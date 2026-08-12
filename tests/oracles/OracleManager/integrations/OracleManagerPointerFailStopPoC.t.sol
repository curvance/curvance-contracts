// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {TestBaseMarketIsolated} from "tests/market/TestBaseMarketIsolated.sol";

import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";

contract OracleManagerPointerFailStopPoC is TestBaseMarketIsolated {
    uint256 internal constant _BORROW_AMOUNT = 100e6;

    address internal outsider = makeAddr("pointerOutsider");
    address internal codeLessOracleManager = makeAddr("codeLessOracleManager");

    struct BorrowState {
        uint256 receiverBalance;
        uint256 accountDebt;
        uint256 marketDebt;
        uint256 marketCash;
        uint256 totalAssets;
        uint256 accountAssetCount;
    }

    function setUp() public override {
        super.setUp();

        _prepareDAI(address(this), 77_777);
        _prepareUSDC(address(this), 77_777);
        dai.approve(address(borrowableCDAI), type(uint256).max);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        marketManagerIsolated.listTokens(
            address(borrowableCDAI), address(borrowableCUSDC)
        );
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 0, 100_000e6);

        _prepareUSDC(address(this), 100_000e6);
        borrowableCUSDC.deposit(100_000e6, address(this));

        _prepareDAI(user1, 1_000e18);
        vm.startPrank(user1);
        dai.approve(address(borrowableCDAI), 1_000e18);
        borrowableCDAI.depositAsCollateral(1_000e18, user1);
        vm.stopPrank();
    }

    function test_authorizedCodeLessPointerFailStopsBorrowAtomicallyAndRestoreRecovers()
        public
    {
        address validOracleManager = address(oracleManager);
        assertEq(codeLessOracleManager.code.length, 0, "bad pointer has code");

        vm.prank(outsider);
        vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
        centralRegistry.setOracleManager(codeLessOracleManager);
        assertEq(
            centralRegistry.oracleManager(),
            validOracleManager,
            "unauthorized caller changed pointer"
        );

        centralRegistry.setOracleManager(codeLessOracleManager);
        assertEq(
            centralRegistry.oracleManager(),
            codeLessOracleManager,
            "authorized bad pointer was not installed"
        );

        vm.prank(outsider);
        vm.expectRevert(CentralRegistry.CentralRegistry__Unauthorized.selector);
        centralRegistry.setOracleManager(validOracleManager);
        assertEq(
            centralRegistry.oracleManager(),
            codeLessOracleManager,
            "unauthorized caller restored pointer"
        );

        BorrowState memory beforeFailedBorrow = _borrowState();
        vm.prank(user1);
        vm.expectRevert();
        borrowableCUSDC.borrow(_BORROW_AMOUNT, user1);
        _assertBorrowStateEq(
            _borrowState(),
            beforeFailedBorrow,
            "failed borrow did not roll back"
        );

        centralRegistry.setOracleManager(validOracleManager);
        assertEq(
            centralRegistry.oracleManager(),
            validOracleManager,
            "valid pointer was not restored"
        );

        vm.prank(user1);
        borrowableCUSDC.borrow(_BORROW_AMOUNT, user1);

        BorrowState memory recovered = _borrowState();
        assertEq(
            recovered.receiverBalance,
            beforeFailedBorrow.receiverBalance + _BORROW_AMOUNT,
            "restored borrow did not transfer assets"
        );
        assertEq(
            recovered.accountDebt,
            beforeFailedBorrow.accountDebt + _BORROW_AMOUNT,
            "restored borrow did not persist account debt"
        );
        assertEq(
            recovered.marketDebt,
            beforeFailedBorrow.marketDebt + _BORROW_AMOUNT,
            "restored borrow did not persist market debt"
        );
        assertEq(
            recovered.marketCash,
            beforeFailedBorrow.marketCash - _BORROW_AMOUNT,
            "restored borrow did not reduce market cash"
        );
        assertEq(
            recovered.totalAssets,
            beforeFailedBorrow.totalAssets,
            "restored borrow changed lender assets"
        );
        assertEq(
            recovered.accountAssetCount,
            beforeFailedBorrow.accountAssetCount + 1,
            "restored borrow did not add debt asset"
        );
    }

    function _borrowState() internal view returns (BorrowState memory state) {
        state.receiverBalance = usdc.balanceOf(user1);
        state.accountDebt = borrowableCUSDC.debtBalance(user1);
        state.marketDebt = borrowableCUSDC.marketOutstandingDebt();
        state.marketCash = usdc.balanceOf(address(borrowableCUSDC));
        state.totalAssets = borrowableCUSDC.totalAssets();
        state.accountAssetCount = marketManagerIsolated.assetsOf(user1).length;
    }

    function _assertBorrowStateEq(
        BorrowState memory actual,
        BorrowState memory expected,
        string memory reason
    ) internal pure {
        require(actual.receiverBalance == expected.receiverBalance, reason);
        require(actual.accountDebt == expected.accountDebt, reason);
        require(actual.marketDebt == expected.marketDebt, reason);
        require(actual.marketCash == expected.marketCash, reason);
        require(actual.totalAssets == expected.totalAssets, reason);
        require(actual.accountAssetCount == expected.accountAssetCount, reason);
    }
}
