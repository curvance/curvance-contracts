import { ethers } from "hardhat";
import { expect } from "chai";
import { Signer, utils } from "ethers";
import { CurvanceToken, CurvanceToken__factory, MockICve__factory } from "../src/types";

describe("Curvance Token - CVE", () => {
  let owner: Signer;
  let newOwner: Signer;
  let curvanceToken: CurvanceToken;

  const initialSupply = utils.parseEther("1000");

  beforeEach(async () => {
    // Get owner and operator
    [owner, newOwner] = await ethers.getSigners();

    // Deploy contracts
    curvanceToken = await new CurvanceToken__factory(owner).deploy();

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

  it("Owner should be able to transfer Ownership", async () => {
    // Transfer ownership
    const tx = curvanceToken.transferOwnership(await newOwner.getAddress());

    // Should emit `OwnershipTransferred` event
    await expect(tx).to.emit(curvanceToken, "OwnershipTransferred");

    // Check if ownership has changed
    const newOwnerAddress = await curvanceToken.owner();
    expect(newOwnerAddress).to.be.equal(await newOwner.getAddress());
  });
});
