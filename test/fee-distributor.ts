import { ethers } from "hardhat";
import { expect } from "chai";
import { Signer } from "ethers";
import { zeroAddress } from "ethereumjs-util";
import { FeesDistributor, FeesDistributor__factory, MockVotingEscrow, MockVotingEscrow__factory } from "../src/types";

const ONE_DAY = 86400;

describe("Fuse Pool Fees distributor", async () => {
  let owner: Signer;
  let michael: Signer;
  let alice: Signer;
  let feesDistributor: FeesDistributor;
  let ve: MockVotingEscrow;

  beforeEach(async () => {
    [owner, michael, alice] = await ethers.getSigners();

    ve = await new MockVotingEscrow__factory(owner).deploy();
    feesDistributor = await new FeesDistributor__factory(owner).deploy(await alice.getAddress(), ve.address);
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
      const pool = await feesDistributor.pools(0);
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
  });
});
