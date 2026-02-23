// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { InitialDistribution } from "contracts/misc/InitialDistribution.sol";

import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";

import "tests/market/TestBaseMarketIsolated.sol";
import "tests/utils/merkle/Merkle.sol";

contract TestInitialDistribution is TestBaseMarketIsolated {
    uint256 public constant USER_LENGTH = 10;

    InitialDistribution public distributor;
    Merkle public merkle;

    uint256 public maxClaimAmount = 3000000 ether;
    address[] public users;
    uint256[] public amounts;
    bytes32[] public leafs;
    bytes32 public root;

    function setUp() public override {
        super.setUp();

        distributor = new InitialDistribution(
            ICentralRegistry(address(centralRegistry)),
            maxClaimAmount
        );

        cve.transfer(address(distributor), cve.balanceOf(address(this)));

        for (uint256 i = 0; i < USER_LENGTH; i++) {
            users.push(address(uint160(10000000 + i)));
            amounts.push(100 ether * (i + 1));
            leafs.push(keccak256(abi.encodePacked(users[i], amounts[i])));
        }

        merkle = new Merkle();
        root = merkle.getRoot(leafs);
    }

    function testInitialize() public {
        assertEq(distributor.cve(), address(cve));
    }

    function testSetMerkleRoot() public {
        vm.expectRevert(
            InitialDistribution
                .InitialDistribution__ParametersAreInvalid
                .selector
        );
        distributor.setMerkleRoot(bytes32(0));

        assertEq(distributor.merkleRoot(), bytes32(0));
        distributor.setMerkleRoot(root);
        assertEq(distributor.merkleRoot(), root);
    }

    function testSetPauseState() public {
        assertEq(distributor.isPaused(), 2);
        distributor.setPauseState(false);
        assertEq(distributor.isPaused(), 1);
        assertEq(distributor.endClaimTimestamp(), block.timestamp + 6 weeks);
        distributor.setPauseState(true);
        assertEq(distributor.isPaused(), 2);
    }

    function testCanClaim() public {
        distributor.setMerkleRoot(root);
        distributor.setPauseState(false);

        for (uint256 i = 0; i < USER_LENGTH; i++) {
            bytes32[] memory proof = merkle.getProof(leafs, i);
            assertEq(distributor.canClaim(users[i], amounts[i], proof), true);
        }
    }

    function testClaimWithoutLock() public {
        distributor.setMerkleRoot(root);
        distributor.setPauseState(false);

        for (uint256 i = 0; i < USER_LENGTH; i++) {
            bytes32[] memory proof = merkle.getProof(leafs, i);

            vm.prank(users[i]);
            distributor.claim(amounts[i], false, proof);

            assertEq(cve.balanceOf(users[i]), amounts[i]);
        }
    }

    function testClaimWithLock() public {
        distributor.setMerkleRoot(root);
        distributor.setPauseState(false);

        centralRegistry.addLockingPermissions(address(distributor));

        _recordEpochRewards(1, 1e6 * _ONE);
        _skipRestrictionDuration();

        for (uint256 i = 0; i < USER_LENGTH; i++) {
            bytes32[] memory proof = merkle.getProof(leafs, i);

            vm.prank(users[i]);
            distributor.claim(amounts[i], true, proof);

            assertEq(
                veCVE.balanceOf(users[i]),
                amounts[i] * distributor.lockedClaimMultiplier()
            );
        }
    }

    function testClaimRevert__Paused() public {
        distributor.setMerkleRoot(root);

        bytes32[] memory proof = merkle.getProof(leafs, 0);

        vm.prank(users[0]);

        vm.expectRevert(
            InitialDistribution.InitialDistribution__Paused.selector
        );
        distributor.claim(amounts[0], false, proof);
    }

    function testClaimRevert__ParametersAreInvalid() public {
        distributor.setMerkleRoot(root);
        distributor.setPauseState(false);

        bytes32[] memory proof = merkle.getProof(leafs, 0);

        vm.prank(users[0]);

        vm.expectRevert(
            InitialDistribution
                .InitialDistribution__ParametersAreInvalid
                .selector
        );
        distributor.claim(maxClaimAmount + 1, false, proof);
    }

    function testClaimRevert__Unauthorized() public {
        distributor.setPauseState(false);

        bytes32[] memory proof = merkle.getProof(leafs, 0);
        vm.prank(users[0]);

        vm.expectRevert(
            InitialDistribution
                .InitialDistribution__Unauthorized
                .selector
        );
        distributor.claim(amounts[0], false, proof);
    }

    function testClaimRevert__NotEligible() public {
        distributor.setMerkleRoot(root);
        distributor.setPauseState(false);

        bytes32[] memory proof = merkle.getProof(leafs, 0);
        vm.startPrank(users[0]);

        distributor.claim(amounts[0], false, proof);

        vm.expectRevert(
            InitialDistribution.InitialDistribution__NotEligible.selector
        );
        distributor.claim(amounts[0], false, proof);

        skip(7 weeks);

        vm.expectRevert(
            InitialDistribution.InitialDistribution__NotEligible.selector
        );
        distributor.claim(amounts[0], false, proof);

        vm.stopPrank();
    }

    event debugUint(string, uint256);
    function testRescueTokenETH_success() public {

        // rescue all ETH
        uint256 ethBalanceOfThisBefore = address(this).balance;

        deal(address(distributor), 1 ether);
        distributor.rescueToken(address(0), 0);

        uint256 ethBalanceOfThisAfter = address(this).balance;

        uint256 ethBalanceRecovered = ethBalanceOfThisAfter - ethBalanceOfThisBefore;

        assertEq(ethBalanceRecovered, 1 ether);
        assertEq(address(distributor).balance, 0);
        
        // rescue exact amount of ETH

        ethBalanceOfThisBefore = address(this).balance;

        deal(address(distributor), 100 ether);

        distributor.rescueToken(address(0), 50 ether);

        ethBalanceOfThisAfter = address(this).balance;

        ethBalanceRecovered = ethBalanceOfThisAfter - ethBalanceOfThisBefore;

        assertEq(ethBalanceRecovered, 50 ether);
        assertEq(address(distributor).balance, 50 ether);

    }

    function testRescueTokenERC20_success() public {

        // rescue all USDC

        _prepareUSDC(address(distributor), 100e6);

        uint256 usdcBalanceOfThisBefore = usdc.balanceOf(address(this));

        distributor.rescueToken(address(usdc), 100e6);

        uint256 usdcBalanceOfThisAfter = usdc.balanceOf(address(this));

        uint256 usdcBalanceRecovered = usdcBalanceOfThisAfter - usdcBalanceOfThisBefore;

        assertEq(usdcBalanceRecovered, 100e6);
        assertEq(usdc.balanceOf(address(distributor)), 0);

        // rescue exact amount of USDC

        _prepareUSDC(address(distributor), 100e6);

        usdcBalanceOfThisBefore = usdc.balanceOf(address(this));

        distributor.rescueToken(address(usdc), 50e6);

        usdcBalanceOfThisAfter = usdc.balanceOf(address(this));

        usdcBalanceRecovered = usdcBalanceOfThisAfter - usdcBalanceOfThisBefore;

        assertEq(usdcBalanceRecovered, 50e6);
        assertEq(usdc.balanceOf(address(distributor)), 50e6);

    }

    function testRescueTokenUnauthorized_fail() public {

        vm.startPrank(user1);
        vm.expectRevert(
            InitialDistribution.InitialDistribution__Unauthorized.selector
        );
        distributor.rescueToken(address(0), 0);

    }

    function testRescueCVE_fail() public {

        vm.expectRevert(
            InitialDistribution.InitialDistribution__TransferError.selector
        );
        distributor.rescueToken(address(cve), 0);

    }

    function testWithdrawRemainingTokens_success() public {

        distributor.setPauseState(false);

        uint256 cveBalanceOfThisBefore = cve.balanceOf(address(this));
        uint256 cveBalanceOfDistributorBefore = cve.balanceOf(address(distributor));

        skip(7 weeks);
        
        distributor.withdrawRemainingTokens();

        uint256 cveBalanceOfThisAfter = cve.balanceOf(address(this));
        uint256 cveBalanceOfDistributorAfter = cve.balanceOf(address(distributor));

        assertEq(cveBalanceOfThisAfter, cveBalanceOfDistributorBefore);
        assertEq(cveBalanceOfDistributorAfter, 0);
    }



    // this test contract is the DAO address
    receive() external payable {}
}
