// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { VelodromeStablePToken, IVeloGauge, IVeloRouter, IVeloPairFactory, IERC20 } from "contracts/market/token/VelodromeStablePToken.sol";
import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

contract TestVelodromeStablePToken is TestBaseMarket {
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

    VelodromeStablePToken public pUSDCDAI;
    MockV3Aggregator public chainlinkVELO;
    MockV3Aggregator public chainlinkUSDC;

    receive() external payable {}

    fallback() external payable {}

    // this is to use address(this) as mock pToken address
    function tokenType() external pure returns (uint256) {
        return 1;
    }

    function setUp() public override {
        _fork("ETH_NODE_URI_OPTIMISM", 109095500);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();

        centralRegistry.addHarvester(address(this));
        centralRegistry.setFeeManager(address(this));
        centralRegistry.setExternalCalldataChecker(
            address(veloRouter),
            address(new MockCalldataChecker(address(veloRouter)))
        );

        pUSDCDAI = new VelodromeStablePToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_USDC_DAI),
            address(marketManager),
            gauge,
            veloPairFactory,
            veloRouter
        );

        vm.warp(veCVE.nextEpochStartTime());

        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkVELO = new MockV3Aggregator(8, 0.06e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _VELO_ADDRESS,
            address(chainlinkVELO),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _VELO_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkUSDC = new MockV3Aggregator(8, 1e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            address(chainlinkUSDC),
            0,
            true
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
        deal(_USDC_DAI, address(this), 42069);

        IERC20(_USDC_DAI).approve(address(pUSDCDAI), 42069);
        marketManager.listToken(address(pUSDCDAI));

        vm.prank(user1);
        IERC20(_USDC_DAI).approve(address(pUSDCDAI), assets);

        vm.prank(user1);
        pUSDCDAI.deposit(assets, user1);

        assertEq(
            pUSDCDAI.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.startPrank(gauge.voter());
        IERC20(_VELO_ADDRESS).approve(address(gauge), 10e18);
        gauge.notifyRewardAmount(10e18);
        vm.stopPrank();

        // Advance time to earn CRV and CVX rewards
        vm.warp(block.timestamp + 1 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkUSDC.updateAnswer(chainlinkUSDC.latestAnswer());

        // Mint some extra rewards for Vault.
        uint256 earned = gauge.earned(address(pUSDCDAI));
        uint256 amount = (earned * 84) / 100;
        SwapperLib.Swap memory swapData;
        swapData.inputToken = _VELO_ADDRESS;
        swapData.inputAmount = amount;
        swapData.outputToken = _USDC_ADDRESS;
        swapData.target = address(veloRouter);
        IVeloRouter.Route[] memory routes = new IVeloRouter.Route[](1);
        routes[0].from = _VELO_ADDRESS;
        routes[0].to = _USDC_ADDRESS;
        routes[0].stable = false;
        routes[0].factory = address(veloPairFactory);
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(pUSDCDAI),
            type(uint256).max
        );
        swapData.slippage = 50e16;

        pUSDCDAI.harvest(abi.encode(swapData));

        assertEq(
            pUSDCDAI.totalAssets(),
            assets + 42069,
            "Total Assets should equal user deposit plus initial mint."
        );

        vm.warp(block.timestamp + 8 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkUSDC.updateAnswer(chainlinkUSDC.latestAnswer());

        // Mint some extra rewards for Vault.
        earned = gauge.earned(address(pUSDCDAI));
        amount = (earned * 84) / 100;
        swapData.inputAmount = amount;
        swapData.call = abi.encodeWithSelector(
            IVeloRouter.swapExactTokensForTokens.selector,
            amount,
            0,
            routes,
            address(pUSDCDAI),
            type(uint256).max
        );
        pUSDCDAI.harvest(abi.encode(swapData));

        vm.warp(block.timestamp + 7 days);
        chainlinkVELO.updateAnswer(chainlinkVELO.latestAnswer());
        chainlinkUSDC.updateAnswer(chainlinkUSDC.latestAnswer());

        assertGt(
            pUSDCDAI.totalAssets(),
            assets + 42069,
            "Total Assets should greater than original deposit plus initial mint."
        );

        vm.prank(user1);
        pUSDCDAI.withdraw(assets, user1, user1);
    }
}
