// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CentralRegistry} from "contracts/architecture/CentralRegistry.sol";
import {MessagingHub} from "contracts/architecture/MessagingHub.sol";
import {VotingHub} from "contracts/architecture/VotingHub.sol";
import {MockERC20Token} from "contracts/mocks/MockERC20Token.sol";

import {WAD_SQUARED} from "contracts/libraries/ConstantsLib.sol";
import {
    ChainConfig,
    ICentralRegistry
} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {EmissionData} from "contracts/interfaces/IMessagingHub.sol";
import {IWormhole} from "contracts/interfaces/external/wormhole/IWormhole.sol";
import {
    IWormholeRelayer
} from "contracts/interfaces/external/wormhole/IWormholeRelayer.sol";

import {QueryTest} from "tests/utils/QueryTest.sol";
import {WormholeMock} from "tests/utils/WormholeMock.sol";

abstract contract P_T7QueryFixture is Test {
    uint256 internal constant _ONE = 1e18;
    uint256 internal constant _GUARDIAN_PRIVATE_KEY =
        0xcfb12303a19cde580bb4dd771639b0d26bc68353645571a8cff516ab2ee113a0;
    uint16 internal constant _REMOTE_MESSAGING_CHAIN_ID = 23;
    uint256 internal constant _REMOTE_GETH_CHAIN_ID = 42161;

    function _buildResponse(
        address remoteConsumer,
        bytes4 selector,
        uint256 result,
        uint64 blockTimeMicros
    ) internal view returns (bytes memory response) {
        bytes memory resultBytes =
            QueryTest.buildEthCallResultBytes(abi.encode(result));
        bytes memory responseBytes = QueryTest.buildEthCallResponseBytes(
            uint64(block.number),
            bytes32(blockhash(block.number)),
            blockTimeMicros,
            1,
            resultBytes
        );
        bytes memory perChainResponse = QueryTest.buildPerChainResponseBytes(
            _REMOTE_MESSAGING_CHAIN_ID, 1, responseBytes
        );

        bytes memory callData = abi.encodeWithSelector(selector);
        bytes memory callDataBytes =
            QueryTest.buildEthCallDataBytes(remoteConsumer, callData);
        bytes memory requestBytes = QueryTest.buildEthCallRequestBytes(
            abi.encode(block.number), 1, callDataBytes
        );
        bytes memory perChainQuery = QueryTest.buildPerChainRequestBytes(
            _REMOTE_MESSAGING_CHAIN_ID, 1, requestBytes
        );
        bytes memory queryRequest = QueryTest.buildOffChainQueryRequestBytes(
            1, 0xdd9914c6, 1, perChainQuery
        );

        response = QueryTest.buildQueryResponseBytes(
            1,
            0,
            hex"ff0c222dc9e3655ec38e212e9792bf1860356d1277462b6bf747db865caca6fc08e6317b64ee3245264e371146b1d315d38c867fe1f69614368dc4430bb560f200",
            queryRequest,
            1,
            perChainResponse
        );
    }

    function _signResponse(bytes memory response)
        internal
        returns (IWormhole.Signature[] memory signatures)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                bytes("query_response_0000000000000000000|"),
                keccak256(response)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(_GUARDIAN_PRIVATE_KEY, digest);
        signatures = new IWormhole.Signature[](1);
        signatures[0] =
            IWormhole.Signature({r: r, s: s, v: v, guardianIndex: 0});
    }

    function _chainConfig(address remoteMessagingHub, address remoteVotingHub)
        internal
        pure
        returns (ChainConfig memory config)
    {
        config.isSupported = true;
        config.messagingChainId = _REMOTE_MESSAGING_CHAIN_ID;
        config.domain = 3;
        config.messagingHub = remoteMessagingHub;
        config.votingHub = remoteVotingHub;
        config.cveAddress = address(0xC0FFEE);
        config.feeTokenAddress = address(0xFEE);
        config.crosschainRelayer = address(0xBEEF);
    }
}

