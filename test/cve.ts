import { ethers } from "hardhat";
import { expect } from "chai";
import { Signer, utils } from "ethers";
import { CurvanceToken, CurvanceToken__factory } from "../src/types";

describe("Curvance Token - CVE", () => {
  let owner: Signer;
  let operator: Signer;
  let curvanceToken: CurvanceToken;

  const initialSupply = utils.parseEther("1000");

  beforeEach(async () => {
    // Get owner and operator
    [owner, operator] = await ethers.getSigners();

    // Deploy contracts
    curvanceToken = await new CurvanceToken__factory(owner).deploy();

    // Mint initial supply with owner
    await curvanceToken.mint(await owner.getAddress(), initialSupply);
  });

  it("Balance of owner and total supply should be equal to `initialSupply`", async () => {
    // Get owner balance
    const ownerBalance = await curvanceToken.balanceOf(await owner.getAddress());

    // Should be equal to `initialSupply`
    expect(ownerBalance).to.be.equal(initialSupply);

    // Total supply should be equal to `ownerBalance`
    expect(ownerBalance).to.be.equal(await curvanceToken.totalSupply());
  });

  it("Should not be able to mint more than `maxSupply`", async () => {
    // Get how many tokens are left to mint
    const maxSupply = await curvanceToken.maxSupply();
    const amountToMaxSupply = maxSupply.sub(await curvanceToken.totalSupply());

    // Revert if `maxSupply` is surpassed
    await expect(curvanceToken.mint(await owner.getAddress(), amountToMaxSupply.add(1))).to.be.revertedWith(
      "maxSupply reached",
    );
  });

  describe("Change operator", () => {
    // Amount of tokens to mint
    const tokensToMint = 1000;

    beforeEach(async () => {
      // Resign to `operator`
      await curvanceToken.updateOperator(await operator.getAddress());
    });

    it("New operator should be `operator`", async () => {
      // Check if new operator address is equal to `operator` address
      expect(await curvanceToken.operator()).to.be.equal(await operator.getAddress());
    });

    it("Only operator should be able to mint tokens", async () => {
      // Former operator trying to mint tokens should not change contract state
      const oldBalance = await curvanceToken.balanceOf(await owner.getAddress());
      await curvanceToken.mint(await owner.getAddress(), tokensToMint);
      expect(await curvanceToken.balanceOf(await owner.getAddress())).to.be.equal(oldBalance);
    });

    it("New operator should be able to mint tokens", async () => {
      // New operator should be able to mint tokens
      await curvanceToken.connect(operator).mint(await operator.getAddress(), tokensToMint);
      expect(await curvanceToken.balanceOf(await operator.getAddress())).to.be.equal(tokensToMint);
    });

    it("Only operator should be able to select a new one", async () => {
      // Try to get operator role back
      await expect(curvanceToken.updateOperator(await owner.getAddress())).to.be.revertedWith("!operator");
    });
  });
});
