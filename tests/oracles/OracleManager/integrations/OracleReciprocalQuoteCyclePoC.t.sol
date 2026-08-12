// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";
import {
    BaseOracleAdaptor
} from "contracts/oracles/adaptors/BaseOracleAdaptor.sol";
import {
    UniswapV3Adaptor
} from "contracts/oracles/adaptors/uniswap/UniswapV3Adaptor.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {
    IStaticOracle
} from "contracts/interfaces/external/uniswap/IStaticOracle.sol";

contract OracleReciprocalQuoteCyclePoC is Test {
    uint256 internal constant _PRICE = 1e18;
    uint256 internal constant _BOUNDED_PRICE_GAS = 1_000_000;

    address internal outsider = makeAddr("outsider");

    CentralRegistry internal centralRegistry;
    OracleManager internal oracleManager;
    FixedPriceAdaptor internal fixedPriceAdaptor;
    UniswapV3Adaptor internal uniswapAdaptor;
    MockStaticOracle internal staticOracle;

    MockToken internal tokenA;
    MockToken internal tokenB;
    MockToken internal tokenC;

    MockUniswapV3Pool internal poolAB;
    MockUniswapV3Pool internal poolBC;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_800_000_000);

        tokenA = new MockToken("Token A", "A", 18);
        tokenB = new MockToken("Token B", "B", 18);
        tokenC = new MockToken("Token C", "C", 18);

        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            block.timestamp + 1,
            address(0),
            address(tokenC)
        );
        oracleManager =
            new OracleManager(ICentralRegistry(address(centralRegistry)));
        centralRegistry.setOracleManager(address(oracleManager));

        fixedPriceAdaptor =
            new FixedPriceAdaptor(ICentralRegistry(address(centralRegistry)));
        staticOracle = new MockStaticOracle(_PRICE);
        uniswapAdaptor = new UniswapV3Adaptor(
            ICentralRegistry(address(centralRegistry)),
            IStaticOracle(address(staticOracle)),
            address(tokenC)
        );

        oracleManager.addApprovedAdaptor(address(fixedPriceAdaptor));
        oracleManager.addApprovedAdaptor(address(uniswapAdaptor));

        poolAB = new MockUniswapV3Pool(address(tokenA), address(tokenB));
        poolBC = new MockUniswapV3Pool(address(tokenB), address(tokenC));
    }

    function test_reciprocalRoutePassesAdmissionThenBreaksBoundedReadUntilEdgeRemoval()
        public
    {
        fixedPriceAdaptor.addAsset(address(tokenB), _PRICE);
        _addRoute(address(tokenB), address(fixedPriceAdaptor));

        uniswapAdaptor.addAsset(address(tokenA), _config(address(poolAB)));
        _addRoute(address(tokenA), address(uniswapAdaptor));
        _assertBoundedPrice(address(tokenA), _PRICE);

        vm.startPrank(outsider);
        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector
        );
        uniswapAdaptor.addAsset(address(tokenB), _config(address(poolAB)));
        vm.expectRevert(OracleManager.OracleManager__Unauthorized.selector);
        oracleManager.removeAssetPricingAdaptor(
            address(tokenA), address(uniswapAdaptor)
        );
        vm.stopPrank();

        // Admission samples B -> A before the B route is inserted. At that
        // moment A -> B still terminates at the fixed adaptor, so admission
        // succeeds even though the committed graph is reciprocal.
        uniswapAdaptor.addAsset(address(tokenB), _config(address(poolAB)));
        _addRoute(address(tokenB), address(uniswapAdaptor));

        address[] memory aRoutes =
            oracleManager.getPricingAdaptors(address(tokenA));
        address[] memory bRoutes =
            oracleManager.getPricingAdaptors(address(tokenB));
        assertEq(aRoutes.length, 1, "A route did not persist");
        assertEq(bRoutes.length, 2, "reciprocal B route did not persist");
        assertEq(bRoutes[1], address(uniswapAdaptor), "wrong B route");
        (,,,, address aQuoteToken) =
            uniswapAdaptor.assetConfig(address(tokenA));
        (,,,, address bQuoteToken) =
            uniswapAdaptor.assetConfig(address(tokenB));
        assertEq(aQuoteToken, address(tokenB), "A quote edge changed");
        assertEq(bQuoteToken, address(tokenA), "B quote edge changed");

        _assertBoundedPriceFailure(address(tokenA));

        oracleManager.removeAssetPricingAdaptor(
            address(tokenB), address(uniswapAdaptor)
        );
        _assertBoundedPrice(address(tokenA), _PRICE);
        _assertBoundedPrice(address(tokenB), _PRICE);
    }

    function test_linkedAdaptorConfigOverwriteCreatesCycleWithoutRouteResamplingAndRestores()
        public
    {
        fixedPriceAdaptor.addAsset(address(tokenC), _PRICE);
        _addRoute(address(tokenC), address(fixedPriceAdaptor));

        UniswapV3Adaptor.AssetConfig memory bToC = _config(address(poolBC));
        uniswapAdaptor.addAsset(address(tokenB), bToC);
        _addRoute(address(tokenB), address(uniswapAdaptor));

        uniswapAdaptor.addAsset(address(tokenA), _config(address(poolAB)));
        _addRoute(address(tokenA), address(uniswapAdaptor));
        _assertBoundedPrice(address(tokenA), _PRICE);
        _assertBoundedPrice(address(tokenB), _PRICE);

        UniswapV3Adaptor.AssetConfig memory bToA = _config(address(poolAB));
        vm.prank(outsider);
        vm.expectRevert(
            BaseOracleAdaptor.BaseOracleAdaptor__Unauthorized.selector
        );
        uniswapAdaptor.addAsset(address(tokenB), bToA);

        // B is already linked in OracleManager. Updating its adaptor config
        // performs no manager-level route admission sample, creating A <-> B.
        uniswapAdaptor.addAsset(address(tokenB), bToA);
        address[] memory bRoutes =
            oracleManager.getPricingAdaptors(address(tokenB));
        assertEq(bRoutes.length, 1, "B route count changed on overwrite");
        assertEq(bRoutes[0], address(uniswapAdaptor), "B route changed");
        (,,,, address bQuoteToken) =
            uniswapAdaptor.assetConfig(address(tokenB));
        assertEq(bQuoteToken, address(tokenA), "overwrite did not persist");
        _assertBoundedPriceFailure(address(tokenA));

        uniswapAdaptor.addAsset(address(tokenB), bToC);
        (,,,, bQuoteToken) = uniswapAdaptor.assetConfig(address(tokenB));
        assertEq(bQuoteToken, address(tokenC), "restored edge did not persist");
        _assertBoundedPrice(address(tokenA), _PRICE);
        _assertBoundedPrice(address(tokenB), _PRICE);
    }

    function _addRoute(address asset, address adaptor) internal {
        oracleManager.addAssetPricingAdaptor(asset, adaptor, 100, 50, 100, 50);
    }

    function _config(address pool)
        internal
        pure
        returns (UniswapV3Adaptor.AssetConfig memory config)
    {
        config.priceSource = pool;
        config.secondsAgo = 900;
    }

    function _assertBoundedPrice(address asset, uint256 expected) internal {
        (bool success, bytes memory returnData) = address(oracleManager)
        .staticcall{gas: _BOUNDED_PRICE_GAS}(
            abi.encodeCall(OracleManager.getPrice, (asset, true, false))
        );
        assertTrue(success, "bounded price call failed");
        (uint256 price, uint256 errorCode) =
            abi.decode(returnData, (uint256, uint256));
        assertEq(price, expected, "unexpected bounded price");
        assertEq(errorCode, 0, "unexpected bounded error");
    }

    function _assertBoundedPriceFailure(address asset) internal {
        (bool success, bytes memory returnData) = address(oracleManager)
        .staticcall{gas: _BOUNDED_PRICE_GAS}(
            abi.encodeCall(OracleManager.getPrice, (asset, true, false))
        );
        assertFalse(success, "reciprocal graph unexpectedly priced");
        assertEq(returnData.length, 0, "unexpected bounded failure payload");
    }
}

contract FixedPriceAdaptor is BaseOracleAdaptor {
    mapping(address => uint256) internal _prices;

    constructor(ICentralRegistry cr) BaseOracleAdaptor(cr, "FixedPricePoC") {}

    function addAsset(address asset, uint256 price) external {
        _checkElevatedPermissions();
        _checkNotZeroAddress(asset);
        _prices[asset] = price;
        isSupportedAsset[asset] = true;
    }

    function _getPrice(address asset, bool inUSD)
        internal
        view
        override
        returns (PricingResult memory result)
    {
        result.price = _prices[asset];
        result.inUSD = inUSD;
        result.hadError = result.price == 0;
    }

    function _wipeAssetConfigs(address asset) internal override {
        delete _prices[asset];
    }
}

contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract MockStaticOracle {
    uint256 internal immutable _quoteAmount;

    constructor(uint256 quoteAmount_) {
        _quoteAmount = quoteAmount_;
    }

    function quoteSpecificPoolsWithTimePeriod(
        uint128,
        address,
        address,
        address[] calldata,
        uint32
    ) external view returns (uint256) {
        return _quoteAmount;
    }
}
