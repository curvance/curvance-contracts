// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { WAD } from "contracts/libraries/Constants.sol";
import { FixedPointMathLib } from "contracts/libraries/FixedPointMathLib.sol";
import { ERC165Checker } from "contracts/libraries/external/ERC165Checker.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
import { CommonLib } from "contracts/libraries/CommonLib.sol";

import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { IOracleManager } from "contracts/interfaces/IOracleManager.sol";

contract CurvanceDAOLBP {
    /// TYPES ///

    enum SaleStatus {
        NotStarted,
        InSale,
        Closed
    }

    /// CONSTANTS ///

    /// @notice The duration of the LBP.
    uint256 public constant SALE_PERIOD = 3 days;

    /// @notice Curvance DAO hub.
    ICentralRegistry public immutable centralRegistry;
    /// @notice CVE contract address.
    address public immutable cve;

    /// STORAGE ///

    /// PUBLIC SALE CONFIGURATIONS

    /// @notice The starting timestamp of the LBP, in Unix time.
    uint256 public startTime;
    /// @notice The number of CVE tokens up for grabs from the DAO.
    uint256 public cveAmountForSale;
    /// @notice Initial soft cap price, in `paymentToken`.
    uint256 public softPriceInpaymentToken;
    /// @notice Initial hard cap price, in `paymentToken`.
    uint256 public hardPriceInpaymentToken;
    /// @notice Payment token can be any ERC20, but never gas tokens.
    address public paymentToken;
    /// @notice Decimals for `paymentToken`.
    uint8 public paymentTokenDecimals;
    /// @notice Cached price of paymentToken, locked in during start() call.
    uint256 public paymentTokenPrice;
    /// @notice The amount of decimals to adjust between paymentToken and CVE.
    uint256 public saleDecimalAdjustment;
    /// @notice The number of `paymentToken` committed to the LBP.
    uint256 public saleCommitted;

    /// @notice User => paymentTokens committed.
    mapping(address => uint256) public userCommitted;

    /// ERRORS ///

    error CurvanceDAOLBP__InvalidCentralRegistry();
    error CurvanceDAOLBP__Unauthorized();
    error CurvanceDAOLBP__InvalidStartTime();
    error CurvanceDAOLBP__InvalidPrice();
    error CurvanceDAOLBP__InvalidPriceSource();
    error CurvanceDAOLBP__NotStarted();
    error CurvanceDAOLBP__AlreadyStarted();
    error CurvanceDAOLBP__InSale();
    error CurvanceDAOLBP__Closed();
    error CurvanceDAOLBP__Success();
    error CurvanceDAOLBP__InvalidSwapData();
    error CurvanceDAOLBP__InvalidSwapOutput();

    /// EVENTS ///

    event LBPStarted(uint256 startTime);
    event Committed(address user, uint256 payAmount);
    event Claimed(address user, uint256 cveAmount);

    /// CONSTRUCTOR ///

    receive() external payable {}

    constructor(ICentralRegistry centralRegistry_) {
        if (
            !ERC165Checker.supportsInterface(
                address(centralRegistry_),
                type(ICentralRegistry).interfaceId
            )
        ) {
            revert CurvanceDAOLBP__InvalidCentralRegistry();
        }

        centralRegistry = centralRegistry_;
        cve = centralRegistry.cve();
    }

    /// EXTERNAL FUNCTIONS ///

    /// @notice Starts the configuration of the LBP.
    /// @param startTimestamp LBP start timestamp, in Unix time.
    /// @param softPriceInUSD LBP base token price, in USD.
    /// @param hardPriceInUSD LBP hard cap token price, in USD.
    /// @param cveAmountInLBP CVE amount included in LBP.
    /// @param paymentTokenAddress The address of the payment token.
    function start(
        uint256 startTimestamp,
        uint256 softPriceInUSD,
        uint256 hardPriceInUSD,
        uint256 cveAmountInLBP,
        address paymentTokenAddress
    ) external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert CurvanceDAOLBP__Unauthorized();
        }

        if (startTime != 0) {
            revert CurvanceDAOLBP__AlreadyStarted();
        }

        if (startTimestamp < block.timestamp) {
            revert CurvanceDAOLBP__InvalidStartTime();
        }

        if (softPriceInUSD >= hardPriceInUSD) {
            revert CurvanceDAOLBP__InvalidPrice();
        }

        uint256 errorCode;
        (paymentTokenPrice, errorCode) = IOracleManager(
            centralRegistry.oracleManager()
        ).getPrice(paymentTokenAddress, true, true);

        // Make sure that we didnt have a catastrophic error when pricing
        // the payment token.
        if (errorCode == 2) {
            revert CurvanceDAOLBP__InvalidPriceSource();
        }

        startTime = startTimestamp;
        softPriceInpaymentToken = (softPriceInUSD * WAD) / paymentTokenPrice;
        hardPriceInpaymentToken = (hardPriceInUSD * WAD) / paymentTokenPrice;
        cveAmountForSale = cveAmountInLBP;
        paymentToken = paymentTokenAddress;
        paymentTokenDecimals = IERC20(paymentTokenAddress).decimals();

        emit LBPStarted(startTimestamp);
    }

    /// @notice Processes a LBP conmmitment, a caller can commit
    ///         `paymentToken` for the caller to receive a proportional
    ///         share of CVE from Curvance DAO.
    /// @param amount The amount of `paymentToken` to commit.
    function commit(uint256 amount) external {
        // Validate that LBP is active.
        _canCommit();

        uint256 remaining = hardCap() - saleCommitted;
        if (amount > remaining) {
            // users can commit for only remaining amount
            amount = remaining;
        }

        // Take commitment.
        SafeTransferLib.safeTransferFrom(
            paymentToken,
            msg.sender,
            address(this),
            amount
        );

        // Document commitment for caller.
        _commit(amount, msg.sender);
    }

    /// @notice Processes a LBP conmmitment, a caller can commit
    ///         `paymentToken` for `recipient` to receive a proportional
    ///         share of CVE from Curvance DAO.
    /// @param amount The amount of `paymentToken` to commit.
    /// @param recipient The address of the user who should benefit from
    ///                  the commitment.
    function commitFor(uint256 amount, address recipient) external {
        // Validate that LBP is active.
        _canCommit();

        // Take commitment.
        SafeTransferLib.safeTransferFrom(
            paymentToken,
            msg.sender,
            address(this),
            amount
        );

        // Document commitment for `recipient`.
        _commit(amount, recipient);
    }

    function swapAndCommitFor(
        SwapperLib.Swap memory swapperData,
        uint256 commitAmount,
        address recipient
    ) external payable {
        // Validate that LBP is active.
        _canCommit();

        if (swapperData.outputToken != paymentToken) {
            revert CurvanceDAOLBP__InvalidSwapData();
        }

        if (CommonLib.isETH(swapperData.inputToken)) {
            // Validate message has gas token attached.
            if (swapperData.inputAmount != msg.value) {
                revert CurvanceDAOLBP__InvalidSwapData();
            }
        } else {
            SafeTransferLib.safeTransferFrom(
                swapperData.inputToken,
                msg.sender,
                address(this),
                swapperData.inputAmount
            );
        }

        // Execute swap into eToken underlying.
        uint256 amount = SwapperLib.swapUnsafe(centralRegistry, swapperData);

        if (amount < commitAmount) {
            revert CurvanceDAOLBP__InvalidSwapOutput();
        }

        if (amount > commitAmount) {
            // Refund remaining payment token
            SafeTransferLib.safeTransfer(
                paymentToken,
                msg.sender,
                amount - commitAmount
            );
        }

        // Document commitment for `recipient`.
        _commit(commitAmount, recipient);
    }

    /// @notice Distributes a callers CVE owed from prior commitments.
    /// @dev Only callable after the conclusion of the LBP.
    function claim() external returns (uint256 amount) {
        SaleStatus saleStatus = currentStatus();
        if (saleStatus == SaleStatus.NotStarted) {
            revert CurvanceDAOLBP__NotStarted();
        }
        if (saleStatus == SaleStatus.InSale) {
            revert CurvanceDAOLBP__InSale();
        }

        uint256 payAmount = userCommitted[msg.sender];
        userCommitted[msg.sender] = 0;

        uint256 price = currentPrice();
        uint256 adjustedPayAmount = _adjustDecimals(
            payAmount,
            paymentTokenDecimals,
            18
        );
        amount = (adjustedPayAmount * WAD) / price;

        SafeTransferLib.safeTransfer(cve, msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    /// PERMISSIONED EXTERNAL FUNCTIONS ///

    /// @notice Withdraws LBP funds to DAO address.
    /// @dev Only callable on the conclusion of the LBP.
    function withdrawFunds() external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert CurvanceDAOLBP__Unauthorized();
        }

        SaleStatus saleStatus = currentStatus();
        if (saleStatus == SaleStatus.NotStarted) {
            revert CurvanceDAOLBP__NotStarted();
        }
        if (saleStatus == SaleStatus.InSale) {
            revert CurvanceDAOLBP__InSale();
        }

        uint256 balance = IERC20(paymentToken).balanceOf(address(this));
        SafeTransferLib.safeTransfer(
            paymentToken,
            centralRegistry.daoAddress(),
            balance
        );
    }

    /// @notice Withdraws CVE to DAO address.
    function withdrawCVE() external {
        if (!centralRegistry.hasDaoPermissions(msg.sender)) {
            revert CurvanceDAOLBP__Unauthorized();
        }

        SaleStatus saleStatus = currentStatus();
        if (saleStatus == SaleStatus.NotStarted) {
            revert CurvanceDAOLBP__NotStarted();
        }
        if (saleStatus == SaleStatus.InSale) {
            revert CurvanceDAOLBP__InSale();
        }

        if (saleCommitted >= softCap()) {
            revert CurvanceDAOLBP__Success();
        }

        uint256 adjustedAmount = _adjustDecimals(
            saleCommitted,
            paymentTokenDecimals,
            18
        );
        uint256 price = currentPrice();
        uint256 soldAmount = (adjustedAmount * WAD) / price;

        uint256 remaining = cveAmountForSale - soldAmount;
        if (remaining == 0) {
            revert CurvanceDAOLBP__Success();
        }

        SafeTransferLib.safeTransfer(
            cve,
            centralRegistry.daoAddress(),
            remaining
        );
    }

    /// PUBLIC FUNCTIONS ///

    /// @notice Returns the current soft cap limit, in `paymentToken`,
    ///         denominated in 18 decimals.
    function softCap() public view returns (uint256) {
        return (softPriceInpaymentToken * cveAmountForSale) / WAD;
    }

    /// @notice return sale hard cap
    function hardCap() public view returns (uint256) {
        return (hardPriceInpaymentToken * cveAmountForSale) / 1e18;
    }

    /// @notice Returns the current LBP price based on current commitments.
    function priceAt(uint256 amount) public view returns (uint256 price) {
        // Adjust decimals between paymentTokenDecimals,
        // and default 18 decimals of softCap().
        amount = _adjustDecimals(amount, paymentTokenDecimals, 18);

        uint256 _softCap = softCap();
        if (amount < _softCap) {
            return softPriceInpaymentToken;
        }

        uint256 _hardCap = hardCap();
        if (amount >= _hardCap) {
            return hardPriceInpaymentToken;
        }

        // Equivalent to (amount * WAD) / cveAmountForSale rounded up.
        return FixedPointMathLib.mulDivUp(amount, WAD, cveAmountForSale);
    }

    /// @notice Returns the current price based on current commitments.
    function currentPrice() public view returns (uint256) {
        return priceAt(saleCommitted);
    }

    /// @notice Returns the current status of the Curvance DAO LBP.
    function currentStatus() public view returns (SaleStatus) {
        if (startTime == 0 || block.timestamp < startTime) {
            return SaleStatus.NotStarted;
        }

        if (
            block.timestamp < startTime + SALE_PERIOD &&
            saleCommitted < hardCap()
        ) {
            return SaleStatus.InSale;
        }

        return SaleStatus.Closed;
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice Preconditional check to determine whether the LBP is active.
    function _canCommit() internal view {
        SaleStatus saleStatus = currentStatus();
        if (saleStatus == SaleStatus.NotStarted) {
            revert CurvanceDAOLBP__NotStarted();
        }

        if (saleStatus == SaleStatus.Closed) {
            revert CurvanceDAOLBP__Closed();
        }
    }

    /// @notice Documents a commitment of `amount` for `recipient`.
    /// @param amount The amount of `paymentToken` committed.
    /// @param recipient The address of the user who should benefit from
    ///                  the commitment.
    function _commit(uint256 amount, address recipient) internal {
        userCommitted[recipient] += amount;
        saleCommitted += amount;

        emit Committed(recipient, amount);
    }

    /// @dev Converting `amount` into proper form between potentially two
    ///      different decimal forms.
    function _adjustDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            return amount * 10 ** (toDecimals - fromDecimals);
        } else {
            return amount / 10 ** (fromDecimals - toDecimals);
        }
    }
}
