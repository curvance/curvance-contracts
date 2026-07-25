// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    TestBaseOracleManager
} from "tests/oracles/OracleManager/TestBaseOracleManager.sol";

import {
    VelodromeStableLPAdaptor
} from "contracts/oracles/adaptors/velodrome/VelodromeStableLPAdaptor.sol";
import {
    VelodromeVolatileLPAdaptor
} from "contracts/oracles/adaptors/velodrome/VelodromeVolatileLPAdaptor.sol";
import {MockOracleAdaptor} from "contracts/mocks/MockOracleAdaptor.sol";
import {MockToken} from "contracts/mocks/MockToken.sol";
import {
    SafeTransferLib
} from "contracts/libraries/external/SafeTransferLib.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {IOracleManager} from "contracts/interfaces/IOracleManager.sol";
import {
    IVeloPool
} from "contracts/interfaces/external/velodrome/IVeloPool.sol";

interface ITokenTransferCallback {
    function onTokenTransfer() external;
}

contract CallbackToken is MockToken {
    address public callbackSender;
    ITokenTransferCallback public callbackTarget;

    constructor() MockToken("Callback Token", "CALL", 18) {}

    function configureCallback(address sender, ITokenTransferCallback target)
        external
    {
        callbackSender = sender;
        callbackTarget = target;
    }

    function transfer(address to, uint256 amount)
        public
        override
        returns (bool)
    {
        bool success = super.transfer(to, amount);

        if (
            msg.sender == callbackSender
                && address(callbackTarget) != address(0)
        ) {
            callbackTarget.onTokenTransfer();
        }

        return success;
    }
}