contract VotingHubMultiCoordinatorEpochReusePoC is P_T7QueryFixture {
    struct VotingFixture {
        CentralRegistry registry;
        VotingHub hub;
        MockGaugeManager gaugeManager;
        MockCVE cve;
    }

    WormholeMock internal wormhole;
    MockERC20Token internal feeToken;
    address internal remoteVotingHub = makeAddr("remoteVotingHub");
    address internal gaugeToken = makeAddr("gaugeToken");

    function setUp() public {
        vm.warp(1_800_000_000);
        wormhole = new WormholeMock();
        feeToken = new MockERC20Token();
    }

    function test_samePriorEpochZeroSnapshotLetsTwoCoordinatorsEachConsumeFullCapAndThenExpires()
        public
    {
        uint256 boundary = block.timestamp + 1;
        uint256 genesisEpoch = boundary - 2 weeks;
        VotingFixture memory first = _deployVotingFixture(genesisEpoch);
        VotingFixture memory second = _deployVotingFixture(genesisEpoch);
        VotingFixture memory expiryControl = _deployVotingFixture(genesisEpoch);

        assertEq(first.hub.currentEpoch(), 0, "unexpected pre-boundary epoch");
        bytes memory response = _buildResponse(
            remoteVotingHub,
            VotingHub.queryEmissionsAllocated.selector,
            0,
            uint64(block.timestamp * 1_000_000)
        );
        IWormhole.Signature[] memory signatures = _signResponse(response);

        // The signed zero was observed in epoch 0. It contains no epoch ID,
        // so both independent coordinators accept it in epoch 1.
        vm.warp(boundary);
        assertEq(first.hub.currentEpoch(), 1, "epoch did not advance");
        _executeFullLocalAllocation(first.hub, response, signatures);
        _executeFullLocalAllocation(second.hub, response, signatures);

        assertEq(
            first.registry.emissionsAllocatedByEpoch(1),
            _ONE,
            "first coordinator did not consume its cap"
        );
        assertEq(
            second.registry.emissionsAllocatedByEpoch(1),
            _ONE,
            "second coordinator did not consume its cap"
        );
        assertEq(first.gaugeManager.totalWeight(1), _ONE, "first gauge weight");
        assertEq(
            second.gaugeManager.totalWeight(1), _ONE, "second gauge weight"
        );
        assertEq(
            first.cve.minted(address(first.gaugeManager)), _ONE, "first mint"
        );
        assertEq(
            second.cve.minted(address(second.gaugeManager)),
            _ONE,
            "second mint"
        );
        assertEq(
            first.cve.minted(address(first.gaugeManager))
                + second.cve.minted(address(second.gaugeManager)),
            2 * _ONE,
            "two coordinators did not allocate twice the global target"
        );

        vm.warp(boundary + 300);
        vm.expectRevert(bytes4(keccak256("StaleBlockTime()")));
        _executeFullLocalAllocation(expiryControl.hub, response, signatures);
        assertEq(
            expiryControl.registry.emissionsAllocatedByEpoch(1),
            0,
            "expired response changed registry state"
        );
        assertEq(
            expiryControl.gaugeManager.totalWeight(1),
            0,
            "expired response changed gauge state"
        );
    }

    function test_postCommitSnapshotPreventsSecondFullAllocation() public {
        uint256 genesisEpoch = block.timestamp - 2 weeks;
        VotingFixture memory fixture = _deployVotingFixture(genesisEpoch);

        bytes memory committedResponse = _buildResponse(
            remoteVotingHub,
            VotingHub.queryEmissionsAllocated.selector,
            _ONE,
            uint64(block.timestamp * 1_000_000)
        );
        IWormhole.Signature[] memory signatures =
            _signResponse(committedResponse);

        vm.expectRevert(VotingHub.VotingHub__InvalidParameter.selector);
        _executeFullLocalAllocation(fixture.hub, committedResponse, signatures);
        assertEq(
            fixture.registry.emissionsAllocatedByEpoch(1),
            0,
            "rejected allocation changed registry state"
        );
        assertEq(
            fixture.gaugeManager.totalWeight(1), 0, "rejected gauge weight"
        );
        assertEq(
            fixture.cve.minted(address(fixture.gaugeManager)),
            0,
            "rejected allocation minted CVE"
        );
    }

    function _deployVotingFixture(uint256 genesisEpoch)
        internal
        returns (VotingFixture memory fixture)
    {
        fixture.registry = new CentralRegistry(
            address(this),
            address(this),
            genesisEpoch,
            address(0),
            address(feeToken)
        );
        fixture.registry.setCrosschainCore(address(wormhole));

        fixture.gaugeManager = new MockGaugeManager();
        fixture.cve = new MockCVE();
        fixture.registry.setGaugeManager(address(fixture.gaugeManager));
        fixture.registry.setCVE(address(fixture.cve));

        fixture.hub =
            new VotingHub(ICentralRegistry(address(fixture.registry)));
        fixture.registry.setVotingHub(address(fixture.hub));
        fixture.registry.setEraTargetEmissions(_ONE);
        fixture.registry
            .addChain(
                _REMOTE_GETH_CHAIN_ID,
                _chainConfig(
                    makeAddr("unusedRemoteMessagingHub"), remoteVotingHub
                )
            );
    }

    function _executeFullLocalAllocation(
        VotingHub hub,
        bytes memory response,
        IWormhole.Signature[] memory signatures
    ) internal {
        uint256[] memory gasLimits = new uint256[](1);
        gasLimits[0] = 300_000;

        EmissionData memory local;
        local.tokens = new address[](1);
        local.tokens[0] = gaugeToken;
        local.emissions = new uint256[](1);
        local.emissions[0] = _ONE;

        EmissionData[] memory remote = new EmissionData[](1);
        remote[0].tokens = new address[](0);
        remote[0].emissions = new uint256[](0);

        hub.executeEmissionConfiguration(
            response, signatures, gasLimits, local, remote
        );
    }
}

