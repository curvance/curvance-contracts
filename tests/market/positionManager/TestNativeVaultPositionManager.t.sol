// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import { NativeVaultPositionManager } from "contracts/market/position-management/NativeVaultPositionManager.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IBorrowableCToken } from "contracts/interfaces/IBorrowableCToken.sol";
import { ICToken, AccountSnapshot } from "contracts/interfaces/ICToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import { console2 } from "forge-std/console2.sol";

// This test suite uses SHMON as the collateral asset, and WMON as the collateral asset.
// An additional lending pool with a non-underlying borrowed asset are not included because of the 
// lack of liquidity on Monad testnet, so no swaps are included. 

contract TestNativeVaultPositionManager is TestBaseMarketIsolated {
    NativeVaultPositionManager public positionManager;

    address public constant SHMON_ADDRESS = 0x3a98250F98Dd388C211206983453837C8365BDc1;
    address public constant WMON_ADDRESS = 0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701;

    address public constant _CHAINLINK_ETH_USD_MONAD = 0x0c76859E85727683Eeba0C70Bc2e0F5781337818;

    SimpleCToken public simpleCSHMON;
    BorrowableCToken public borrowableCWMON;

    receive() external payable {}
    fallback() external payable {}

    function setUp() public override {

        _fork("ETH_NODE_URI_MONAD");

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();

        // Native vault position manager
        positionManager = new NativeVaultPositionManager(
            ICentralRegistry(address(centralRegistry)),
            address(marketManagerIsolated),
            WMON_ADDRESS
        );
        marketManagerIsolated.addPositionManager(address(positionManager));

        // deploy simpleCSHMON
        simpleCSHMON = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(SHMON_ADDRESS),
            address(marketManagerIsolated)
        );

        ChainlinkAdaptor adaptor = new ChainlinkAdaptor(ICentralRegistry(address(centralRegistry)));
        oracleManager.addApprovedAdaptor(address(adaptor));

        adaptor.addAsset(SHMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPriceFeed(SHMON_ADDRESS, address(adaptor));
        oracleManager.addCTokenSupport(address(simpleCSHMON));

        adaptor.addAsset(WMON_ADDRESS, true, _CHAINLINK_ETH_USD_MONAD, 0);
        oracleManager.addAssetPriceFeed(WMON_ADDRESS, address(adaptor));

        borrowableCWMON = _deployBorrowableCToken(WMON_ADDRESS);
        oracleManager.addCTokenSupport(address(borrowableCWMON));

        deal(SHMON_ADDRESS, address(this), 77777 ether);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), 77777 ether);
        deal(WMON_ADDRESS, address(this), 77777 ether);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), 77777 ether);

        marketManagerIsolated.listTokens(address(simpleCSHMON), address(borrowableCWMON));

        _setCTokenConfigBasic(address(simpleCSHMON), 1_000_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCWMON), 1_000_000e18, 1_000_000e18);

        // Provide WMON liquidity
        address liquidityProvider = makeAddr("liquidityProvider");
        deal(WMON_ADDRESS, liquidityProvider, 1_000_000 ether);
        vm.startPrank(liquidityProvider);
        IERC20(WMON_ADDRESS).approve(address(borrowableCWMON), type(uint256).max);
        borrowableCWMON.deposit(1_000_000 ether, liquidityProvider);
        vm.stopPrank();
    }

    function testLeverage_BorrowedWrappedNative_NoSwaps() public {

        deal(SHMON_ADDRESS, user1, 500e18);
        vm.startPrank(user1);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), type(uint256).max);
        uint256 depositShares = 500e18;
        simpleCSHMON.deposit(depositShares, user1);
        simpleCSHMON.postCollateral(depositShares);

        borrowableCWMON.borrow(1 ether, user1);

        uint256 amountForLeverage = positionManager.maxRemainingLeverageOf(
            user1,
            address(borrowableCWMON)
        ) / 2;

        console2.log("amountForLeverage", amountForLeverage);

        NativeVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCWMON));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSHMON));

        positionManager.leverage(leverageAction, 0.5e18);

        AccountSnapshot memory debtSnap = borrowableCWMON.getSnapshot(user1);
        AccountSnapshot memory collSnap = simpleCSHMON.getSnapshot(user1);

        assertGt(debtSnap.debtBalance, 1 ether, "Debt should increase after leverage");
        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");

        vm.stopPrank();
    }

    function testDepositAndLeverage_BorrowedWrappedNative_NoSwaps() public {
        vm.startPrank(user1);

        deal(SHMON_ADDRESS, user1, 500e18);
        IERC20(SHMON_ADDRESS).approve(address(positionManager), type(uint256).max);

        simpleCSHMON.setDelegateApproval(address(positionManager), true);

        uint256 amountForLeverage = 100 ether;

        NativeVaultPositionManager.LeverageAction memory leverageAction;
        leverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCWMON));
        leverageAction.borrowAssets = amountForLeverage;
        leverageAction.cToken = ICToken(address(simpleCSHMON));

        positionManager.depositAndLeverage(500e18, leverageAction, 0.05e18);

        AccountSnapshot memory collSnap = simpleCSHMON.getSnapshot(user1);
        AccountSnapshot memory debtSnap = borrowableCWMON.getSnapshot(user1);

        assertGt(collSnap.collateralPosted, 0, "Collateral should be posted");
        assertGt(debtSnap.debtBalance, 0, "Debt should be incurred");

        vm.stopPrank();
    }

    function testDeleverage_BorrowedWrappedNative_NoSwaps() public {

        testLeverage_BorrowedWrappedNative_NoSwaps();

        // Accrue a bit
        skip(20 minutes);
        borrowableCWMON.accrueIfNeeded();

        vm.startPrank(user1);

        AccountSnapshot memory debtBefore = borrowableCWMON.getSnapshot(user1);
        AccountSnapshot memory collBefore = simpleCSHMON.getSnapshot(user1);

        NativeVaultPositionManager.DeleverageAction memory deleverageAction;
        deleverageAction.cToken = ICToken(address(simpleCSHMON));
        deleverageAction.collateralAssets = collBefore.collateralPosted / 5;
        deleverageAction.borrowableCToken = IBorrowableCToken(address(borrowableCWMON));
        deleverageAction.repayAssets = debtBefore.debtBalance / 10;
        simpleCSHMON.approve(address(positionManager), type(uint256).max);

        positionManager.deleverage(deleverageAction, 0.5e18);

        AccountSnapshot memory debtAfter = borrowableCWMON.getSnapshot(user1);
        AccountSnapshot memory collAfter = simpleCSHMON.getSnapshot(user1);

        assertLt(debtAfter.debtBalance, debtBefore.debtBalance, "Debt should be reduced after deleverage");
        assertLt(collAfter.collateralPosted, collBefore.collateralPosted, "Collateral should be reduced after deleverage");

        vm.stopPrank();
    }
}
