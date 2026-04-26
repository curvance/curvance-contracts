// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { SimpleZapper } from "contracts/plugins/market/SimpleZapper.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IUniswapV3Router } from "contracts/interfaces/external/uniswap/IUniswapV3Router.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TC004SimpleZapperSwapAccountingPoC is TestBaseMarketIsolated {
    uint256 internal constant INPUT_ETH_AMOUNT = 3 ether;
    uint256 internal constant MIN_BORROW_PROBE = 100 ether;
    uint256 internal constant MAX_BORROW_PROBE = 2_000 ether;

    address internal constant _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    SimpleZapper public simpleZapper;

    struct BranchState {
        uint256 collateralAssetsDelivered;
        uint256 cTokenSharesReceived;
        uint256 cTokenBalance;
        uint256 collateralPosted;
        uint256 marketCollateralPosted;
        uint256 cTokenTotalAssets;
        uint256 maxBorrowCapacity;
        uint256 borrowAmount;
        uint256 debtBalance;
        LiquidationProbe liquidationProbe;
    }

    struct LiquidationProbe {
        bool liquidationAvailable;
        uint256 debtAmountInput;
        uint256 debtAmountResolved;
        uint256 collateralPosted;
        uint256 debtBalance;
        uint256 liquidatedShares;
        uint256 debtRepaid;
        uint256 badDebtRealized;
    }

    function setUp() public override {
        super.setUp();

        oracleManager.addCTokenSupport(address(simpleCUSDC));

        simpleZapper = new SimpleZapper(
            ICentralRegistry(address(centralRegistry)),
            _WETH_ADDRESS
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        _prepareDAI(address(this), 200_000 ether);
        dai.approve(address(borrowableCDAI), 200_000 ether);

        _prepareUSDC(address(this), 100e6);
        usdc.approve(address(simpleCUSDC), 100e6);

        marketManagerIsolated.listTokens(address(simpleCUSDC), address(borrowableCDAI));

        _setCTokenConfigHighValues(address(simpleCUSDC), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCDAI), 100_000e18, 100_000e18);

        address liquidityProvider = makeAddr("tc004LiquidityProvider");
        _prepareDAI(liquidityProvider, 1_000 ether);
        _prepareUSDC(liquidityProvider, 100e6);

        vm.startPrank(liquidityProvider);
        dai.approve(address(borrowableCDAI), 1_000 ether);
        borrowableCDAI.deposit(1_000 ether, liquidityProvider);
        usdc.approve(address(simpleCUSDC), 100e6);
        simpleCUSDC.mint(100e6, liquidityProvider);
        vm.stopPrank();
    }

    function test_tc004_simpleZapper_swapIngressAndRealizedOutputDirectBaselineReachEquivalentMarketState() public {
        uint256 baselineSnapshot = vm.snapshotState();

        BranchState memory swapBranch = _runSwapIngressBranch(INPUT_ETH_AMOUNT);

        assertTrue(vm.revertToState(baselineSnapshot), "tc004:failed-to-revert-swap-branch");

        // Replay direct entry with the realized swap output so the comparison
        // isolates zapper/accounting behavior rather than router price movement.
        BranchState memory directBranch = _runDirectUsdcBranch(
            swapBranch.collateralAssetsDelivered
        );

        _assertEquivalentBranchState(
            swapBranch,
            directBranch,
            "realized-output-direct"
        );
    }

    function test_tc004_simpleZapper_unknownSwapTargetRevertsBeforeMarketMutation() public {
        BranchState memory beforeState = _captureStaticState();
        vm.deal(user1, INPUT_ETH_AMOUNT);
        uint256 userEthBefore = user1.balance;

        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            inputAmount: INPUT_ETH_AMOUNT,
            outputToken: _USDC_ADDRESS,
            target: address(0xdead),
            slippage: 0,
            call: ""
        });

        vm.startPrank(user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);
        vm.expectRevert(SwapperLib.SwapperLib__UnknownCalldata.selector);
        simpleZapper.swapAndDeposit{value: INPUT_ETH_AMOUNT}(
            address(simpleCUSDC),
            false,
            swapAction,
            0,
            true,
            user1
        );
        vm.stopPrank();

        BranchState memory afterState = _captureStaticState();

        assertEq(afterState.cTokenBalance, beforeState.cTokenBalance, "tc004:revert-ctoken-balance-drift");
        assertEq(afterState.collateralPosted, beforeState.collateralPosted, "tc004:revert-collateral-drift");
        assertEq(afterState.marketCollateralPosted, beforeState.marketCollateralPosted, "tc004:revert-market-collateral-drift");
        assertEq(afterState.cTokenTotalAssets, beforeState.cTokenTotalAssets, "tc004:revert-total-assets-drift");
        assertEq(afterState.debtBalance, beforeState.debtBalance, "tc004:revert-debt-drift");
        assertEq(user1.balance, userEthBefore, "tc004:revert-user-eth-drift");
    }

    function _runSwapIngressBranch(
        uint256 ethAmount
    ) internal returns (BranchState memory branch) {
        vm.deal(user1, ethAmount);

        SwapperLib.Swap memory swapAction = _buildEthToUsdcSwapAction(ethAmount);

        uint256 totalAssetsBefore = simpleCUSDC.totalAssets();

        vm.startPrank(user1);
        simpleCUSDC.setDelegateApproval(address(simpleZapper), true);
        uint256 cTokenShares = simpleZapper.swapAndDeposit{value: ethAmount}(
            address(simpleCUSDC),
            false,
            swapAction,
            0,
            true,
            user1
        );
        vm.stopPrank();

        uint256 deliveredAssets = simpleCUSDC.totalAssets() - totalAssetsBefore;
        assertGt(deliveredAssets, 0, "tc004:missing-swap-output");

        branch = _completeAccountingBranch(deliveredAssets, cTokenShares);
    }

    function _runDirectUsdcBranch(
        uint256 assetAmount
    ) internal returns (BranchState memory branch) {
        _prepareUSDC(user1, assetAmount);

        uint256 totalAssetsBefore = simpleCUSDC.totalAssets();

        vm.startPrank(user1);
        usdc.approve(address(simpleCUSDC), assetAmount);
        uint256 cTokenShares = simpleCUSDC.depositAsCollateral(
            assetAmount,
            user1
        );
        vm.stopPrank();

        uint256 deliveredAssets = simpleCUSDC.totalAssets() - totalAssetsBefore;
        branch = _completeAccountingBranch(deliveredAssets, cTokenShares);
    }

    function _completeAccountingBranch(
        uint256 collateralAssetsDelivered,
        uint256 cTokenSharesReceived
    ) internal returns (BranchState memory branch) {
        branch.collateralAssetsDelivered = collateralAssetsDelivered;
        branch.cTokenSharesReceived = cTokenSharesReceived;
        branch.cTokenBalance = simpleCUSDC.balanceOf(user1);
        branch.collateralPosted = simpleCUSDC.collateralPosted(user1);
        branch.marketCollateralPosted = simpleCUSDC.marketCollateralPosted();
        branch.cTokenTotalAssets = simpleCUSDC.totalAssets();

        assertGt(branch.cTokenSharesReceived, 0, "tc004:missing-ctoken-shares");
        assertEq(branch.cTokenBalance, branch.cTokenSharesReceived, "tc004:unexpected-ctoken-balance");
        assertEq(branch.collateralPosted, branch.cTokenBalance, "tc004:unexpected-collateral-posted");

        branch.maxBorrowCapacity = _maxBorrowCapacity();
        assertGe(branch.maxBorrowCapacity, MIN_BORROW_PROBE, "tc004:insufficient-borrow-capacity");

        branch.borrowAmount = branch.maxBorrowCapacity / 2;

        vm.prank(address(borrowableCDAI));
        marketManagerIsolated.canBorrow(
            address(borrowableCDAI),
            branch.borrowAmount,
            user1,
            branch.borrowAmount
        );

        vm.prank(user1);
        borrowableCDAI.borrow(branch.borrowAmount, user1);

        skip(20 minutes);
        borrowableCDAI.accrueIfNeeded();

        branch.debtBalance = borrowableCDAI.debtBalance(user1);
        branch.liquidationProbe = _scaffoldLiquidationProbe(branch.borrowAmount);
    }

    function _captureStaticState() internal view returns (BranchState memory branch) {
        branch.cTokenBalance = simpleCUSDC.balanceOf(user1);
        branch.collateralPosted = simpleCUSDC.collateralPosted(user1);
        branch.marketCollateralPosted = simpleCUSDC.marketCollateralPosted();
        branch.cTokenTotalAssets = simpleCUSDC.totalAssets();
        branch.debtBalance = borrowableCDAI.debtBalance(user1);
    }

    function _scaffoldLiquidationProbe(
        uint256 debtAmount
    ) internal returns (LiquidationProbe memory probe) {
        address[] memory accounts = new address[](1);
        uint256[] memory debtAmounts = new uint256[](1);
        accounts[0] = user1;
        debtAmounts[0] = debtAmount;

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(simpleCUSDC),
            debtToken: address(borrowableCDAI),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        probe.debtAmountInput = debtAmount;
        probe.debtAmountResolved = debtAmount;
        probe.collateralPosted = simpleCUSDC.collateralPosted(user1);
        probe.debtBalance = borrowableCDAI.debtBalance(user1);

        vm.prank(address(borrowableCDAI));
        try marketManagerIsolated.canLiquidate(
            debtAmounts,
            address(this),
            accounts,
            action
        ) returns (
            IMarketManager.LiqResult memory result,
            uint256[] memory adjustedDebtAmounts
        ) {
            probe.liquidationAvailable = true;
            probe.liquidatedShares = result.liquidatedShares[0];
            probe.debtRepaid = result.debtRepaid;
            probe.badDebtRealized = result.badDebtRealized;

            if (adjustedDebtAmounts.length != 0) {
                probe.debtAmountResolved = adjustedDebtAmounts[0];
            }
        } catch {
            probe.liquidationAvailable = false;
        }
    }

    function _maxBorrowCapacity() internal returns (uint256 borrowCapacity) {
        uint256 low = MIN_BORROW_PROBE;
        uint256 high = MAX_BORROW_PROBE;

        vm.prank(address(borrowableCDAI));
        marketManagerIsolated.canBorrow(
            address(borrowableCDAI),
            low,
            user1,
            low
        );

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;

            vm.prank(address(borrowableCDAI));
            try marketManagerIsolated.canBorrow(
                address(borrowableCDAI),
                mid,
                user1,
                mid
            ) {
                low = mid;
            } catch {
                high = mid - 1;
            }
        }

        borrowCapacity = low;
    }

    function _buildEthToUsdcSwapAction(
        uint256 ethAmount
    ) internal view returns (SwapperLib.Swap memory swapAction) {
        swapAction.inputToken = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        swapAction.inputAmount = ethAmount;
        swapAction.outputToken = _USDC_ADDRESS;
        swapAction.target = _UNISWAP_V3_SWAP_ROUTER;

        IUniswapV3Router.ExactInputSingleParams memory params;
        params.tokenIn = _WETH_ADDRESS;
        params.tokenOut = _USDC_ADDRESS;
        params.fee = 100;
        params.recipient = address(simpleZapper);
        params.deadline = block.timestamp;
        params.amountIn = ethAmount;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;

        swapAction.call = abi.encodeWithSelector(
            IUniswapV3Router.exactInputSingle.selector,
            params
        );
    }

    function _assertEquivalentBranchState(
        BranchState memory expectedBranch,
        BranchState memory actualBranch,
        string memory branchLabel
    ) internal pure {
        assertEq(
            actualBranch.collateralAssetsDelivered,
            expectedBranch.collateralAssetsDelivered,
            string.concat("tc004:", branchLabel, ":collateral-assets-delivered")
        );
        assertEq(
            actualBranch.cTokenSharesReceived,
            expectedBranch.cTokenSharesReceived,
            string.concat("tc004:", branchLabel, ":ctoken-shares")
        );
        assertEq(
            actualBranch.cTokenBalance,
            expectedBranch.cTokenBalance,
            string.concat("tc004:", branchLabel, ":ctoken-balance")
        );
        assertEq(
            actualBranch.collateralPosted,
            expectedBranch.collateralPosted,
            string.concat("tc004:", branchLabel, ":collateral-posted")
        );
        assertEq(
            actualBranch.marketCollateralPosted,
            expectedBranch.marketCollateralPosted,
            string.concat("tc004:", branchLabel, ":market-collateral-posted")
        );
        assertEq(
            actualBranch.cTokenTotalAssets,
            expectedBranch.cTokenTotalAssets,
            string.concat("tc004:", branchLabel, ":ctoken-total-assets")
        );
        assertEq(
            actualBranch.maxBorrowCapacity,
            expectedBranch.maxBorrowCapacity,
            string.concat("tc004:", branchLabel, ":max-borrow-capacity")
        );
        assertEq(
            actualBranch.borrowAmount,
            expectedBranch.borrowAmount,
            string.concat("tc004:", branchLabel, ":borrow-amount")
        );
        assertEq(
            actualBranch.debtBalance,
            expectedBranch.debtBalance,
            string.concat("tc004:", branchLabel, ":debt-balance")
        );
        assertEq(
            actualBranch.liquidationProbe.liquidationAvailable,
            expectedBranch.liquidationProbe.liquidationAvailable,
            string.concat("tc004:", branchLabel, ":liquidation-availability")
        );
        assertEq(
            actualBranch.liquidationProbe.debtAmountResolved,
            expectedBranch.liquidationProbe.debtAmountResolved,
            string.concat("tc004:", branchLabel, ":probe-debt-resolved")
        );
        assertEq(
            actualBranch.liquidationProbe.collateralPosted,
            expectedBranch.liquidationProbe.collateralPosted,
            string.concat("tc004:", branchLabel, ":probe-collateral")
        );
        assertEq(
            actualBranch.liquidationProbe.debtBalance,
            expectedBranch.liquidationProbe.debtBalance,
            string.concat("tc004:", branchLabel, ":probe-debt-balance")
        );
        assertEq(
            actualBranch.liquidationProbe.liquidatedShares,
            expectedBranch.liquidationProbe.liquidatedShares,
            string.concat("tc004:", branchLabel, ":probe-liquidated-shares")
        );
        assertEq(
            actualBranch.liquidationProbe.debtRepaid,
            expectedBranch.liquidationProbe.debtRepaid,
            string.concat("tc004:", branchLabel, ":probe-debt-repaid")
        );
        assertEq(
            actualBranch.liquidationProbe.badDebtRealized,
            expectedBranch.liquidationProbe.badDebtRealized,
            string.concat("tc004:", branchLabel, ":probe-bad-debt")
        );
    }
}
