// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { BaseZapper } from "contracts/plugins/BaseZapper.sol";
import { NativeVaultZapper } from "contracts/plugins/market/NativeVaultZapper.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { IVault } from "contracts/interfaces/IVault.sol";
import { MockCalldataChecker } from "contracts/mocks/MockCalldataChecker.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";

contract TC003NativeVaultZapperAccountingPoC is TestBaseMarketIsolated {
    uint256 internal constant INPUT_AMOUNT = 100 ether;
    uint256 internal constant MIN_BORROW_PROBE = 50e6;
    uint256 internal constant MAX_BORROW_PROBE = 50_000e6;

    NativeVaultZapper public vaultZapper;
    address public constant SHMON_ADDRESS = 0x1B68626dCa36c7fE922fD2d55E4f631d962dE19c;
    address public constant WMON_ADDRESS = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
    SimpleCToken public simpleCSHMON;

    address public constant _CHAINLINK_ETH_USD_MONAD = 0x1B1414782B859871781bA3E4B0979b9ca57A0A04;
    address public constant _CHAINLINK_USDC_USD_MONAD = 0xf5F15f188AbCB0d165D1Edb7f37F7d6fA2fCebec;

    address internal constant _UNISWAP_V3_SWAP_ROUTER =
        0xE592427A0AEce92De3Edee1F18E0157C05861564;

    struct BranchState {
        uint256 vaultSharesReceived;
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
        _fork("MON_NODE_URI_MONAD_MAINNET");

        _deployCentralRegistry();
        _deployCVE();
        _deployRewardManager();
        _deployVeCVE();
        _deployGaugeManager();
        _deployMarketManager();
        _deployOracleManager();
        _deployBorrowableCUSDC();

        vaultZapper = new NativeVaultZapper(
            ICentralRegistry(address(centralRegistry)),
            WMON_ADDRESS
        );

        centralRegistry.setExternalCalldataChecker(
            _UNISWAP_V3_SWAP_ROUTER,
            address(new MockCalldataChecker(_UNISWAP_V3_SWAP_ROUTER))
        );

        simpleCSHMON = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(SHMON_ADDRESS),
            address(marketManagerIsolated)
        );

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        chainlinkAdaptor.addAsset(
            SHMON_ADDRESS,
            true,
            _CHAINLINK_ETH_USD_MONAD,
            0
        );
        oracleManager.addAssetPricingAdaptor(
            SHMON_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addCTokenSupport(address(simpleCSHMON));

        chainlinkAdaptor.addAsset(
            _USDC_ADDRESS,
            true,
            _CHAINLINK_USDC_USD_MONAD,
            0
        );
        oracleManager.addAssetPricingAdaptor(
            _USDC_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50,
            100,
            50
        );
        oracleManager.addCTokenSupport(address(borrowableCUSDC));

        deal(SHMON_ADDRESS, address(this), 77_777 ether);
        IERC20(SHMON_ADDRESS).approve(address(simpleCSHMON), 77_777 ether);
        deal(_USDC_ADDRESS, address(this), 77_777 ether);
        IERC20(_USDC_ADDRESS).approve(address(borrowableCUSDC), 77_777 ether);

        marketManagerIsolated.listTokens(address(simpleCSHMON), address(borrowableCUSDC));

        _setCTokenConfigBasic(address(simpleCSHMON), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDC), 100_000e18, 100_000e18);

        address liquidityProvider = makeAddr("tc003LiquidityProvider");
        _prepareUSDC(liquidityProvider, 1_000_000e6);

        vm.startPrank(liquidityProvider);
        usdc.approve(address(borrowableCUSDC), type(uint256).max);
        borrowableCUSDC.deposit(1_000_000e6, liquidityProvider);
        vm.stopPrank();
    }

    function test_tc003_nativeVaultZapper_directNativeAndNativeNoSwapReachEquivalentMarketState() public {
        uint256 baselineSnapshot = vm.snapshotState();

        BranchState memory directBranch = _runDirectNativeBranch(INPUT_AMOUNT);

        assertTrue(vm.revertToState(baselineSnapshot), "tc003:failed-to-revert-direct-baseline");

        BranchState memory nativeZapperBranch = _runNativeVaultNoSwapBranch(INPUT_AMOUNT, false);

        _assertEquivalentBranchState(directBranch, nativeZapperBranch, "native-no-swap");
    }

    function test_tc003_nativeVaultZapper_directNativeAndWrappedNativeNoSwapReachEquivalentMarketState() public {
        uint256 baselineSnapshot = vm.snapshotState();

        BranchState memory directBranch = _runDirectNativeBranch(INPUT_AMOUNT);

        assertTrue(vm.revertToState(baselineSnapshot), "tc003:failed-to-revert-direct-baseline");

        BranchState memory wrappedNativeBranch = _runNativeVaultNoSwapBranch(INPUT_AMOUNT, true);

        _assertEquivalentBranchState(directBranch, wrappedNativeBranch, "wrapped-native-no-swap");
    }

    function test_tc003_nativeVaultZapper_nonNativeOutputRevertsBeforeMarketMutation() public {
        deal(user1, INPUT_AMOUNT);
        BranchState memory beforeState = _captureStaticState();
        uint256 userEthBefore = user1.balance;

        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            inputAmount: INPUT_AMOUNT,
            outputToken: WMON_ADDRESS,
            target: address(0),
            slippage: 0,
            call: ""
        });
        vm.startPrank(user1);
        simpleCSHMON.setDelegateApproval(address(vaultZapper), true);
        vm.expectRevert(BaseZapper.BaseZapper__UnderlyingTokenIsNotInputToken.selector);
        vaultZapper.swapAndDeposit{value: INPUT_AMOUNT}(
            address(simpleCSHMON),
            false,
            swapAction,
            0,
            true,
            user1
        );
        vm.stopPrank();

        BranchState memory afterState = _captureStaticState();

        assertEq(afterState.cTokenBalance, beforeState.cTokenBalance, "tc003:revert-ctoken-balance-drift");
        assertEq(afterState.collateralPosted, beforeState.collateralPosted, "tc003:revert-collateral-drift");
        assertEq(afterState.marketCollateralPosted, beforeState.marketCollateralPosted, "tc003:revert-market-collateral-drift");
        assertEq(afterState.cTokenTotalAssets, beforeState.cTokenTotalAssets, "tc003:revert-total-assets-drift");
        assertEq(afterState.debtBalance, beforeState.debtBalance, "tc003:revert-debt-drift");
        assertEq(user1.balance, userEthBefore, "tc003:revert-user-eth-drift");
    }

    function _runDirectNativeBranch(uint256 nativeAmount) internal returns (BranchState memory branch) {
        deal(user1, nativeAmount);

        vm.startPrank(user1);
        uint256 vaultShares = IVault(simpleCSHMON.asset()).deposit{value: nativeAmount}(nativeAmount, user1);
        IERC20(simpleCSHMON.asset()).approve(address(simpleCSHMON), vaultShares);
        uint256 cTokenShares = simpleCSHMON.depositAsCollateral(vaultShares, user1);
        vm.stopPrank();

        branch = _completeAccountingBranch(vaultShares, cTokenShares);
    }

    function _runNativeVaultNoSwapBranch(
        uint256 inputAmount,
        bool wrappedInput
    ) internal returns (BranchState memory branch) {
        SwapperLib.Swap memory swapAction = SwapperLib.Swap({
            inputToken: wrappedInput ? WMON_ADDRESS : address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            inputAmount: inputAmount,
            outputToken: address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            target: address(0),
            slippage: 0,
            call: ""
        });

        if (wrappedInput) {
            deal(WMON_ADDRESS, user1, inputAmount);
        } else {
            deal(user1, inputAmount);
        }

        uint256 expectedVaultShares = IVault(simpleCSHMON.asset()).previewDeposit(inputAmount);

        vm.startPrank(user1);
        simpleCSHMON.setDelegateApproval(address(vaultZapper), true);

        if (wrappedInput) {
            IERC20(WMON_ADDRESS).approve(address(vaultZapper), inputAmount);
        }

        uint256 cTokenShares = wrappedInput
            ? vaultZapper.swapAndDeposit(
                address(simpleCSHMON),
                false,
                swapAction,
                0,
                true,
                user1
            )
            : vaultZapper.swapAndDeposit{value: inputAmount}(
                address(simpleCSHMON),
                false,
                swapAction,
                0,
                true,
                user1
            );
        vm.stopPrank();

        branch = _completeAccountingBranch(expectedVaultShares, cTokenShares);
    }

    function _completeAccountingBranch(
        uint256 vaultSharesReceived,
        uint256 cTokenSharesReceived
    ) internal returns (BranchState memory branch) {
        branch.vaultSharesReceived = vaultSharesReceived;
        branch.cTokenSharesReceived = cTokenSharesReceived;
        branch.cTokenBalance = simpleCSHMON.balanceOf(user1);
        branch.collateralPosted = simpleCSHMON.collateralPosted(user1);
        branch.marketCollateralPosted = simpleCSHMON.marketCollateralPosted();
        branch.cTokenTotalAssets = simpleCSHMON.totalAssets();

        assertGt(branch.cTokenSharesReceived, 0, "tc003:missing-ctoken-shares");
        assertEq(branch.cTokenBalance, branch.cTokenSharesReceived, "tc003:unexpected-ctoken-balance");
        assertEq(branch.collateralPosted, branch.cTokenBalance, "tc003:unexpected-collateral-posted");

        branch.maxBorrowCapacity = _maxBorrowCapacity();
        assertGe(branch.maxBorrowCapacity, MIN_BORROW_PROBE, "tc003:insufficient-borrow-capacity");

        branch.borrowAmount = branch.maxBorrowCapacity / 2;
        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(
            address(borrowableCUSDC),
            branch.borrowAmount,
            user1,
            branch.borrowAmount
        );

        vm.prank(user1);
        borrowableCUSDC.borrow(branch.borrowAmount, user1);

        skip(20 minutes);
        borrowableCUSDC.accrueIfNeeded();

        branch.debtBalance = borrowableCUSDC.debtBalance(user1);
        branch.liquidationProbe = _scaffoldLiquidationProbe(branch.borrowAmount);
    }

    function _captureStaticState() internal view returns (BranchState memory branch) {
        branch.cTokenBalance = simpleCSHMON.balanceOf(user1);
        branch.collateralPosted = simpleCSHMON.collateralPosted(user1);
        branch.marketCollateralPosted = simpleCSHMON.marketCollateralPosted();
        branch.cTokenTotalAssets = simpleCSHMON.totalAssets();
        branch.debtBalance = borrowableCUSDC.debtBalance(user1);
    }

    function _scaffoldLiquidationProbe(
        uint256 debtAmount
    ) internal returns (LiquidationProbe memory probe) {
        address[] memory accounts = new address[](1);
        uint256[] memory debtAmounts = new uint256[](1);
        accounts[0] = user1;
        debtAmounts[0] = debtAmount;

        IMarketManager.LiqAction memory action = IMarketManager.LiqAction({
            collateralToken: address(simpleCSHMON),
            debtToken: address(borrowableCUSDC),
            numAccounts: 1,
            liquidateExact: false,
            liquidatedShares: 0,
            debtRepaid: 0,
            badDebt: 0
        });

        probe.debtAmountInput = debtAmount;
        probe.debtAmountResolved = debtAmount;
        probe.collateralPosted = simpleCSHMON.collateralPosted(user1);
        probe.debtBalance = borrowableCUSDC.debtBalance(user1);

        vm.prank(address(borrowableCUSDC));
        try marketManagerIsolated.canLiquidate(debtAmounts, address(this), accounts, action) returns (
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

        vm.prank(address(borrowableCUSDC));
        marketManagerIsolated.canBorrow(address(borrowableCUSDC), low, user1, low);

        while (low < high) {
            uint256 mid = (low + high + 1) / 2;

            vm.prank(address(borrowableCUSDC));
            try marketManagerIsolated.canBorrow(
                address(borrowableCUSDC),
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

    function _assertEquivalentBranchState(
        BranchState memory expectedBranch,
        BranchState memory actualBranch,
        string memory branchLabel
    ) internal pure {
        assertEq(actualBranch.vaultSharesReceived, expectedBranch.vaultSharesReceived, string.concat("tc003:", branchLabel, ":vault-shares"));
        assertEq(actualBranch.cTokenSharesReceived, expectedBranch.cTokenSharesReceived, string.concat("tc003:", branchLabel, ":ctoken-shares"));
        assertEq(actualBranch.cTokenBalance, expectedBranch.cTokenBalance, string.concat("tc003:", branchLabel, ":ctoken-balance"));
        assertEq(actualBranch.collateralPosted, expectedBranch.collateralPosted, string.concat("tc003:", branchLabel, ":collateral-posted"));
        assertEq(actualBranch.marketCollateralPosted, expectedBranch.marketCollateralPosted, string.concat("tc003:", branchLabel, ":market-collateral-posted"));
        assertEq(actualBranch.cTokenTotalAssets, expectedBranch.cTokenTotalAssets, string.concat("tc003:", branchLabel, ":ctoken-total-assets"));
        assertEq(actualBranch.maxBorrowCapacity, expectedBranch.maxBorrowCapacity, string.concat("tc003:", branchLabel, ":max-borrow-capacity"));
        assertEq(actualBranch.borrowAmount, expectedBranch.borrowAmount, string.concat("tc003:", branchLabel, ":borrow-amount"));
        assertEq(actualBranch.debtBalance, expectedBranch.debtBalance, string.concat("tc003:", branchLabel, ":debt-balance"));
        assertEq(
            actualBranch.liquidationProbe.liquidationAvailable,
            expectedBranch.liquidationProbe.liquidationAvailable,
            string.concat("tc003:", branchLabel, ":liquidation-availability")
        );
        assertEq(actualBranch.liquidationProbe.debtAmountResolved, expectedBranch.liquidationProbe.debtAmountResolved, string.concat("tc003:", branchLabel, ":probe-debt-resolved"));
        assertEq(actualBranch.liquidationProbe.collateralPosted, expectedBranch.liquidationProbe.collateralPosted, string.concat("tc003:", branchLabel, ":probe-collateral"));
        assertEq(actualBranch.liquidationProbe.debtBalance, expectedBranch.liquidationProbe.debtBalance, string.concat("tc003:", branchLabel, ":probe-debt-balance"));
        assertEq(actualBranch.liquidationProbe.liquidatedShares, expectedBranch.liquidationProbe.liquidatedShares, string.concat("tc003:", branchLabel, ":probe-liquidated-shares"));
        assertEq(actualBranch.liquidationProbe.debtRepaid, expectedBranch.liquidationProbe.debtRepaid, string.concat("tc003:", branchLabel, ":probe-debt-repaid"));
        assertEq(actualBranch.liquidationProbe.badDebtRealized, expectedBranch.liquidationProbe.badDebtRealized, string.concat("tc003:", branchLabel, ":probe-bad-debt"));
    }
}
