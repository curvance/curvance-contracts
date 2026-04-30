// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseBorrowableCToken } from "../TestBaseBorrowableCToken.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";
import { FixedPointMathLib } from "contracts/market/token/BaseCToken.sol";
import "forge-std/console2.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ICollateralCTokenLike {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function postCollateral(uint256 shares) external;
}

contract FlashloanTest is TestBaseBorrowableCToken {

    uint256 flashloanAmount = 10_000e6;
    uint256 fee = FixedPointMathLib.mulDivUp(10_000e6, 4, 10_000);

    function setUp() public override {
        super.setUp();

        // Provide liquidity from user1
        vm.startPrank(user1);
        _prepareUSDC(address(user1), flashloanAmount);
        usdc.approve(address(borrowableCUSDC), flashloanAmount);
        borrowableCUSDC.deposit(flashloanAmount, address(user1));
        vm.stopPrank();
    }

    function test_flashloan_success() public {

        _prepareUSDC(address(this), 0); // reset USDC balance

        uint256 cUSDCBalanceBeforeFlashloan = usdc.balanceOf(address(borrowableCUSDC));

        bytes memory cUSDCBalanceBeforeFlashloanBytes = abi.encode(cUSDCBalanceBeforeFlashloan, false);

        borrowableCUSDC.flashLoan(flashloanAmount, cUSDCBalanceBeforeFlashloanBytes);

        uint256 cUSDCBalanceAfterFlashloan = usdc.balanceOf(address(borrowableCUSDC));

        assertEq(cUSDCBalanceAfterFlashloan, cUSDCBalanceBeforeFlashloan + fee, "cUSDC should have profited");

    }

    function test_flashloan_fail_whenAssetsReturnedIsLessThanAssets() public {
        _prepareUSDC(address(this), 0); // reset USDC balance
        
        uint256 cUSDCBalanceBeforeFlashloan = usdc.balanceOf(address(borrowableCUSDC));
        bytes memory cUSDCBalanceBeforeFlashloanBytes = abi.encode(cUSDCBalanceBeforeFlashloan, true);
        vm.expectRevert();
        borrowableCUSDC.flashLoan(flashloanAmount, cUSDCBalanceBeforeFlashloanBytes);
    }

    function test_flashloan_reentry_depositRedeem_doesNotExtractValue() public {
        FlashloanReentryReceiver receiver = new FlashloanReentryReceiver(
            address(usdc),
            address(borrowableCUSDC),
            address(pendleStrategyCTokenSTETH)
        );
        _prepareUSDC(address(receiver), fee);

        uint256 marketBalanceBefore = usdc.balanceOf(address(borrowableCUSDC));
        uint256 totalAssetsBefore = borrowableCUSDC.totalAssets();

        receiver.attackDepositRedeem(flashloanAmount);

        assertEq(usdc.balanceOf(address(receiver)), 0, "receiver only pays flashloan fee");
        assertEq(
            usdc.balanceOf(address(borrowableCUSDC)),
            marketBalanceBefore + fee,
            "market receives fee and principal is restored"
        );
        assertEq(
            borrowableCUSDC.totalAssets(),
            totalAssetsBefore + fee,
            "fee is the only market accounting delta"
        );
    }

    function test_flashloan_reentry_borrow_carriesEquivalentDebt() public {
        FlashloanReentryReceiver receiver = new FlashloanReentryReceiver(
            address(usdc),
            address(borrowableCUSDC),
            address(pendleStrategyCTokenSTETH)
        );

        deal(address(LP_wstETH_24Dec2025), address(receiver), _ONE);
        receiver.postCollateral(address(LP_wstETH_24Dec2025), _ONE - 1);

        uint256 loanAmount = flashloanAmount / 2;
        uint256 loanFee = FixedPointMathLib.mulDivUp(loanAmount, 4, 10_000);
        uint256 borrowAmount = 100e6;
        _prepareUSDC(address(receiver), loanFee);

        uint256 marketBalanceBefore = usdc.balanceOf(address(borrowableCUSDC));
        uint256 totalAssetsBefore = borrowableCUSDC.totalAssets();
        uint256 debtBefore = borrowableCUSDC.marketOutstandingDebt();

        receiver.attackBorrowDuringCallback(loanAmount, borrowAmount);

        assertEq(
            borrowableCUSDC.debtBalance(address(receiver)),
            borrowAmount,
            "callback borrow is recorded as normal debt"
        );
        assertEq(
            borrowableCUSDC.marketOutstandingDebt(),
            debtBefore + borrowAmount,
            "market debt tracks borrowed assets"
        );
        assertEq(
            usdc.balanceOf(address(receiver)),
            borrowAmount,
            "receiver keeps only the normally borrowed assets"
        );
        assertEq(
            usdc.balanceOf(address(borrowableCUSDC)),
            marketBalanceBefore + loanFee - borrowAmount,
            "cash movement equals fee less accounted debt"
        );
        assertEq(
            borrowableCUSDC.totalAssets(),
            totalAssetsBefore + loanFee,
            "flashloan fee is the only totalAssets increase"
        );
    }

    // Callback function for the flashloan
    function onFlashLoan(uint256 assets, uint256 assetsReturned, bytes calldata data) external returns (bytes32) {

        console2.log("onFlashLoan called");

        (uint256 cUSDCBalanceBeforeFlashloan, bool isRevert) = abi.decode(data, (uint256, bool));

        uint256 cUSDCBalanceDuringFlashloan = usdc.balanceOf(address(borrowableCUSDC));

        assertEq(assets, flashloanAmount, "assets should be the flashloan amount");
        assertEq(assetsReturned, flashloanAmount + fee, "assetsReturned should be the flashloan amount + fee");

        assertEq(cUSDCBalanceDuringFlashloan, cUSDCBalanceBeforeFlashloan - flashloanAmount, "cUSDC should have loaned out the flashloan amount");
        assertEq(usdc.balanceOf(address(this)), flashloanAmount, "this contract should have received the flashloan amount");

        if (!isRevert) {
            _prepareUSDC(address(this), assetsReturned);
        } else {
            // 0% interest loan
        }

        usdc.approve(address(borrowableCUSDC), flashloanAmount + fee);

        return bytes32(0);
    }



}