contract MessagingHubResponseReusePoC is P_T7QueryFixture {
    uint256 internal constant _FEE_AMOUNT = 100e6;

    CentralRegistry internal centralRegistry;
    MessagingHub internal messagingHub;
    WormholeMock internal wormhole;
    MockERC20Token internal feeToken;
    MockRewardManager internal rewardManager;
    MockVeCVE internal veCVE;
    MockFeeManager internal feeManager;
    MockRelayer internal relayer;
    MockTokenMessenger internal tokenMessenger;
    address internal remoteMessagingHub = makeAddr("remoteMessagingHub");

    function setUp() public {
        vm.warp(1_800_000_000);
        wormhole = new WormholeMock();
        feeToken = new MockERC20Token();
        rewardManager = new MockRewardManager(3);
        veCVE = new MockVeCVE(0);
        feeManager = new MockFeeManager();
        relayer = new MockRelayer();
        tokenMessenger = new MockTokenMessenger();

        centralRegistry = new CentralRegistry(
            address(this),
            address(this),
            block.timestamp - 2 weeks,
            address(0),
            address(feeToken)
        );
        centralRegistry.setCrosschainCore(address(wormhole));
        centralRegistry.setCrosschainRelayer(address(relayer));
        centralRegistry.setTokenMessager(address(tokenMessenger));
        centralRegistry.setRewardManager(address(rewardManager));
        centralRegistry.setVeCVE(address(veCVE));
        centralRegistry.setFeeManager(address(feeManager));
        centralRegistry.setGaugeManager(address(new MockGaugeManager()));

        messagingHub =
            new MessagingHub(ICentralRegistry(address(centralRegistry)));
        centralRegistry.setMessagingHub(address(messagingHub));
        centralRegistry.addChain(
            _REMOTE_GETH_CHAIN_ID,
            _chainConfig(remoteMessagingHub, makeAddr("unusedRemoteVotingHub"))
        );
    }

    function test_identicalResponseAdvancesTwoEpochsWhileFreshZeroChangesSecondEpoch()
        public
    {
        bytes memory nonzeroResponse = _buildResponse(
            remoteMessagingHub,
            MessagingHub.queryLockPoints.selector,
            _ONE,
            uint64(block.timestamp * 1_000_000)
        );
        IWormhole.Signature[] memory nonzeroSignatures =
            _signResponse(nonzeroResponse);
        uint256 expectedRewardsPerPoint = (_FEE_AMOUNT * WAD_SQUARED) / _ONE;

        uint256 snapshot = vm.snapshotState();
        _fundAndExecute(nonzeroResponse, nonzeroSignatures);
        _fundAndExecute(nonzeroResponse, nonzeroSignatures);

        assertEq(
            rewardManager.nextEpochToDeliver(),
            2,
            "reuse did not advance twice"
        );
        assertEq(
            rewardManager.epochRewardsPerPoint(0),
            expectedRewardsPerPoint,
            "first reused value was not applied"
        );
        assertEq(
            rewardManager.epochRewardsPerPoint(1),
            expectedRewardsPerPoint,
            "identical response was not applied to second epoch"
        );
        assertEq(
            feeToken.balanceOf(address(tokenMessenger)),
            2 * _FEE_AMOUNT,
            "two reused distributions did not send the same remote value"
        );

        assertTrue(
            vm.revertToState(snapshot), "failed to restore comparison state"
        );
        _fundAndExecute(nonzeroResponse, nonzeroSignatures);

        bytes memory zeroResponse = _buildResponse(
            remoteMessagingHub,
            MessagingHub.queryLockPoints.selector,
            0,
            uint64(block.timestamp * 1_000_000)
        );
        IWormhole.Signature[] memory zeroSignatures =
            _signResponse(zeroResponse);
        _fundAndExecute(zeroResponse, zeroSignatures);

        assertEq(
            rewardManager.nextEpochToDeliver(),
            2,
            "control did not advance twice"
        );
        assertEq(
            rewardManager.epochRewardsPerPoint(0),
            expectedRewardsPerPoint,
            "control first epoch changed"
        );
        assertEq(
            rewardManager.epochRewardsPerPoint(1),
            0,
            "fresh zero did not change the second epoch"
        );
        assertEq(
            feeToken.balanceOf(address(tokenMessenger)),
            _FEE_AMOUNT,
            "fresh zero unexpectedly repeated remote fee delivery"
        );
        assertEq(
            feeToken.balanceOf(centralRegistry.daoAddress()),
            _FEE_AMOUNT,
            "zero-points control did not route fees to DAO"
        );
    }

    function _fundAndExecute(
        bytes memory response,
        IWormhole.Signature[] memory signatures
    ) internal {
        feeToken.mint(address(messagingHub), _FEE_AMOUNT);
        messagingHub.executeEpoch(response, signatures, 0, 300_000);
    }
}

