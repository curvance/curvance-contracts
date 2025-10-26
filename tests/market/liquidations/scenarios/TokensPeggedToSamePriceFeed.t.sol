// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { TestBaseMarketIsolated } from "tests/market/TestBaseMarketIsolated.sol";
import { BorrowableCToken } from "contracts/market/token/BorrowableCToken.sol";
import { SimpleCToken } from "contracts/market/token/SimpleCToken.sol";
import { IERC20 } from "contracts/interfaces/IERC20.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { console2 } from "forge-std/console2.sol";
import { SafeTransferLib } from "contracts/libraries/external/SafeTransferLib.sol";
import { MockDataFeed } from "contracts/mocks/MockDataFeed.sol";
import { VaultAggregator } from "contracts/oracles/adaptors/wrappedAggregators/VaultAggregator.sol";
import { ProtocolReader } from "contracts/views/ProtocolReader.sol";
import { IMarketManager } from "contracts/interfaces/IMarketManager.sol";
import { MarketManagerIsolated } from "contracts/market/isolated/MarketManagerIsolated.sol";

contract TokensPeggedToSamePriceFeed is TestBaseMarketIsolated {

    BorrowableCToken public borrowableCUSDT;
    SimpleCToken public simpleSUSDE;
    MockDataFeed public mockUsdtFeed;
    VaultAggregator public sUSDeVaultAggregator;

    IERC20 public usdt;
    IERC20 public susde;
    address _SUSDE_ADDRESS = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address _USDE_ADDRESS = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;


    function setUp() public override {
        super.setUp();

        // Deploy cTokens
        usdt = IERC20(_USDT_ADDRESS);
        susde = IERC20(_SUSDE_ADDRESS);

        borrowableCUSDT = _deployBorrowableCToken(_USDT_ADDRESS);
        simpleSUSDE = new SimpleCToken(
            ICentralRegistry(address(centralRegistry)),
            IERC20(_SUSDE_ADDRESS),
            address(marketManagerIsolated)
        );

        deal(_USDT_ADDRESS, address(this), 77777);
        deal(_SUSDE_ADDRESS, address(this), 77777);

        SafeTransferLib.safeApprove(address(usdt), address(borrowableCUSDT), 77777);
        susde.approve(address(simpleSUSDE), 77777);

        marketManagerIsolated.listTokens(address(simpleSUSDE), address(borrowableCUSDT));

        // Deploy mock data feed
        mockUsdtFeed = new MockDataFeed(_CHAINLINK_USDC_USD);
        sUSDeVaultAggregator = new VaultAggregator(address(susde), _USDE_ADDRESS, address(mockUsdtFeed));

        oracleManager.addApprovedAdaptor(address(sUSDeVaultAggregator));

        chainlinkAdaptor.addAsset(
            _USDT_ADDRESS,
            true,
            address(mockUsdtFeed),
            0,
            100
        );
        chainlinkAdaptor.addAsset(
            _SUSDE_ADDRESS,
            true,
            address(sUSDeVaultAggregator),
            0,
            100
        );

        oracleManager.addAssetPricingAdaptor(
            _USDT_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50
        );
        oracleManager.addAssetPricingAdaptor(
            _SUSDE_ADDRESS,
            address(chainlinkAdaptor),
            100,
            50
        );

        oracleManager.addCTokenSupport(address(simpleSUSDE));
        oracleManager.addCTokenSupport(address(borrowableCUSDT));

        _setCTokenConfigBasic(address(simpleSUSDE), 100_000e18, 0);
        _setCTokenConfigBasic(address(borrowableCUSDT), 0, 1_000_000e6);

        // Provide liquidity to borrow
        deal(address(usdt), address(this), 500_000e18);
        SafeTransferLib.safeApprove(address(usdt), address(borrowableCUSDT), 500_000e18);
        borrowableCUSDT.deposit(500_000e18, address(this));

    }

    function testLiquidationWithSamePriceFeed() public {

        vm.startPrank(user1);
        deal(address(_SUSDE_ADDRESS), user1, 1000e18);
        susde.approve(address(simpleSUSDE), 1000e18);
        simpleSUSDE.depositAsCollateral(1000e18, user1);
        borrowableCUSDT.borrow(700e6, user1);
        vm.stopPrank();

        // Drop price to $0.50
        mockUsdtFeed.setMockAnswer(0.5e8);

        // Check position health using protocol reader.
        (uint256 health, bool err) = protocolReader.getPositionHealth(
            IMarketManager(address(marketManagerIsolated)),
            user1,
            address(0),
            address(0),
            false,
            0,
            false,
            0,
            0
        );

        assertGt(health, 1e18, "position should be healthy");
        assertFalse(err);

        // try to liquidate, should revert
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        vm.expectRevert(MarketManagerIsolated.MarketManager__NoLiquidationAvailable.selector);
        borrowableCUSDT.liquidate(accounts, address(simpleSUSDE));

        

    }
}
