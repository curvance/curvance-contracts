import { ethers } from "hardhat";
import { expect } from "chai";
import { Signer, utils } from "ethers";
import { CurvanceToken, CurvanceToken__factory, MockICve__factory } from "../src/types";

describe("Curvance Token - CVE", () => {
  let owner: Signer;
  let minter: Signer;
  let notMinter: Signer;
  let newOwner: Signer;
  let curvanceToken: CurvanceToken;

  const initialSupply = utils.parseEther("1000");

  const minterRole = utils.keccak256(utils.toUtf8Bytes("MINTER"));
  const adminRole = utils.zeroPad("0x00", 32);

  beforeEach(async () => {
    // Get owner and operator
    [owner, minter, notMinter, newOwner] = await ethers.getSigners();

    // Deploy contracts
    curvanceToken = await new CurvanceToken__factory(owner).deploy();

    // Mint initial supply with owner
    await curvanceToken.mint(await owner.getAddress(), initialSupply);
  });

  it("Check if disabled functions are not changing state", async () => {
    // `grantRole` should not be able change contract state
    await curvanceToken.grantRole(minterRole, await notMinter.getAddress());
    expect(await curvanceToken.isMinter(await notMinter.getAddress())).to.be.false;

    // Grant minter rights to `minter`
    await curvanceToken.nominateMinter(await minter.getAddress());

    // `revokeRole` should not be able change contract state
    await curvanceToken.revokeRole(minterRole, await minter.getAddress());
    expect(await curvanceToken.isMinter(await minter.getAddress())).to.be.true;

    // `renounceRole`should not be able to change contract state
    await curvanceToken.connect(minter).renounceRole(minterRole, await minter.getAddress());
    expect(await curvanceToken.isMinter(await minter.getAddress())).to.be.true;
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

  it("Owner should be able to transfer Ownership", async () => {
    // Transfer ownership
    const tx = curvanceToken.transferOwnership(await newOwner.getAddress());

    // Should emit `OwnerChanged` event
    await expect(tx).to.emit(curvanceToken, "OwnerChanged");

    // Check if ownership has changed
    const newOwnerAddress = await curvanceToken.owner();
    expect(newOwnerAddress).to.be.equal(await newOwner.getAddress());

    // Minter role also transferred
    expect(await curvanceToken.isMinter(await newOwner.getAddress())).to.be.true;
    expect(await curvanceToken.isMinter(await owner.getAddress())).to.be.false;

    // Admin role also transferred
    expect(await curvanceToken.hasRole(adminRole, await newOwner.getAddress())).to.be.true;
    expect(await curvanceToken.hasRole(adminRole, await owner.getAddress())).to.be.false;
  });

  describe("Add another minter", () => {
    // Amount of tokens to mint
    const tokensToMint = 1000;

    beforeEach(async () => {
      // Add minter
      await curvanceToken.nominateMinter(await minter.getAddress());
    });

    it("Only minter should be able to mint tokens", async () => {
      // Address without minter rights tries to mint tokens
      const tx = curvanceToken.connect(notMinter).mint(await notMinter.getAddress(), tokensToMint);
      await expect(tx).to.be.revertedWith("!minter");
    });

    it("Minter should be able to mint tokens", async () => {
      // New minter should be able to mint tokens
      await curvanceToken.connect(minter).mint(await minter.getAddress(), tokensToMint);
      expect(await curvanceToken.balanceOf(await minter.getAddress())).to.be.equal(tokensToMint);
    });

    it("Owner should be able to remove minter rights", async () => {
      // Remove minter rights from `minter`
      await curvanceToken.removeMinter(await minter.getAddress());

      // Address without minter rights tries to mint tokens
      const tx = curvanceToken.connect(minter).mint(await minter.getAddress(), tokensToMint);
      await expect(tx).to.be.revertedWith("!minter");
    });

    it("Minter should be able to renouce role", async () => {
      // Renouce minter role
      await curvanceToken.connect(minter).renounceMinterRole();

      // Address without minter rights tries to mint tokens
      const tx = curvanceToken.connect(minter).mint(await minter.getAddress(), tokensToMint);
      await expect(tx).to.be.revertedWith("!minter");
    });
  });
});