contract MockGaugeManager {
    mapping(uint256 => uint256) public totalWeight;
    mapping(uint256 => mapping(address => uint256)) public tokenWeight;

    function setEmissionRates(
        uint256 epoch,
        address[] memory tokens,
        uint256[] memory weights
    ) external {
        for (uint256 i; i < tokens.length; ++i) {
            tokenWeight[epoch][tokens[i]] += weights[i];
            totalWeight[epoch] += weights[i];
        }
    }

    function currentEpoch() external pure returns (uint256) {
        return 0;
    }
}

contract MockCVE {
    mapping(address => uint256) public minted;

    function mintGaugeEmissions(address gaugeManager, uint256 amount)
        external
    {
        minted[gaugeManager] += amount;
    }
}

contract MockRewardManager {
    uint256 public nextEpochToDeliver;
    uint256 public immutable reportedCurrentEpoch;
    mapping(uint256 => uint256) public epochRewardsPerPoint;

    constructor(uint256 currentEpoch_) {
        reportedCurrentEpoch = currentEpoch_;
    }

    function currentEpoch(uint256) external view returns (uint256) {
        return reportedCurrentEpoch;
    }

    function recordEpochRewards(uint256 rewardsPerPoint) external {
        epochRewardsPerPoint[nextEpochToDeliver] = rewardsPerPoint;
        ++nextEpochToDeliver;
    }

    function isShutdown() external pure returns (uint256) {
        return 1;
    }
}

contract MockVeCVE {
    uint256 public immutable chainPoints;

    constructor(uint256 chainPoints_) {
        chainPoints = chainPoints_;
    }

    function chainUnlocksByEpoch(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockFeeManager {
    function pullFees(uint256) external pure returns (uint256) {
        return 0;
    }
}

contract MockTokenMessenger {
    uint64 internal _nonce;

    function remoteTokenMessengers(uint32) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function depositForBurnWithCaller(
        uint256 amount,
        uint32,
        bytes32,
        address burnToken,
        bytes32
    ) external returns (uint64 nonce) {
        require(
            IERC20(burnToken).transferFrom(msg.sender, address(this), amount),
            "transfer failed"
        );
        nonce = ++_nonce;
    }
}

contract MockRelayer {
    uint64 internal _sequence;

    function quoteEVMDeliveryPrice(uint16, uint256, uint256)
        external
        pure
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    function getDefaultDeliveryProvider() external view returns (address) {
        return address(this);
    }

    function sendPayloadToEvm(uint16, address, bytes memory, uint256, uint256)
        external
        payable
        returns (uint64 sequence)
    {
        sequence = ++_sequence;
    }

    function sendPayloadToEvm(
        uint16,
        address,
        bytes memory,
        uint256,
        uint256,
        uint16,
        address
    ) external payable returns (uint64 sequence) {
        sequence = ++_sequence;
    }

    function sendToEvm(
        uint16,
        address,
        bytes memory,
        uint256,
        uint256,
        uint256,
        uint16,
        address,
        address,
        IWormholeRelayer.MessageKey[] memory,
        uint8
    ) external payable returns (uint64 sequence) {
        sequence = ++_sequence;
    }
}
