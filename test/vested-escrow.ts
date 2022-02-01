import { ethers, network } from "hardhat";
import { expect } from "chai";
import { Signer } from "ethers";
import {
  VestedEscrow,
  VestedEscrow__factory,
  VestedEscrowFactory,
  VestedEscrowFactory__factory,
  MockCve,
  MockCve__factory,
} from "../src/types";

const timestamp = async () => {
  return (await ethers.provider.getBlock(await ethers.provider.getBlockNumber())).timestamp;
};

const mineToFuture = async (futureTime: number) => {
  await network.provider.send("evm_increaseTime", [futureTime]);
  await network.provider.send("evm_mine");
};

const ONE_YEAR = 31536000;
const ONE_MONTH = 2678400;

describe("CVE Vested Escrow", async () => {
  let owner: Signer;
  let michael: Signer;
  let alice: Signer;
  let mockCve: MockCve;
  let vestedEscrow: VestedEscrow;
  let implementation: VestedEscrow;
  let vestedEscrowFactory: VestedEscrowFactory;

  beforeEach(async () => {
    [owner, michael, alice] = await ethers.getSigners();

    mockCve = await new MockCve__factory(owner).deploy("Curvance Token", "CVE");
    // implementation contract
    implementation = await new VestedEscrow__factory(owner).deploy();
    vestedEscrowFactory = await new VestedEscrowFactory__factory(owner).deploy(implementation.address);
    // staking contract address as placeholder
    const tx = await vestedEscrowFactory.createEscrow(
      mockCve.address,
      (await timestamp()) + 1,
      (await timestamp()) + ONE_YEAR,
      await owner.getAddress(),
    );
    const receipt = await tx.wait();
    const vestedEscrowAddress = ethers.utils.defaultAbiCoder.decode(["address"], receipt.logs[0].data).toString();
    vestedEscrow = VestedEscrow__factory.connect(vestedEscrowAddress, owner);

    // mint enough cve to owner
    await mockCve.mint(await owner.getAddress(), 100000000);
    // allow escrow to spend
    await mockCve.increaseAllowance(vestedEscrow.address, 10000);
  });

  it("admin tests", async () => {
    // only admin can create escrows from factory
    await expect(
      vestedEscrowFactory
        .connect(alice)
        .createEscrow(
          mockCve.address,
          (await timestamp()) + 1,
          (await timestamp()) + ONE_YEAR,
          await alice.getAddress(),
        ),
    ).to.be.revertedWith("Ownable: caller is not the owner");
    await expect(
      vestedEscrowFactory.createEscrow(
        mockCve.address,
        (await timestamp()) + 1,
        (await timestamp()) + ONE_YEAR,
        await owner.getAddress(),
      ),
    ).to.emit(vestedEscrowFactory, "EscrowCreated");

    // only admin can add tokens
    await expect(vestedEscrow.connect(alice).addTokens(100)).to.be.revertedWith("!auth");
    await vestedEscrow.addTokens(1000);

    // should only fund after adding tokens (or ensuring unallocatedAmount >= funds to add)
    // only admin can fund
    await expect(
      vestedEscrow.connect(alice).fund([await michael.getAddress(), await alice.getAddress()], [100, 100]),
    ).to.be.revertedWith("!auth");
    await vestedEscrow.fund([await michael.getAddress(), await alice.getAddress()], [100, 100]);
  });

  it("creates escrows with correct params/initialization", async () => {
    const timeNow = await timestamp();

    await expect(
      vestedEscrowFactory.createEscrow(mockCve.address, timeNow - 1, timeNow + ONE_YEAR, await owner.getAddress()),
    ).to.be.revertedWith("start must be future");
    await expect(
      vestedEscrowFactory.createEscrow(mockCve.address, timeNow + 1, timeNow - 1, await owner.getAddress()),
    ).to.be.revertedWith("end must be greater");
    // create 2 escrows
    await vestedEscrowFactory.createEscrow(mockCve.address, timeNow + 10, timeNow + ONE_YEAR, await owner.getAddress());
    await vestedEscrowFactory.createEscrow(mockCve.address, timeNow + 10, timeNow + ONE_YEAR, await owner.getAddress());

    // check params
    expect(await vestedEscrow.factory()).to.eq(vestedEscrowFactory.address);
    expect(await vestedEscrow.token()).to.eq(mockCve.address);
    expect(await vestedEscrow.lockingContract()).to.eq(await owner.getAddress());
  });

  it("adds tokens", async () => {
    await vestedEscrow.addTokens(100);
    expect(await vestedEscrow.unallocatedSupply()).to.eq(100);
  });

  it("funds recipients", async () => {
    const aliceAllocBefore = await vestedEscrow.initialLocked(await alice.getAddress());
    const michaelAllocBefore = await vestedEscrow.initialLocked(await michael.getAddress());

    await expect(
      vestedEscrow.fund([await michael.getAddress(), await alice.getAddress()], [100, 100]),
    ).to.be.revertedWith("total funding more than unallocated");
    await vestedEscrow.addTokens(200);
    await vestedEscrow.fund([await michael.getAddress(), await alice.getAddress()], [100, 100]);
    expect(await vestedEscrow.initialLocked(await michael.getAddress())).to.eq(michaelAllocBefore.add(100));
    expect(await vestedEscrow.initialLocked(await alice.getAddress())).to.eq(aliceAllocBefore.add(100));
  });

  it("gets right vesting of recipients", async () => {
    expect(await vestedEscrow["vestedOf(address)"](await michael.getAddress())).to.eq(0);
    expect(await vestedEscrow["vestedOf(address)"](await alice.getAddress())).to.eq(0);

    await vestedEscrow.addTokens(1000);
    await vestedEscrow.fund([await michael.getAddress(), await alice.getAddress()], [120, 240]);

    // fast forward and check
    await mineToFuture(ONE_MONTH);
    expect(await vestedEscrow["vestedOf(address)"](await michael.getAddress())).to.eq(10);
    expect(await vestedEscrow.lockedOf(await michael.getAddress())).to.eq(110);
    await mineToFuture(ONE_MONTH * 3);
    expect(await vestedEscrow["vestedOf(address)"](await michael.getAddress())).to.eq(40);
    expect(await vestedEscrow.lockedOf(await michael.getAddress())).to.eq(80);
    await mineToFuture(ONE_MONTH * 8);
    expect(await vestedEscrow["vestedOf(address)"](await michael.getAddress())).to.eq(120);
    expect(await vestedEscrow.lockedOf(await michael.getAddress())).to.eq(0);
    expect(await vestedEscrow["vestedOf(address)"](await alice.getAddress())).to.eq(240);
    expect(await vestedEscrow.lockedOf(await alice.getAddress())).to.eq(0);
  });

  it("gets total vested supply", async () => {
    await vestedEscrow.addTokens(1000);
    expect(await vestedEscrow.vestedSupply()).to.eq(0);

    await vestedEscrow.fund([await michael.getAddress(), await alice.getAddress()], [120, 240]);
    // fast forward and check
    await mineToFuture(ONE_MONTH);
    expect(await vestedEscrow.vestedSupply()).to.eq(30);
    await mineToFuture(ONE_MONTH * 11);
    expect(await vestedEscrow.vestedSupply()).to.eq(360);
  });

  it("gets total locked supply", async () => {
    await vestedEscrow.addTokens(1000);
    await vestedEscrow.fund([await michael.getAddress(), await alice.getAddress()], [120, 240]);
    // fast forward and check
    await mineToFuture(ONE_MONTH);
    expect(await vestedEscrow.lockedSupply()).to.eq(330);
    await mineToFuture(ONE_MONTH * 11);
    expect(await vestedEscrow.lockedSupply()).to.eq(0);
  });

  it("claims and checks balance", async () => {
    await vestedEscrow.addTokens(1000);
    await vestedEscrow.fund([await michael.getAddress(), await alice.getAddress()], [120, 240]);
    // fast forward and check
    await mineToFuture(ONE_MONTH);
    await expect(vestedEscrow.connect(michael)["claim()"]())
      .to.emit(vestedEscrow, "Claim")
      .withArgs(await michael.getAddress(), 10);
    expect(await mockCve.balanceOf(await michael.getAddress())).to.eq(10);

    await mineToFuture(ONE_MONTH * 11);
    await expect(vestedEscrow.connect(michael)["claim()"]())
      .to.emit(vestedEscrow, "Claim")
      .withArgs(await michael.getAddress(), 110);
    expect(await mockCve.balanceOf(await michael.getAddress())).to.eq(120);
    await expect(vestedEscrow.connect(alice)["claim()"]())
      .to.emit(vestedEscrow, "Claim")
      .withArgs(await alice.getAddress(), 240);
    expect(await mockCve.balanceOf(await alice.getAddress())).to.eq(240);
  });
});
