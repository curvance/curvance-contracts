// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { IBooster } from "contracts/interfaces/external/convex/IBooster.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { CompoundingPToken} from "contracts/market/token/CompoundingPToken.sol";
import "tests/market/TestBaseMarketIsolated.sol";

contract TestAuraPToken is TestBaseMarketIsolated {
    address internal _BAL_ADDRESS = 0xba100000625a3754423978a60c9317c58a424e3D;
    address internal _AURA_ADDRESS =
        0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;

    MockDataFeed public mockUsdcFeed;
    MockDataFeed public mockDaiFeed;
    MockDataFeed public mockWethFeed;
    MockDataFeed public mockRethFeed;
    MockDataFeed public mockBALFeed;
    MockDataFeed public mockAURAFeed;

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

        // use mock pricing for testing
        mockUsdcFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(mockUsdcFeed),
            0,
            true
        );
        mockDaiFeed = new MockDataFeed(_CHAINLINK_DAI_USD);
        chainlinkAdaptor.addAsset(_DAI_ADDRESS, address(mockDaiFeed), 0, true);
        dualChainlinkAdaptor.addAsset(
            _DAI_ADDRESS,
            address(mockDaiFeed),
            0,
            true
        );
        mockWethFeed = new MockDataFeed(_CHAINLINK_ETH_USD);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        dualChainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(mockWethFeed),
            0,
            true
        );
        mockRethFeed = new MockDataFeed(_CHAINLINK_RETH_ETH);
        chainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            false
        );
        dualChainlinkAdaptor.addAsset(
            _RETH_ADDRESS,
            address(mockRethFeed),
            0,
            true
        );

        mockBALFeed = new MockDataFeed(
            0xdF2917806E30300537aEB49A7663062F4d1F2b5F
        );
        mockBALFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(_BAL_ADDRESS, address(mockBALFeed), 0, true);
        oracleManager.addAssetPriceFeed(
            _BAL_ADDRESS,
            address(chainlinkAdaptor)
        );

        mockAURAFeed = new MockDataFeed(
            0xdF2917806E30300537aEB49A7663062F4d1F2b5F
        );
        mockAURAFeed.setMockUpdatedAt(block.timestamp);
        chainlinkAdaptor.addAsset(
            _AURA_ADDRESS,
            address(mockAURAFeed),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _AURA_ADDRESS,
            address(chainlinkAdaptor)
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
            address(pBALRETH),
            _ONE
        );
        marketManagerIsolated.listToken(address(pBALRETH));
    }

    function testHarvestAuraPToken() public {
        uint256 assets = 100e18;
        _prepareBALRETH(user1, assets);

        vm.prank(user1);
        balRETH.approve(address(pBALRETH), assets);

        vm.prank(user1);
        pBALRETH.deposit(assets, user1);

        assertEq(
            pBALRETH.totalAssets(),
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
            address(pBALRETH),
            block.timestamp
        );

        pBALRETH.harvest(abi.encode(swaps, 1e8));

        // check vault data without modification to vesting period

        CompoundingPToken.VaultData memory vaultData = pBALRETH.getVaultYieldStatus();
        uint256 rewardRate = vaultData.rewardRate;
        uint256 vestingPeriodEnd = vaultData.vestingPeriodEnd;
        uint256 lastVestClaim = vaultData.lastVestClaim;

        assert(lastVestClaim == block.timestamp);
        assert(vestingPeriodEnd == block.timestamp + 1 days);

        vm.warp(block.timestamp + 8 days);

        assertGt(
            pBALRETH.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit."
        );

        vm.startPrank(user1);
        pBALRETH.withdraw(pBALRETH.balanceOf(user1), user1, user1);
        vm.stopPrank();

        pBALRETH.setVestingPeriod(2 days);

        // increase vesting period to 2 days

        (bool updateNeeded, uint256 newVestPeriod) = pBALRETH.pendingVestUpdate();
        assert(updateNeeded == true);
        assert(newVestPeriod == 2 days);

        // harvest again to update the vesting period

        _prepareBALRETH(user2, assets);

        vm.prank(user2);
        balRETH.approve(address(pBALRETH), assets);

        vm.prank(user2);
        pBALRETH.deposit(assets, user2);

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
            address(pBALRETH),
            block.timestamp
        );

        pBALRETH.harvest(abi.encode(swaps, 1e8));

        vaultData = pBALRETH.getVaultYieldStatus();
        rewardRate = vaultData.rewardRate;
        vestingPeriodEnd = vaultData.vestingPeriodEnd;
        lastVestClaim = vaultData.lastVestClaim;

        assert(lastVestClaim == block.timestamp);
        assert(vestingPeriodEnd == block.timestamp + 2 days);

        // setCompoundingPaused
        pBALRETH.setCompoundingPaused(true);

        vm.expectRevert(CompoundingPToken.CompoundingPToken__CompoundingPaused.selector);
        pBALRETH.harvest(bytes("0"));

    }

    function testReQueryTokens() external {
        pBALRETH.reQueryTokens();

        assertEq(pBALRETH.rewardTokens().length, 3);
        assertEq(pBALRETH.underlyingTokens().length, 2);
    }
}
