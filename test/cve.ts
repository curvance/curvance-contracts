import { ethers } from "hardhat";
import { expect } from "chai";
import { Signer, utils } from "ethers";
import { CurvanceToken, CurvanceToken__factory, MockICve__factory } from "../src/types";

describe("Curvance Token - CVE", () => {
  let owner: Signer;
  let minter: Signer;
  let notMinter: Signer;
  let curvanceToken: CurvanceToken;

  const initialSupply = utils.parseEther("1000");

  const minterRole = utils.keccak256(utils.toUtf8Bytes("MINTER"));

  beforeEach(async () => {
    // Get owner and operator
    [owner, minter, notMinter] = await ethers.getSigners();

    // Deploy contracts
    curvanceToken = await new CurvanceToken__factory(owner).deploy();

    // Give owner the minter role
    await curvanceToken.grantRole(minterRole, await owner.getAddress());

    // Mint initial supply with owner
    await curvanceToken.mint(await owner.getAddress(), initialSupply);
  });

  it("ICve interface should be compatible with CVE contract", async () => {
    // Deploy ICve mock contract to get it's interface id
    const mockICve = await new MockICve__factory(owner).deploy();

    // Assert compatibility
    expect(await curvanceToken.supportsInterface(await mockICve.interfaceId()));
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

  describe("Add another minter", () => {
    // Amount of tokens to mint
    const tokensToMint = 1000;

    beforeEach(async () => {
      // Add minter
      await curvanceToken.grantRole(minterRole, await minter.getAddress());

      // Revoke minter role from owner
      await curvanceToken.revokeRole(minterRole, await owner.getAddress());
    });

    it("Only minter should be able to mint tokens", async () => {
      // Sanity check
      expect(await curvanceToken.hasRole(minterRole, await minter.getAddress())).to.be.true;
      // Former operator trying to mint tokens should not change contract state
      const oldBalance = await curvanceToken.balanceOf(await notMinter.getAddress());
      await curvanceToken.connect(notMinter).mint(await notMinter.getAddress(), tokensToMint);
      expect(await curvanceToken.balanceOf(await notMinter.getAddress())).to.be.equal(oldBalance);
    });

    it("Minter should be able to mint tokens", async () => {
      // Sanity check
      expect(await curvanceToken.hasRole(minterRole, await minter.getAddress())).to.be.true;
      // New operator should be able to mint tokens
      await curvanceToken.connect(minter).mint(await minter.getAddress(), tokensToMint);
      expect(await curvanceToken.balanceOf(await minter.getAddress())).to.be.equal(tokensToMint);
    });
  });
});