contract VelodromePoolStateWindowFixture is IVeloPool {
    address public immutable override token0;
    address public immutable override token1;
    address public immutable override factory;
    bool public immutable override stable;

    uint256 public override totalSupply;
    uint112 internal _reserve0;
    uint112 internal _reserve1;
    bool public locked;

    constructor(
        address token0_,
        address token1_,
        bool stable_,
        uint112 reserve0_,
        uint112 reserve1_,
        uint256 totalSupply_
    ) {
        token0 = token0_;
        token1 = token1_;
        stable = stable_;
        factory = address(this);
        _reserve0 = reserve0_;
        _reserve1 = reserve1_;
        totalSupply = totalSupply_;
    }

    function getK() external view override returns (uint256) {
        return uint256(_reserve0) * uint256(_reserve1);
    }

    function getReserves()
        external
        view
        override
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    {
        return (_reserve0, _reserve1, uint32(block.timestamp));
    }

    // Velodrome's explicit swap hook runs before the pool updates its stored
    // reserves and without changing LP total supply. The adaptor therefore
    // observes the same coherent pre-swap state as the baseline quote.
    function quoteDuringSwapCallback(IOracleManager oracleManager)
        external
        returns (uint256 price, uint256 errorCode)
    {
        require(!locked, "LOCKED");
        locked = true;
        (price, errorCode) = oracleManager.getPrice(address(this), true, false);
        locked = false;
    }

    // Velodrome burn reduces LP total supply before its token transfers and
    // updates stored reserves only after both transfers. A callback-capable
    // token can therefore price the pool after the supply reduction while the
    // adaptor still observes the old reserves.
    function burnTo(address recipient, uint256 burnAmount) external {
        require(!locked, "LOCKED");
        locked = true;

        uint256 supplyBefore = totalSupply;
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = (burnAmount * balance0) / supplyBefore;
        uint256 amount1 = (burnAmount * balance1) / supplyBefore;

        totalSupply = supplyBefore - burnAmount;

        SafeTransferLib.safeTransfer(token0, recipient, amount0);
        SafeTransferLib.safeTransfer(token1, recipient, amount1);

        _reserve0 = uint112(IERC20(token0).balanceOf(address(this)));
        _reserve1 = uint112(IERC20(token1).balanceOf(address(this)));
        locked = false;
    }
}

    contract VelodromeLPReadOnlyReentrancyProof is
        TestBaseOracleManager,
        ITokenTransferCallback
    {
        CallbackToken internal token0;
        MockToken internal token1;
        MockOracleAdaptor internal underlyingAdaptor;
        VelodromeStableLPAdaptor internal stableAdaptor;
        VelodromeVolatileLPAdaptor internal volatileAdaptor;
        VelodromePoolStateWindowFixture internal stablePool;
        VelodromePoolStateWindowFixture internal volatilePool;

        VelodromePoolStateWindowFixture internal callbackPool;
        uint256 internal callbackPrice;
        uint256 internal callbackError;
        bool internal callbackObserved;
        bool internal callbackObservedLocked;

        function setUp() public override {
            vm.warp(1_700_000_000);
            _deployCentralRegistry();
            _deployOracleManager();

            token0 = new CallbackToken();
            token1 = new MockToken("Token 1", "T1", 18);

            underlyingAdaptor = new MockOracleAdaptor(
                ICentralRegistry(address(centralRegistry)),
                "LP Underlying Mock"
            );
            stableAdaptor = new VelodromeStableLPAdaptor(
                ICentralRegistry(address(centralRegistry))
            );
            volatileAdaptor = new VelodromeVolatileLPAdaptor(
                ICentralRegistry(address(centralRegistry))
            );

            oracleManager.addApprovedAdaptor(address(underlyingAdaptor));
            oracleManager.addApprovedAdaptor(address(stableAdaptor));
            oracleManager.addApprovedAdaptor(address(volatileAdaptor));

            _addUnderlying(address(token0));
            _addUnderlying(address(token1));

            stablePool = new VelodromePoolStateWindowFixture(
                address(token0), address(token1), true, 1e18, 1e18, 2e18
            );
            volatilePool = new VelodromePoolStateWindowFixture(
                address(token0), address(token1), false, 1e18, 1e18, 2e18
            );

            token0.transfer(address(stablePool), 1e18);
            token1.transfer(address(stablePool), 1e18);
            token0.transfer(address(volatilePool), 1e18);
            token1.transfer(address(volatilePool), 1e18);

            stableAdaptor.addAsset(address(stablePool));
            volatileAdaptor.addAsset(address(volatilePool));

            oracleManager.addAssetPricingAdaptor(
                address(stablePool), address(stableAdaptor), 100, 50, 100, 50
            );
            oracleManager.addAssetPricingAdaptor(
                address(volatilePool),
                address(volatileAdaptor),
                100,
                50,
                100,
                50
            );
        }

        function test_swapCallbackPreservesStableAndVolatileQuotes() public {
            (uint256 stableBefore, uint256 stableErrorBefore) =
                _quote(address(stablePool));
            (uint256 stableDuring, uint256 stableErrorDuring) = stablePool.quoteDuringSwapCallback(
                IOracleManager(address(oracleManager))
            );

            assertEq(stableErrorBefore, 0);
            assertEq(stableErrorDuring, 0);
            assertGt(stableBefore, 0);
            assertEq(stableDuring, stableBefore);

            (uint256 volatileBefore, uint256 volatileErrorBefore) =
                _quote(address(volatilePool));
            (uint256 volatileDuring, uint256 volatileErrorDuring) = volatilePool.quoteDuringSwapCallback(
                IOracleManager(address(oracleManager))
            );

            assertEq(volatileErrorBefore, 0);
            assertEq(volatileErrorDuring, 0);
            assertGt(volatileBefore, 0);
            assertEq(volatileDuring, volatileBefore);
        }

        function test_stableBurnTransferWindowInflatesThenRestoresQuote()
            public
        {
            _assertBurnWindow(stablePool);
        }

        function test_volatileBurnTransferWindowInflatesThenRestoresQuote()
            public
        {
            _assertBurnWindow(volatilePool);
        }

        function test_staticPriceGuardCapsStableBurnTransferWindow() public {
            (uint256 baseline, uint256 baselineError) =
                _quote(address(stablePool));
            assertEq(baselineError, 0);
            assertGt(baseline, 0);

            stableAdaptor.setGuardedPriceConfig(
                address(stablePool), true, 0, 0, baseline, 0
            );

            _armCallback(stablePool);
            stablePool.burnTo(address(this), stablePool.totalSupply() / 2);
            (uint256 finalizedPrice, uint256 finalizedError) =
                _quote(address(stablePool));

            assertTrue(callbackObserved);
            assertTrue(callbackObservedLocked);
            assertEq(callbackError, 0);
            assertEq(finalizedError, 0);
            assertEq(callbackPrice, baseline);
            assertEq(finalizedPrice, baseline);
        }

        function _addUnderlying(address asset) internal {
            underlyingAdaptor.addAsset(asset);
            underlyingAdaptor.setPrice(asset, 1e18, 1e18);
            oracleManager.addAssetPricingAdaptor(
                asset, address(underlyingAdaptor), 100, 50, 100, 50
            );
        }

        function _assertBurnWindow(VelodromePoolStateWindowFixture pool)
            internal
        {
            (uint256 baseline, uint256 baselineError) = _quote(address(pool));
            assertEq(baselineError, 0);
            assertGt(baseline, 0);

            _armCallback(pool);
            pool.burnTo(address(this), pool.totalSupply() / 2);
            (uint256 finalizedPrice, uint256 finalizedError) =
                _quote(address(pool));

            assertTrue(callbackObserved);
            assertTrue(callbackObservedLocked);
            assertEq(callbackError, 0);
            assertEq(finalizedError, 0);
            assertApproxEqAbs(callbackPrice, baseline * 2, 2);
            assertApproxEqAbs(finalizedPrice, baseline, 2);
        }

        function onTokenTransfer() external override {
            require(msg.sender == address(token0), "UNEXPECTED_CALLBACK_TOKEN");

            callbackObserved = true;
            callbackObservedLocked = callbackPool.locked();
            (callbackPrice, callbackError) =
                oracleManager.getPrice(address(callbackPool), true, false);
        }

        function _armCallback(VelodromePoolStateWindowFixture pool) internal {
            callbackPool = pool;
            callbackPrice = 0;
            callbackError = 0;
            callbackObserved = false;
            callbackObservedLocked = false;
            token0.configureCallback(
                address(pool), ITokenTransferCallback(address(this))
            );
        }

        function _quote(address asset)
            internal
            view
            returns (uint256 price, uint256 errorCode)
        {
            return oracleManager.getPrice(asset, true, false);
        }
    }
