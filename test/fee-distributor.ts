import { ethers, network } from "hardhat";
import { expect } from "chai";
import { Signer } from "ethers";
import { zeroAddress } from "ethereumjs-util";
import {
  FeesDistributor,
  FeesDistributor__factory,
  MCErc20,
  MCErc20__factory,
  MockComptroller,
  MockComptroller__factory,
  MockCve,
  MockCve__factory,
  MockVotingEscrow,
  MockVotingEscrow__factory,
} from "../src/types";

const ONE_DAY = 86400;

const mineToFuture = async (futureTime: number) => {
  await network.provider.send("evm_increaseTime", [futureTime]);
  await network.provider.send("evm_mine");
};

const timestamp = async () => {
  return (await ethers.provider.getBlock(await ethers.provider.getBlockNumber())).timestamp;
};

describe("Fuse Pool Fees distributor", async () => {
  let owner: Signer;
  let michael: Signer;
  let alice: Signer;
  let feesDistributor: FeesDistributor;
  let ve: MockVotingEscrow;
  let cve: MockCve;
  let comptroller: MockComptroller;
  let erc20_A: MockCve;
  let erc20_B: MockCve;
  let cERC20_A: MCErc20;

  beforeEach(async () => {
    [owner, michael, alice] = await ethers.getSigners();

    // deplloy erc20s
    erc20_A = await new MockCve__factory(owner).deploy("ERC20 A", "20A");
    erc20_B = await new MockCve__factory(owner).deploy("ERC20 B", "20B");
    // create pool/comptroller
    cERC20_A = await new MCErc20__factory(owner).deploy(erc20_A.address);
    comptroller = await new MockComptroller__factory(owner).deploy([cERC20_A.address]);

    ve = await new MockVotingEscrow__factory(owner).deploy(await cERC20_A.underlying());
    feesDistributor = await new FeesDistributor__factory(owner).deploy(await alice.getAddress(), ve.address);

    cve = await new MockCve__factory(owner).deploy("Curvance Token", "CVE");
    await cve.mint(await michael.getAddress(), ethers.utils.parseEther("100"));
    await cve.mint(feesDistributor.address, ethers.utils.parseEther("100"));

    // add pool
    await feesDistributor.addPool(comptroller.address);

    // mint fees to cerc20
    await erc20_A.mint(cERC20_A.address, ethers.utils.parseEther("100"));
  });

  describe("admin tests", async () => {
    it("can set operator", async () => {
      await expect(feesDistributor.connect(michael).setOperator(await alice.getAddress())).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      await expect(feesDistributor.setOperator(await alice.getAddress())).to.be.revertedWith("same operator");
      await expect(feesDistributor.setOperator(await michael.getAddress()))
        .to.emit(feesDistributor, "NewOperator")
        .withArgs(await michael.getAddress());
      expect(await feesDistributor.operator()).to.eq(await michael.getAddress());
    });

    it("can add pool", async () => {
      await expect(feesDistributor.connect(michael).addPool(await alice.getAddress())).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      await expect(feesDistributor.addPool(await michael.getAddress()))
        .to.emit(feesDistributor, "PoolAdded")
        .withArgs(await michael.getAddress());
      const pool = await feesDistributor.pools(1);
      expect(pool).to.eq(await michael.getAddress());
      expect(await feesDistributor.poolExists(await michael.getAddress())).to.eq(true);

      // adding same pool
      await expect(feesDistributor.addPool(await michael.getAddress())).to.be.revertedWith("pool already exists");
      await expect(feesDistributor.addPool(zeroAddress())).to.be.revertedWith("invalid pool");
    });

    it("can remove pool", async () => {
      await expect(feesDistributor.connect(michael).removePool(await alice.getAddress())).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      await expect(feesDistributor.removePool(await owner.getAddress())).to.be.revertedWith("pool does not exist");
      await feesDistributor.addPool(await michael.getAddress());
      await expect(feesDistributor.removePool(await michael.getAddress())).to.emit(feesDistributor, "PoolRemoved");
      expect(await feesDistributor.poolExists(await michael.getAddress())).to.eq(false);
    });

    it("can set harvest interval ", async () => {
      await expect(feesDistributor.connect(michael).setHarvestInterval(0)).to.be.revertedWith(
        "Ownable: caller is not the owner",
      );
      await expect(feesDistributor.setHarvestInterval(0)).to.be.revertedWith("invalid interval");
      await expect(feesDistributor.setHarvestInterval(ONE_DAY))
        .to.emit(feesDistributor, "NewHarvestInterval")
        .withArgs(ONE_DAY);
      expect(await feesDistributor.harvestInterval()).to.eq(ONE_DAY);
    });

    it("can recover token", async () => {
      await expect(
        feesDistributor
          .connect(alice)
          .recoverToken(cve.address, await owner.getAddress(), ethers.utils.parseEther("100")),
      ).to.be.revertedWith("Ownable: caller is not the owner");
      await expect(feesDistributor.recoverToken(cve.address, await owner.getAddress(), ethers.utils.parseEther("100")))
        .to.emit(feesDistributor, "RecoveredToken")
        .withArgs(cve.address, await owner.getAddress(), await owner.getAddress(), ethers.utils.parseEther("100"));

      expect(await cve.balanceOf(await owner.getAddress())).to.eq(ethers.utils.parseEther("100"));

      // TODO: add test for underlyingExists check
    });

    it("harvest only at intervals", async () => {
      // only operator
      await expect(feesDistributor.connect(michael).harvestAdminFees(false)).to.be.revertedWith("not authorized");

      // fast forward
      await mineToFuture((await timestamp()) + ONE_DAY);

      await feesDistributor.connect(alice).harvestAdminFees(false);
    });

    it("can harvest admin fees", async () => {
      await expect(feesDistributor.connect(michael).harvestAdminFees(false)).to.be.revertedWith("not authorized");
      // no underlying tokens nor fees yet
      expect(await feesDistributor.underlyingExists(await cERC20_A.underlying())).to.eq(false);
      expect(await feesDistributor.feesHarvested(cERC20_A.address)).to.eq(0);
      expect(await feesDistributor.feesRemaining(await cERC20_A.underlying())).to.eq(0);

      const fees = ethers.utils.parseEther("100");
      await expect(feesDistributor.connect(alice).harvestAdminFees(false))
        .to.emit(feesDistributor, "FeesHarvested")
        .withArgs(comptroller.address, cERC20_A.address, fees);

      // validate harvest interval
      expect(await feesDistributor.lastHarvestedTime()).to.gt(0);

      // check underlying and fees
      expect(await feesDistributor.underlyingExists(await cERC20_A.underlying())).to.eq(true);
      expect(await feesDistributor.feesHarvested(cERC20_A.address)).to.eq(fees);
      expect(await feesDistributor.feesRemaining(await cERC20_A.underlying())).to.eq(fees);
      expect(await feesDistributor.underlyingTokens(0)).to.eq(await cERC20_A.underlying());
    });

    it("notifies reward amount", async () => {
      const fees = ethers.utils.parseEther("100");
      await expect(feesDistributor.connect(alice).harvestAdminFees(true))
        .to.emit(feesDistributor, "FeesDistributed")
        .withArgs(ve.address, await cERC20_A.underlying(), fees);
      expect(await feesDistributor.feesHarvested(cERC20_A.address)).to.eq(fees);
      expect(await feesDistributor.feesRemaining(await cERC20_A.underlying())).to.eq(0);
    });

    it("distributes remaining fees for a token", async () => {
      const fees = ethers.utils.parseEther("100");
      await feesDistributor.connect(alice).harvestAdminFees(false);

      await expect(feesDistributor.connect(alice).distribute(await owner.getAddress())).to.be.revertedWith(
        "nothing to distribute",
      );

      await expect(feesDistributor.connect(alice).distribute(await cERC20_A.underlying()))
        .to.emit(feesDistributor, "FeesDistributed")
        .withArgs(ve.address, await cERC20_A.underlying(), fees);
      expect(await feesDistributor.feesHarvested(cERC20_A.address)).to.eq(fees);
      expect(await feesDistributor.feesRemaining(await cERC20_A.underlying())).to.eq(0);

      await expect(feesDistributor.connect(alice).distribute(await cERC20_A.underlying())).to.be.revertedWith(
        "nothing to distribute",
      );
    });

    it("distributes all remaining fees", async () => {
      const fees = ethers.utils.parseEther("100");
      await feesDistributor.connect(alice).harvestAdminFees(false);
      expect(await feesDistributor.feesRemaining(await cERC20_A.underlying())).to.eq(fees);
      expect(await feesDistributor.underlyingExists(await cERC20_A.underlying())).to.eq(true);

      await expect(feesDistributor.connect(alice).distributeAll())
        .to.emit(feesDistributor, "FeesDistributed")
        .withArgs(ve.address, await cERC20_A.underlying(), fees);
      expect(await feesDistributor.feesHarvested(cERC20_A.address)).to.eq(fees);
      expect(await feesDistributor.feesRemaining(await cERC20_A.underlying())).to.eq(0);
    });
  });
});
