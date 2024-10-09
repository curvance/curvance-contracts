// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { TestBaseMarket } from "tests/market/TestBaseMarket.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { FixedPointMathLib } from "contracts/libraries/FixedPointMathLib.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IStakedGMX } from "contracts/interfaces/external/gmx/IStakedGMX.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { StakedGMXPToken, IERC20 } from "contracts/market/token/StakedGMXPToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { MockV3Aggregator } from "contracts/mocks/MockV3Aggregator.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

contract TestStakedGMXPToken is TestBaseMarket {
    address internal _GMX_REWARD_ROUTER =
        0x159854e14A862Df9E39E1D128b8e5F70B4A3cE9B;
    address internal _GMX_FEE_GMX_TRACKER =
        0xd2D1162512F927a7e282Ef43a362659E4F2a728F;
    address internal _GMX_STAKED_GMX_TRACKER =
        0x908C4D94D34924765f1eDc22A1DD098397c59dD4;
    address internal _GMX_ADDRESS = 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;
    address internal _UNISWAP_V3_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    IERC20 public gmx = IERC20(_GMX_ADDRESS);
    StakedGMXPToken public cStakedGMX;
    MockV3Aggregator public chainlinkWETH;
    MockV3Aggregator public chainlinkGMX;

    receive() external payable {}

    fallback() external payable {}

    function setUp() public override {
        _fork("ETH_NODE_URI_ARBITRUM", 180000000);

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();

        centralRegistry.addHarvester(address(this));
        centralRegistry.setFeeManager(address(this));

        cStakedGMX = new StakedGMXPToken(
            ICentralRegistry(address(centralRegistry)),
            gmx,
            address(marketManager),
            _GMX_REWARD_ROUTER,
            _WETH_ADDRESS
        );

        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );
        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkWETH = new MockV3Aggregator(8, 3000e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _WETH_ADDRESS,
            address(chainlinkWETH),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _WETH_ADDRESS,
            address(chainlinkAdaptor)
        );

        chainlinkGMX = new MockV3Aggregator(8, 45e8, 1e50, 1e6);
        chainlinkAdaptor.addAsset(
            _GMX_ADDRESS,
            address(chainlinkGMX),
            0,
            true
        );
        oracleManager.addAssetPriceFeed(
            _GMX_ADDRESS,
            address(chainlinkAdaptor)
        );

        centralRegistry.setSlippageLimit(6000);
    }

    function testGmxStakedGMX() public {
        centralRegistry.setExternalCallDataChecker(
            _UNISWAP_V3_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_ROUTER))
        );

        uint256 assets = 100e18;
        deal(_GMX_ADDRESS, user1, assets);
        deal(_GMX_ADDRESS, address(this), 42069);

        gmx.approve(address(cStakedGMX), 42069);
        marketManager.listToken(address(cStakedGMX));

        vm.prank(user1);
        gmx.approve(address(cStakedGMX), assets);

        vm.prank(user1);
        cStakedGMX.deposit(assets, user1);

        uint256 initialAssets = cStakedGMX.totalAssets();

        assertEq(
            initialAssets,
            assets + 42069,
            "Total Assets should equal user deposit plus initial mint."
        );

        // Advance time to earn rewards
        skip(1 days);
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());
        chainlinkGMX.updateAnswer(chainlinkGMX.latestAnswer());

        IStakedGMX(_GMX_FEE_GMX_TRACKER).updateRewards();
        uint256 amount = IStakedGMX(_GMX_FEE_GMX_TRACKER).claimable(
            address(cStakedGMX)
        );
        amount -= FixedPointMathLib.mulDiv(
            amount,
            centralRegistry.protocolHarvestFee(),
            1e18
        );

        SwapperLib.Swap memory swapData;
        swapData.inputToken = _WETH_ADDRESS;
        swapData.inputAmount = amount;
        swapData.outputToken = _GMX_ADDRESS;
        swapData.target = _UNISWAP_V3_ROUTER;
        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _GMX_ADDRESS;
        params.fee = 10000;
        params.recipient = address(cStakedGMX);
        params.deadline = block.timestamp;
        params.amountIn = amount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
        swapData.slippage = 50e16;

        cStakedGMX.harvest(abi.encode(swapData));

        assertEq(
            cStakedGMX.totalAssets(),
            initialAssets,
            "New Total Assets should equal user deposit plus initial mint."
        );

        uint256 updatedStakedBalance = IStakedGMX(_GMX_STAKED_GMX_TRACKER)
            .stakedAmounts(address(cStakedGMX));

        skip(8 days);
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());
        chainlinkGMX.updateAnswer(chainlinkGMX.latestAnswer());

        IStakedGMX(_GMX_FEE_GMX_TRACKER).updateRewards();
        amount = IStakedGMX(_GMX_FEE_GMX_TRACKER).claimable(
            address(cStakedGMX)
        );

        amount -= FixedPointMathLib.mulDiv(
            amount,
            centralRegistry.protocolHarvestFee(),
            1e18
        );

        swapData.inputAmount = amount;
        params.deadline = block.timestamp;
        params.amountIn = amount;
        swapData.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );

        cStakedGMX.harvest(abi.encode(swapData));

        // Now that first vest should have occurred, assets should
        // equal previous staked balance.
        assertEq(
            cStakedGMX.totalAssets(),
            updatedStakedBalance,
            "Total Assets should equal user deposit plus initial mint and previous vest."
        );

        skip(7 days);
        chainlinkWETH.updateAnswer(chainlinkWETH.latestAnswer());
        chainlinkGMX.updateAnswer(chainlinkGMX.latestAnswer());

        assertGt(
            cStakedGMX.totalAssets(),
            assets + 42069,
            "Total Assets should greater than original deposit plus initial mint."
        );

        vm.prank(user1);
        cStakedGMX.withdraw(assets, user1, user1);
    }
}
