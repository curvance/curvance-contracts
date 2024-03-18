// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import { TestBaseFeeAccumulator } from "../TestBaseFeeAccumulator.sol";
import { EpochRolloverData } from "contracts/interfaces/IFeeAccumulator.sol";
import { FeeAccumulator } from "contracts/architecture/FeeAccumulator.sol";
import { RewardsData } from "contracts/interfaces/ICVELocker.sol";

contract ExecuteEpochFeeRouterTest is TestBaseFeeAccumulator {
    EpochRolloverData data =
        EpochRolloverData({
            chainId: 42161,
            value: _ONE,
            numChainData: 1,
            epoch: 0
        });

    function setUp() public override {
        super.setUp();

        vm.prank(centralRegistry.feeAccumulator());
        cveLocker.recordEpochRewards(_ONE);

        skip(veCVE.RESTRICTION_DURATION() + 1);
    }

    function test_executeEpochFeeRouter_fail_whenChainIsNotSupported() public {
        centralRegistry.addChainSupport(
            address(protocolMessagingHub),
            address(protocolMessagingHub),
            address(cve),
            42161,
            1,
            1,
            23
        );

        uint256 currentEpoch = cveLocker.currentEpoch(block.timestamp);
        uint256 nextEpoch = cveLocker.nextEpochToDeliver();

        vm.prank(address(protocolMessagingHub));

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeAccumulator.FeeAccumulator__CurrentEpochError.selector,
                currentEpoch,
                nextEpoch
            )
        );
        feeAccumulator.executeEpochFeeRouter(42161);
    }

    function test_executeEpochFeeRouter_success_whenChainIsNotSupported()
        public
    {
        skip(veCVE.EPOCH_DURATION() * 2);

        vm.expectRevert();
        feeAccumulator.crossChainLockData(0);

        vm.prank(address(protocolMessagingHub));
        feeAccumulator.executeEpochFeeRouter(42161);

        vm.expectRevert();
        feeAccumulator.crossChainLockData(0);
    }

    function test_executeEpochFeeRouter_success_whenChainIsSupported_whenCVELockerIsNotShutdown()
        public
    {
        _executeEpochFeeRouter();

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), 0);
        assertEq(usdc.balanceOf(address(cveLocker)), 6250000);
    }

    function test_executeEpochFeeRouter_success_whenChainIsSupported_whenCVELockerIsShutdown()
        public
    {
        cveLocker.notifyLockerShutdown();

        _executeEpochFeeRouter();

        assertEq(usdc.balanceOf(centralRegistry.daoAddress()), 6250000);
        assertEq(usdc.balanceOf(address(cveLocker)), 0);
    }

    function _executeEpochFeeRouter() internal {
        skip(3 weeks);

        vm.prank(centralRegistry.feeAccumulator());
        cveLocker.recordEpochRewards(_ONE);

        deal(address(protocolMessagingHub), _ONE);
        deal(address(feeAccumulator), _ONE);
        deal(_USDC_ADDRESS, address(feeAccumulator), 10e6);
        deal(address(cve), address(this), _ONE);

        cve.approve(address(veCVE), _ONE);

        veCVE.createLock(
            _ONE,
            true,
            RewardsData(false, true, true, true),
            "",
            0
        );

        centralRegistry.addChainSupport(
            address(protocolMessagingHub),
            address(protocolMessagingHub),
            address(cve),
            42161,
            1,
            1,
            23
        );

        uint256 nextEpoch = cveLocker.nextEpochToDeliver();

        vm.prank(address(protocolMessagingHub));
        feeAccumulator.receiveCrossChainLockData(data);

        (uint224 lockAmount, uint16 epoch, uint16 chainId) = feeAccumulator
            .crossChainLockData(0);

        assertEq(lockAmount, _ONE);
        assertEq(chainId, 42161);
        assertEq(epoch, nextEpoch);

        skip(veCVE.EPOCH_DURATION() * 2);

        vm.prank(address(protocolMessagingHub));
        feeAccumulator.executeEpochFeeRouter(42161);

        vm.expectRevert();
        feeAccumulator.crossChainLockData(0);

        assertEq(usdc.balanceOf(address(feeAccumulator)), 0);
    }
}
