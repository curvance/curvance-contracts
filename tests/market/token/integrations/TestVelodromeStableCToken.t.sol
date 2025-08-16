// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VelodromeStableCToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/VelodromeStableCToken.sol";
import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { console2 } from "forge-std/console2.sol";

contract TestVelodromeStableCToken is TestBaseMarketIsolated {
    address internal _VELO_ADDRESS =
        0x9560e827aF36c94D2Ac33a39bCE1Fe78631088Db;
    address internal _USDC_DAI = 0x19715771E30c93915A5bbDa134d782b81A820076;
    IVeloGauge public gauge =
        IVeloGauge(0x6998089F6bDd9c74C7D8d01b99d7e379ccCcb02D);
    IVeloPairFactory public veloPairFactory =
        IVeloPairFactory(0xF1046053aa5682b4F9a81b5481394DA16BE5FF5a);
    IVeloRouter public veloRouter =
        IVeloRouter(0xa062aE8A9c5e11aaA026fc2670B0D65cCc8B2858);
    address public optiSwap = 0x6108FeAA628155b073150F408D0b390eC3121834;

    VelodromeStableCToken public veloCTokenUSDCDAI;
    MockV3Aggregator public chainlinkVELO;
    MockV3Aggregator public chainlinkUSDC;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 109095500);
        
        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployBorrowableCDAI();

        centralRegistry.addHarvestPermissions(address(this));
        centralRegistry.setFeeManager(address(this));
        centralRegistry.setExternalCalldataChecker(
            address(veloRouter),
            address(new MockCalldataChecker(address(veloRouter)))
        );

        veloCTokenUSDCDAI = new VelodromeStableCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_DAI),
            address(marketManagerIsolated),
            gauge,
            veloPairFactory,
            veloRouter,
            1 days
        );

        vm.warp(veCVE.nextEpochStartTime());

        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkVELO = new MockV3Aggregator(8, 0.06e8);
        chainlinkAdaptor.addAsset(
            _VELO_ADDRESS,
            true,
            address(chainlinkVELO),
            0
        );
        oracleManager.addAssetPriceFeed(
            _VELO_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkUSDC = new MockV3Aggregator(8, 1e8);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            address(chainlinkUSDC),
            0
        );
        oracleManager.addAssetPriceFeed(
            _USDC_ADDRESS,
            address(chainlinkAdaptor)
        );

        centralRegistry.setSlippageLimit(6000);
    }

    function testUsdcDaiStablePool() public {
        uint256 assets = 100e18;
        deal(_USDC_DAI, user1, assets);
        deal(_USDC_DAI, address(this), 77777);
        _prepareDAI(address(this), 1e18);
        IERC20(_USDC_DAI).approve(address(veloCTokenUSDCDAI), 77777);
        dai.approve(address(borrowableCDAI), 77777);
        marketManagerIsolated.listTokens(address(veloCTokenUSDCDAI), address(borrowableCDAI));

        vm.prank(user1);
        IERC20(_USDC_DAI).approve(address(veloCTokenUSDCDAI), assets);

        vm.prank(user1);
        veloCTokenUSDCDAI.deposit(assets, user1);

        assertEq(
            veloCTokenUSDCDAI.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        console2.log("total assets before harvest", veloCTokenUSDCDAI.totalAssets());

        vm.startPrank(gauge.voter());
        IERC20(_VELO_ADDRESS).approve(address(gauge), 10e18);
        gauge.notifyRewardAmount(10e18);
        vm.stopPrank();

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 1 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkUSDC.updateAnswer(chainlinkUSDC.latestAnswer());

        // Mint some extra rewards for Vault.
        uint256 earned = gauge.earned(address(veloCTokenUSDCDAI));
        uint256 amount = (earned * 84) / 100;
        SwapperLib.Swap memory swapAction;
        swapAction.inputToken = _VELO_ADDRESS;
        swapAction.inputAmount = amount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _VELO_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(veloCTokenUSDCDAI),
            type(uint256).max
        );
        swapAction.slippage = 50e16;

        veloCTokenUSDCDAI.harvest(abi.encode(swapAction, 1e14));

        console2.log("total assets after first harvest:", veloCTokenUSDCDAI.totalAssets());

        assertEq(
            veloCTokenUSDCDAI.totalAssets(),
            assets + 77777,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.warp(block.timestamp + 8 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkUSDC.updateAnswer(chainlinkUSDC.latestAnswer());

        // Mint some extra rewards for Vault.
        earned = gauge.earned(address(veloCTokenUSDCDAI));
        amount = (earned * 84) / 100;
        swapAction.inputAmount = amount;
        swapAction.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(veloCTokenUSDCDAI),
            type(uint256).max
        );
        veloCTokenUSDCDAI.harvest(abi.encode(swapAction, 1e14));

        console2.log("total assets after second harvest", veloCTokenUSDCDAI.totalAssets());

        vm.warp(block.timestamp + 7 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkUSDC.updateAnswer(chainlinkUSDC.latestAnswer());

        console2.log("Total Assets", veloCTokenUSDCDAI.totalAssets());
        console2.log("Assets", assets);

        assertGt(
            veloCTokenUSDCDAI.totalAssets(),
            assets + 77777,
            "Total Assets should greater than original deposit plus initial mint."
        );

        vm.prank(user1);
        veloCTokenUSDCDAI.withdraw(assets, user1, user1);
    }
}
