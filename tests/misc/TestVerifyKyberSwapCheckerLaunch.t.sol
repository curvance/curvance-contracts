// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    VerifyKyberSwapCheckerLaunch
} from "script/deployment/VerifyKyberSwapCheckerLaunch.s.sol";
import {
    KyberSwapChecker
} from "contracts/calldata-checker/swap-checker/KyberSwapChecker.sol";
import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";

contract VerifyKyberSwapCheckerLaunchRegistry {
    address public immutable daoAddress;
    mapping(address => address) public externalCalldataChecker;

    constructor(address daoAddress_) {
        daoAddress = daoAddress_;
    }

    function setExternalCalldataChecker(address target, address checker)
        external
    {
        externalCalldataChecker[target] = checker;
    }

    function hasDaoPermissions(address addressToCheck)
        external
        view
        returns (bool)
    {
        return addressToCheck == daoAddress;
    }

    function supportsInterface(bytes4 interfaceId)
        external
        pure
        returns (bool)
    {
        return interfaceId == 0x01ffc9a7
            || interfaceId == type(ICentralRegistry).interfaceId;
    }
}

contract TestVerifyKyberSwapCheckerLaunch is Test {
    address internal constant KYBER_ROUTER =
        0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address internal constant KYBER_EXECUTOR =
        0x63242A4Ea82847b20E506b63B0e2e2eFF0CC6cB0;
    address internal constant PLANNED_KYBER_EXECUTOR =
        0x4a16958D2041044C67c8F33017a75693Cc58F7CC;
    address internal constant CURRENT_API_KYBER_EXECUTOR =
        0x8F10B468b06c6FD214B65F87778827F7D113f996;

    VerifyKyberSwapCheckerLaunch internal script;
    VerifyKyberSwapCheckerLaunchRegistry internal registry;
    KyberSwapChecker internal checker;

    function setUp() public {
        vm.chainId(143);
        vm.etch(KYBER_ROUTER, hex"01");

        script = new VerifyKyberSwapCheckerLaunch();
        registry = new VerifyKyberSwapCheckerLaunchRegistry(address(this));

        address[] memory approvedExecutors = new address[](2);
        approvedExecutors[0] = KYBER_EXECUTOR;
        approvedExecutors[1] = CURRENT_API_KYBER_EXECUTOR;
        checker = new KyberSwapChecker(
            KYBER_ROUTER, approvedExecutors, address(registry)
        );
        registry.setExternalCalldataChecker(KYBER_ROUTER, address(checker));
    }

    function test_verifyKyberSwapCheckerLaunch_acceptsExpectedConfig() public {
        script.verify(_config());
    }

    function test_verifyKyberSwapCheckerLaunch_rejectsMissingRegistryMapping()
        public
    {
        registry.setExternalCalldataChecker(KYBER_ROUTER, address(0));

        vm.expectRevert(
            VerifyKyberSwapCheckerLaunch.VerifyKyberSwapCheckerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyKyberSwapCheckerLaunch_rejectsWrongCheckerTarget()
        public
    {
        address wrongRouter = makeAddr("wrongRouter");
        vm.etch(wrongRouter, hex"01");

        address[] memory approvedExecutors = new address[](2);
        approvedExecutors[0] = KYBER_EXECUTOR;
        approvedExecutors[1] = CURRENT_API_KYBER_EXECUTOR;
        KyberSwapChecker wrongChecker = new KyberSwapChecker(
            wrongRouter, approvedExecutors, address(registry)
        );
        registry.setExternalCalldataChecker(
            KYBER_ROUTER, address(wrongChecker)
        );

        vm.expectRevert(
            VerifyKyberSwapCheckerLaunch.VerifyKyberSwapCheckerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyKyberSwapCheckerLaunch_rejectsWrongRegistry() public {
        VerifyKyberSwapCheckerLaunchRegistry wrongRegistry =
            new VerifyKyberSwapCheckerLaunchRegistry(address(this));

        address[] memory approvedExecutors = new address[](2);
        approvedExecutors[0] = KYBER_EXECUTOR;
        approvedExecutors[1] = CURRENT_API_KYBER_EXECUTOR;
        KyberSwapChecker wrongChecker = new KyberSwapChecker(
            KYBER_ROUTER, approvedExecutors, address(wrongRegistry)
        );
        registry.setExternalCalldataChecker(
            KYBER_ROUTER, address(wrongChecker)
        );

        vm.expectRevert(
            VerifyKyberSwapCheckerLaunch.VerifyKyberSwapCheckerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyKyberSwapCheckerLaunch_rejectsCodehashMismatch()
        public
    {
        VerifyKyberSwapCheckerLaunch.Config memory config = _config();
        config.expectedCheckerCodeHash = bytes32(uint256(1));

        vm.expectRevert(
            VerifyKyberSwapCheckerLaunch.VerifyKyberSwapCheckerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyKyberSwapCheckerLaunch_rejectsFeeMismatch() public {
        VerifyKyberSwapCheckerLaunch.Config memory config = _config();
        config.expectedFeeBps = 5;

        vm.expectRevert(
            VerifyKyberSwapCheckerLaunch.VerifyKyberSwapCheckerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyKyberSwapCheckerLaunch_rejectsFlagsMismatch() public {
        VerifyKyberSwapCheckerLaunch.Config memory config = _config();
        config.expectedRequiredFlags = 0x80;

        vm.expectRevert(
            VerifyKyberSwapCheckerLaunch.VerifyKyberSwapCheckerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyKyberSwapCheckerLaunch_rejectsMissingApprovedExecutor()
        public
    {
        VerifyKyberSwapCheckerLaunch.Config memory config = _config();
        config.approvedExecutors[1] = PLANNED_KYBER_EXECUTOR;

        vm.expectRevert(
            VerifyKyberSwapCheckerLaunch.VerifyKyberSwapCheckerLaunch__InvalidConfig
                .selector
        );
        script.verify(config);
    }

    function test_verifyKyberSwapCheckerLaunch_rejectsUnexpectedApprovedExecutor()
        public
    {
        vm.prank(address(this));
        checker.setExecutorApproval(PLANNED_KYBER_EXECUTOR, true);

        vm.expectRevert(
            VerifyKyberSwapCheckerLaunch.VerifyKyberSwapCheckerLaunch__InvalidConfig
                .selector
        );
        script.verify(_config());
    }

    function test_verifyKyberSwapCheckerLaunch_runReadsEnvTuple() public {
        vm.setEnv("KYBER_CENTRAL_REGISTRY", vm.toString(address(registry)));
        vm.setEnv("KYBER_ROUTER", vm.toString(KYBER_ROUTER));
        vm.setEnv("KYBER_CHECKER", vm.toString(address(checker)));
        vm.setEnv(
            "KYBER_CHECKER_CODEHASH", vm.toString(address(checker).codehash)
        );
        vm.setEnv("KYBER_EXPECTED_FEE_BPS", "4");
        vm.setEnv("KYBER_EXPECTED_REQUIRED_FLAGS", "640");
        vm.setEnv(
            "KYBER_APPROVED_EXECUTORS",
            string.concat(
                vm.toString(KYBER_EXECUTOR),
                ",",
                vm.toString(CURRENT_API_KYBER_EXECUTOR)
            )
        );
        vm.setEnv(
            "KYBER_UNAPPROVED_EXECUTORS", vm.toString(PLANNED_KYBER_EXECUTOR)
        );

        script.run();
    }

    function _config()
        internal
        view
        returns (VerifyKyberSwapCheckerLaunch.Config memory config)
    {
        address[] memory approvedExecutors = new address[](2);
        approvedExecutors[0] = KYBER_EXECUTOR;
        approvedExecutors[1] = CURRENT_API_KYBER_EXECUTOR;

        address[] memory unapprovedExecutors = new address[](1);
        unapprovedExecutors[0] = PLANNED_KYBER_EXECUTOR;

        config = VerifyKyberSwapCheckerLaunch.Config({
            registry: address(registry),
            router: KYBER_ROUTER,
            checker: address(checker),
            expectedCheckerCodeHash: address(checker).codehash,
            expectedFeeBps: 4,
            expectedRequiredFlags: 0x280,
            approvedExecutors: approvedExecutors,
            unapprovedExecutors: unapprovedExecutors
        });
    }
}
