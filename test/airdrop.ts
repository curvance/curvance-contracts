import { ethers, network } from "hardhat";
import { expect } from "chai";
import { BigNumber, Signer } from "ethers";
import {
  MerkleAirdrop,
  MerkleAirdrop__factory,
  MerkleAirdropFactory,
  MerkleAirdropFactory__factory,
  MockCve,
  MockCve__factory,
} from "../src/types";
import BalanceTree from "../src/scripts/merkle/balance-tree";

const timestamp = async () => {
  return (await ethers.provider.getBlock(await ethers.provider.getBlockNumber())).timestamp;
};

const mineToFuture = async (futureTime: number) => {
  await network.provider.send("evm_increaseTime", [futureTime]);
  await network.provider.send("evm_mine");
};

describe("CVE Merkle Airdrop", async () => {
  let owner: Signer;
  let michael: Signer;
  let alice: Signer;
  let bob: Signer;
  let tree: BalanceTree;
  let airdrop: MerkleAirdrop;
  let mockCve: MockCve;
  let airdropFactory: MerkleAirdropFactory;

  const NUM_LEAVES = 10000; //100_000;
  const NUM_SAMPLES = 25;
  const elements: { account: string; amount: BigNumber }[] = [];

  beforeEach(async () => {
    [owner, michael, alice, bob] = await ethers.getSigners();

    for (let i = 0; i < NUM_LEAVES; i++) {
      const node = { account: await michael.getAddress(), amount: BigNumber.from(100) };
      elements.push(node);
    }
    tree = new BalanceTree(elements);

    mockCve = await new MockCve__factory(owner).deploy("Cve Token", "CVE");
    airdropFactory = await new MerkleAirdropFactory__factory(owner).deploy();
    await airdropFactory.CreateMerkleAirdrop(
      mockCve.address,
      await timestamp(),
      (await timestamp()) + 1000,
      tree.getHexRoot(),
    );

    const airdropAddress = await airdropFactory.airdrop();
    airdrop = MerkleAirdrop__factory.connect(airdropAddress, owner);

    // set time to start claim
    await airdrop.setClaimEndTimestamp((await timestamp()) + 1000);

    // ensure airdrop contract has enough tokens to give
    await mockCve.mint(airdrop.address, 10000);
  });

  it("admin tests", async () => {
    // only admin can set owner
    await expect(airdrop.connect(michael).setOwner(await michael.getAddress())).to.be.revertedWith("!owner");
    await airdrop.setOwner(await alice.getAddress());
    expect(await airdrop.owner()).to.eq(await alice.getAddress());

    // only admin can set time to end airdrop
    const timeNow = await timestamp();
    await expect(airdrop.connect(michael).setClaimEndTimestamp(timeNow + 1000)).to.be.revertedWith("!owner");
    await airdrop.connect(alice).setClaimEndTimestamp(timeNow + 1000);
  });

  it("sets time correctly", async () => {
    const timeNow = (await timestamp()) + 1;

    // end time
    await expect(airdrop.setClaimEndTimestamp(timeNow - 10)).to.be.revertedWith("!valid");
    await airdrop.setClaimEndTimestamp(timeNow + 100);
    const end = await airdrop.endClaimTimestamp();
    expect(end).to.eq(timeNow + 100);
  });

  it("returns token address", async () => {
    expect(await airdrop.token()).to.eq(mockCve.address);
  });

  it("fails for invalid index", async () => {
    const proof = tree.getProof(0, await michael.getAddress(), BigNumber.from(100));
    await expect(airdrop.claim(200000, await michael.getAddress(), 100, proof)).to.be.revertedWith("!valid proof");
  });

  it("successfully claims", async () => {
    const proof = tree.getProof(0, await michael.getAddress(), BigNumber.from(100));
    await expect(airdrop.claim(0, await michael.getAddress(), 100, proof))
      .to.emit(airdrop, "Claimed")
      .withArgs(0, await michael.getAddress(), 100);
  });

  it("sends account Cve", async () => {
    // michael should receive airdrop
    const proof = tree.getProof(0, await michael.getAddress(), BigNumber.from(100));
    expect(await mockCve.balanceOf(await michael.getAddress())).to.eq(0);
    await airdrop.claim(0, await michael.getAddress(), 100, proof);
    expect(await mockCve.balanceOf(await michael.getAddress())).to.eq(100);
  });

  it("sets #isClaimed", async () => {
    const proof = tree.getProof(0, await michael.getAddress(), BigNumber.from(100));
    expect(await airdrop.isClaimed(0)).to.eq(false);
    expect(await airdrop.isClaimed(1)).to.eq(false);
    await airdrop.claim(0, await michael.getAddress(), 100, proof);
    expect(await airdrop.isClaimed(0)).to.eq(true);
    expect(await airdrop.isClaimed(1)).to.eq(false);
  });

  it("cannot allow two claims", async () => {
    const proof = tree.getProof(0, await michael.getAddress(), BigNumber.from(100));
    await airdrop.claim(0, await michael.getAddress(), 100, proof);
    await expect(airdrop.claim(0, await michael.getAddress(), 100, proof)).to.be.revertedWith("already claimed.");
  });

  it("cannot claim for address other than proof", async () => {
    // alice trying to claim with michael's proof
    const proof = tree.getProof(0, await michael.getAddress(), BigNumber.from(100));
    await expect(airdrop.claim(1, await alice.getAddress(), 101, proof)).to.be.revertedWith("!valid proof");
  });

  it("cannot claim more than proof", async () => {
    // michael trying to claim more than he was allocated
    const proof = tree.getProof(0, await michael.getAddress(), BigNumber.from(100));
    await expect(airdrop.claim(0, await michael.getAddress(), 101, proof)).to.be.revertedWith("!valid proof");
  });

  it("cannot claim after claim period", async () => {
    // clint can claim
    const proof = tree.getProof(0, await michael.getAddress(), BigNumber.from(100));
    expect(await mockCve.balanceOf(await michael.getAddress())).to.eq(0);
    await airdrop.claim(0, await michael.getAddress(), 100, proof);
    expect(await mockCve.balanceOf(await michael.getAddress())).to.eq(100);

    // fast forward and try again
    const timeNow = await timestamp();
    const fastForward = timeNow + 86400 * 3;
    await mineToFuture(fastForward);
    const proof1 = tree.getProof(1, await michael.getAddress(), BigNumber.from(100));
    await expect(airdrop.claim(1, await michael.getAddress(), 100, proof1)).to.be.revertedWith("!valid time");
  });

  it("proof verification works", async () => {
    const root = Buffer.from(tree.getHexRoot().slice(2), "hex");
    for (let i = 0; i < NUM_LEAVES; i += NUM_LEAVES / NUM_SAMPLES) {
      const proof = tree
        .getProof(i, await michael.getAddress(), BigNumber.from(100))
        .map(el => Buffer.from(el.slice(2), "hex"));
      const validProof = BalanceTree.verifyProof(i, await michael.getAddress(), BigNumber.from(100), proof, root);
      expect(validProof).to.be.true;
    }
  });

  it("no double claims in random distribution", async () => {
    for (let i = 0; i < 25; i += Math.floor(Math.random() * (NUM_LEAVES / NUM_SAMPLES))) {
      const proof = tree.getProof(i, await michael.getAddress(), BigNumber.from(100));
      await airdrop.claim(i, await michael.getAddress(), 100, proof);
      await expect(airdrop.claim(i, await michael.getAddress(), 100, proof)).to.be.revertedWith("already claimed.");
    }
  });
});
