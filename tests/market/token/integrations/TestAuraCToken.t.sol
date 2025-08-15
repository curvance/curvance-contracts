// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IBooster } from "contracts/interfaces/external/convex/IBooster.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { StrategyCToken} from "contracts/market/token/StrategyCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";

contract TestAuraCToken is TestBaseMarketIsolated {


    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork(20287400);

        _init();

        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V2_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V2_ROUTER))
        );

        vm.warp(gaugeManager.gaugeStartTime());
        _skipEpochDuration(1);
        vm.roll(block.number + 1000);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);

        _prepareBALRETH(user1, _ONE);
        _prepareBALRETH(address(this), _ONE);

        SafeTransferLib.safeApprove(
            _BAL_WETH_RETH_ADDRESS,
            address(strategyCBALRETH),
            _ONE
        );

        _prepareUSDC(address(this), 1000e6);

        usdc.approve(address(borrowableCUSDC), type(uint256).max);

        marketManagerIsolated.listTokens(address(strategyCBALRETH), address(borrowableCUSDC));
    }

    function testHarvestAuraCToken() public {
        uint256 assets = 100e18;
        _prepareBALRETH(user1, assets);

        vm.prank(user1);
        balRETH.approve(address(strategyCBALRETH), assets);

        vm.prank(user1);
        strategyCBALRETH.deposit(assets, user1);

        assertEq(
            strategyCBALRETH.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit."
        );

        IBooster(_AURA_BOOSTER).earmarkRewards(109);

        // Advance time to earn BAL and AURA rewards
        vm.warp(block.timestamp + 10 days);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        mockAURAFeed.setMockUpdatedAt(block.timestamp);

        // Mint some extra rewards for Vault.
        // deal(address(CRV), address(cSTETH), 100e18);
        // deal(address(CVX), address(cSTETH), 100e18);
        // deal(address(cSTETH), 1 ether);

        SwapperLib.Swap[] memory swaps = new SwapperLib.Swap[](1);
        uint256 balAmount = 100 ether;
        swaps[0].slippage = 0.3e18;
        swaps[0].inputToken = _BAL_ADDRESS;
        swaps[0].inputAmount = balAmount;
        swaps[0].outputToken = _WETH_ADDRESS;
        swaps[0].target = _UNISWAP_V2_ROUTER;
        address[] memory path = new address[](2);
        path[0] = _BAL_ADDRESS;
        path[1] = _WETH_ADDRESS;
        swaps[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            balAmount,
            0,
            path,
            address(strategyCBALRETH),
            block.timestamp
        );

        strategyCBALRETH.harvest(abi.encode(swaps, 1e8));

        // check vault data without modification to vesting period
        (uint256 rewardRate, 
        uint256 vestingPeriodEnd, 
        uint256 lastVestClaim) = strategyCBALRETH.getYieldInformation();

        assert(lastVestClaim == block.timestamp);
        assert(vestingPeriodEnd == block.timestamp + 1 days);

        vm.warp(block.timestamp + 8 days);

        assertGt(
            strategyCBALRETH.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit."
        );

        vm.startPrank(user1);
        
        strategyCBALRETH.withdraw(strategyCBALRETH.balanceOf(user1), user1, user1);
        vm.stopPrank();

        strategyCBALRETH.setVestingPeriod(2 days);

        // increase vesting period to 2 days

        (bool updateNeeded, uint256 newVestPeriod) = strategyCBALRETH.pendingVestingPeriodUpdate();
        assert(updateNeeded == true);
        assert(newVestPeriod == 2 days);

        // harvest again to update the vesting period

        _prepareBALRETH(user2, assets);

        vm.prank(user2);
        balRETH.approve(address(strategyCBALRETH), assets);

        vm.prank(user2);
        strategyCBALRETH.deposit(assets, user2);

        IBooster(_AURA_BOOSTER).earmarkRewards(109);

        // Advance time to earn BAL and AURA rewards
        vm.warp(block.timestamp + 10 days);

        mockUsdcFeed.setMockUpdatedAt(block.timestamp);
        mockDaiFeed.setMockUpdatedAt(block.timestamp);
        mockWethFeed.setMockUpdatedAt(block.timestamp);
        mockRethFeed.setMockUpdatedAt(block.timestamp);
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        mockAURAFeed.setMockUpdatedAt(block.timestamp);

        swaps[0].call = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            balAmount,
            0,
            path,
            address(strategyCBALRETH),
            block.timestamp
        );

        strategyCBALRETH.harvest(abi.encode(swaps, 1e8));

        (rewardRate, vestingPeriodEnd, lastVestClaim) = strategyCBALRETH.getYieldInformation();

        assert(lastVestClaim == block.timestamp);
        assert(vestingPeriodEnd == block.timestamp + 2 days);

        // setHarvestingPaused
        strategyCBALRETH.setHarvestingPaused(true);

        vm.expectRevert(StrategyCToken.StrategyCToken__HarvestingPaused.selector);
        strategyCBALRETH.harvest(bytes("0"));

    }

    function testReQueryTokens() external {
        strategyCBALRETH.reQueryTokens();

        assertEq(strategyCBALRETH.rewardTokens().length, 3);
        assertEq(strategyCBALRETH.underlyingTokens().length, 2);
    }
}
