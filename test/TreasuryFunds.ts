import { ethers } from "hardhat";
import { expect } from "chai";
import { Signer, utils } from "ethers";
import {
  TreasuryFunds,
  TreasuryFunds__factory,
  ERC20Mock,
  ERC20Mock__factory,
  ITreasuryFundsMock__factory,
} from "../src/types";

describe("Treasury Funds", () => {
  let owner: Signer;
  let newOwner: Signer;
  let newHolder: Signer;
  let erc20Mock: ERC20Mock;
  let treasuryFunds: TreasuryFunds;

  beforeEach(async () => {
    // Get owner and operator
    [owner, newOwner, newHolder] = await ethers.getSigners();

    // Deploy contracts
    treasuryFunds = await new TreasuryFunds__factory(owner).deploy();
    erc20Mock = await new ERC20Mock__factory(owner).deploy();
  });

  it("ITreasuryFunds interface should be compatible with TreasuryFunds contract", async () => {
    // Deploy ITreasuryFunds mock contract to get it's interface id
    const iTreasuryFundsMock = await new ITreasuryFundsMock__factory(owner).deploy();

    // Assert compatibility
    expect(await treasuryFunds.supportsInterface(await iTreasuryFundsMock.interfaceId()));
  });

  it("should withdraw asset to the given address", async () => {
    const someAmount = utils.parseEther("300");
    // Transfer some dummy tokens to treasury account
    await erc20Mock.transfer(treasuryFunds.address, someAmount);

    // Withdraw some dummy tokens from the treasury account to new holder account
    const tx = treasuryFunds.withdrawTo(erc20Mock.address, someAmount, await newHolder.getAddress());

    // Should emit `WithdrawTo` event
    await expect(tx).to.emit(treasuryFunds, "WithdrawTo");

    // New holder now should have exact the amount withdrawn from the treasury
    const newHolderBalance = await erc20Mock.balanceOf(await newHolder.getAddress());
    expect(newHolderBalance).to.be.equal(someAmount);
  });

  it("should execute dummy function and emit an ExternalCall event", async () => {
    // Build the interface for the function `dummy` signature
    const iface = new ethers.utils.Interface(["function dummy()"]);

    // Build the call data for `dummy` function call
    const callData = iface.encodeFunctionData("dummy");

    // Execute a function `dummy` on `DummyERC20Token` contract with amount and calldata
    const sendAmount = 0;
    const tx = treasuryFunds.execute(erc20Mock.address, sendAmount, callData);

    // Should emit `ExternalCall` event
    await expect(tx).to.emit(treasuryFunds, "ExternalCall");
  });

  it("should allow the owner to transfer the Ownership", async () => {
    // Transfer ownership
    const tx = treasuryFunds.transferOwnership(await newOwner.getAddress());

    // Should emit `OwnershipTransferred` event
    await expect(tx).to.emit(treasuryFunds, "OwnershipTransferred");

    // Check if ownership has changed
    const newOwnerAddress = await treasuryFunds.owner();
    expect(newOwnerAddress).to.be.equal(await newOwner.getAddress());
  });
});
