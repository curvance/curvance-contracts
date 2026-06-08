// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {Faucet} from "contracts/testnet/Faucet.sol";
import {FaucetWithSignature} from "contracts/testnet/FaucetWithSignature.sol";

contract ReentrantFaucetClaimer {
    FaucetWithSignature internal faucet;
    address internal token;
    uint256 internal amount;
    uint256 internal expireAt;
    bytes internal signature;
    bool internal entered;

    bool public reentryBlocked;

    receive() external payable {
        if (entered) {
            return;
        }

        entered = true;
        try faucet.claim(address(this), token, amount, expireAt, signature) {
            reentryBlocked = false;
        } catch {
            reentryBlocked = true;
        }
    }

    function claim(
        FaucetWithSignature faucet_,
        address token_,
        uint256 amount_,
        uint256 expireAt_,
        bytes calldata signature_
    ) external {
        faucet = faucet_;
        token = token_;
        amount = amount_;
        expireAt = expireAt_;
        signature = signature_;

        faucet.claim(address(this), token_, amount_, expireAt_, signature_);
    }
}

contract SimpleFaucetToken {
    mapping(address => uint256) public balanceOf;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address to, uint256 amount)
        public
        virtual
        returns (bool)
    {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReentrantFaucetToken is SimpleFaucetToken {
    Faucet internal faucet;
    address internal victimToken;
    bool internal entered;

    function arm(Faucet faucet_, address victimToken_) external {
        faucet = faucet_;
        victimToken = victimToken_;
    }

    function transfer(address to, uint256 amount)
        public
        override
        returns (bool)
    {
        super.transfer(to, amount);

        if (!entered) {
            entered = true;
            address[] memory tokens = new address[](1);
            tokens[0] = victimToken;
            try faucet.claim(tokens) {} catch {}
        }

        return true;
    }
}

contract TestFaucets is Test {
    function test_removeFaucetToken_removesMiddleToken() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(0xA);
        tokens[1] = address(0xB);
        tokens[2] = address(0xC);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1;
        amounts[1] = 2;
        amounts[2] = 3;

        Faucet faucet = new Faucet(tokens, amounts);
        faucet.removeFaucetToken(address(0xB));

        (address token0, uint256 amount0) = faucet.faucetTokens(0);
        (address token1, uint256 amount1) = faucet.faucetTokens(1);

        assertEq(token0, address(0xA));
        assertEq(amount0, 1);
        assertEq(token1, address(0xC));
        assertEq(amount1, 3);
        vm.expectRevert();
        faucet.faucetTokens(2);
    }

    function test_removeFaucetToken_duplicateDoesNotLeaveZeroEntry() public {
        address[] memory tokens = new address[](4);
        tokens[0] = address(0xA);
        tokens[1] = address(0xB);
        tokens[2] = address(0xB);
        tokens[3] = address(0xC);

        uint256[] memory amounts = new uint256[](4);
        amounts[0] = 1;
        amounts[1] = 2;
        amounts[2] = 22;
        amounts[3] = 3;

        Faucet faucet = new Faucet(tokens, amounts);
        faucet.removeFaucetToken(address(0xB));

        (address token0, uint256 amount0) = faucet.faucetTokens(0);
        (address token1, uint256 amount1) = faucet.faucetTokens(1);
        (address token2, uint256 amount2) = faucet.faucetTokens(2);

        assertEq(token0, address(0xA), "first token should remain listed");
        assertEq(amount0, 1, "first token amount should remain unchanged");
        assertEq(token1, address(0xB), "second duplicate should remain listed");
        assertEq(amount1, 22, "second duplicate amount should remain");
        assertEq(token2, address(0xC), "last token should compact left");
        assertEq(amount2, 3, "last token amount should remain unchanged");
        vm.expectRevert();
        faucet.faucetTokens(3);
    }

    function test_signatureFaucet_marksSignatureBeforeExternalTransfer()
        public
    {
        vm.warp(2 days);

        uint256 signerKey = 0xA11CE;
        address signer = vm.addr(signerKey);
        FaucetWithSignature faucet = new FaucetWithSignature(signer);
        ReentrantFaucetClaimer claimer = new ReentrantFaucetClaimer();

        vm.deal(address(faucet), 1 ether);

        uint256 amount = 0.01 ether;
        uint256 expireAt = block.timestamp + 1 days;
        bytes32 digest = faucet.getMessageHash(
            address(claimer), address(0), amount, expireAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        claimer.claim(faucet, address(0), amount, expireAt, signature);

        assertTrue(claimer.reentryBlocked());
        assertEq(address(claimer).balance, amount);
        assertEq(address(faucet).balance, 1 ether - amount);
        assertTrue(faucet.isSignatureUsed(signature));
    }

    function test_faucet_blocksTokenTransferReentrancyAcrossListedTokens()
        public
    {
        vm.warp(2 days);

        ReentrantFaucetToken maliciousToken = new ReentrantFaucetToken();
        SimpleFaucetToken victimToken = new SimpleFaucetToken();

        address[] memory tokens = new address[](2);
        tokens[0] = address(maliciousToken);
        tokens[1] = address(victimToken);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;

        Faucet faucet = new Faucet(tokens, amounts);
        maliciousToken.arm(faucet, address(victimToken));

        maliciousToken.mint(address(faucet), amounts[0]);
        victimToken.mint(address(faucet), amounts[1]);

        address[] memory claimTokens = new address[](1);
        claimTokens[0] = address(maliciousToken);
        faucet.claim(claimTokens);

        assertEq(maliciousToken.balanceOf(address(this)), amounts[0]);
        assertEq(victimToken.balanceOf(address(maliciousToken)), 0);
        assertEq(victimToken.balanceOf(address(faucet)), amounts[1]);
    }

    function test_signatureFaucet_revertsZeroUser() public {
        uint256 signerKey = 0xB0B;
        address signer = vm.addr(signerKey);
        FaucetWithSignature faucet = new FaucetWithSignature(signer);

        uint256 expireAt = block.timestamp + 1 days;
        bytes32 digest = faucet.getMessageHash(
            address(0), address(0), 0.01 ether, expireAt
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.expectRevert(bytes("Invalid user"));
        faucet.claim(
            address(0),
            address(0),
            0.01 ether,
            expireAt,
            abi.encodePacked(r, s, v)
        );
    }
}