contract FlashloanReentryReceiver {
    uint8 internal constant MODE_DEPOSIT_REDEEM = 1;
    uint8 internal constant MODE_BORROW = 2;

    IERC20Like internal immutable asset;
    BorrowableCToken internal immutable borrowableCToken;
    ICollateralCTokenLike internal immutable collateralCToken;

    uint256 internal borrowAmount;

    constructor(address asset_, address borrowableCToken_, address collateralCToken_) {
        asset = IERC20Like(asset_);
        borrowableCToken = BorrowableCToken(borrowableCToken_);
        collateralCToken = ICollateralCTokenLike(collateralCToken_);
    }

    function postCollateral(address collateralAsset, uint256 assets) external {
        IERC20Like(collateralAsset).approve(address(collateralCToken), assets);
        uint256 shares = collateralCToken.deposit(assets, address(this));
        collateralCToken.postCollateral(shares);
    }

    function attackDepositRedeem(uint256 assets) external {
        borrowableCToken.flashLoan(assets, abi.encode(MODE_DEPOSIT_REDEEM));
    }

    function attackBorrowDuringCallback(uint256 assets, uint256 borrowAmount_) external {
        borrowAmount = borrowAmount_;
        borrowableCToken.flashLoan(assets, abi.encode(MODE_BORROW));
    }

    function onFlashLoan(uint256 assets, uint256 assetsReturned, bytes calldata data) external returns (bytes32) {
        require(msg.sender == address(borrowableCToken), "unauthorized callback");

        uint8 mode = abi.decode(data, (uint8));
        if (mode == MODE_DEPOSIT_REDEEM) {
            asset.approve(address(borrowableCToken), assets);
            uint256 shares = borrowableCToken.deposit(assets, address(this));
            borrowableCToken.redeem(shares, address(this), address(this));
        } else if (mode == MODE_BORROW) {
            borrowableCToken.borrow(borrowAmount, address(this));
        }

        asset.approve(address(borrowableCToken), assetsReturned);
        return bytes32(0);
    }
}
