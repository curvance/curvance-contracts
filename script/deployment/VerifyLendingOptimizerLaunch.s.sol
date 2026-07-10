// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";

import {ICentralRegistry} from "contracts/interfaces/ICentralRegistry.sol";
import {IERC20} from "contracts/interfaces/IERC20.sol";
import {ICToken} from "contracts/interfaces/ICToken.sol";
import {ILendingOptimizer} from "contracts/interfaces/ILendingOptimizer.sol";
import {IMarketManager} from "contracts/interfaces/IMarketManager.sol";
import {ERC165Checker} from "contracts/libraries/external/ERC165Checker.sol";

interface IUnderlyingDependency {
    function underlying() external view returns (address);
}

interface ILPDependency {
    function token0() external view returns (address);

    function token1() external view returns (address);
}

/// @notice Verifies a LendingOptimizer launch snapshot and the connected
///         Curvance cToken dependency graph reached through both `asset()`
///         ancestry and each reached cToken's listed MarketManager siblings.
/// @dev `expectedTerminalAssets` is a reviewed operator attestation, not an
///      automatically inferred classification. Undeclared contracts and known
///      receipt/LP surfaces fail closed, but opaque nonstandard dependencies
///      still require operator review. Known wrapper and LP surfaces are not
///      expanded or exempted here: extend this verifier with typed coverage
///      before admitting them. VerifyOptimizerShareDeScope separately checks
///      declared oracle and integration routes.
contract VerifyLendingOptimizerLaunch is Script {
    error VerifyLendingOptimizerLaunch__InvalidConfig();

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_RECEIPT_DEPTH = 8;
    uint256 internal constant MAX_GRAPH_NODES = 64;

    struct Config {
        address optimizer;
        string expectedName;
        string expectedSymbol;
        address expectedUnderlying;
        address expectedCentralRegistry;
        uint256 expectedFeeBps;
        address[] expectedMarkets;
        uint256[] expectedAllocationCapsWad;
        address[] expectedTerminalAssets;
    }

    struct TraversalState {
        address[] graphNodes;
        bool[] terminalAssetsUsed;
        uint256 graphNodeCount;
    }

    function run() external view {
        Config memory config = Config({
            optimizer: vm.envAddress("LENDING_OPTIMIZER_ADDRESS"),
            expectedName: vm.envString("LENDING_OPTIMIZER_NAME"),
            expectedSymbol: vm.envString("LENDING_OPTIMIZER_SYMBOL"),
            expectedUnderlying: vm.envAddress("LENDING_OPTIMIZER_UNDERLYING"),
            expectedCentralRegistry: vm.envAddress(
                "LENDING_OPTIMIZER_CENTRAL_REGISTRY"
            ),
            expectedFeeBps: vm.envUint("LENDING_OPTIMIZER_FEE_BPS"),
            expectedMarkets: vm.envAddress("LENDING_OPTIMIZER_MARKETS", ","),
            expectedAllocationCapsWad: vm.envUint(
                "LENDING_OPTIMIZER_ALLOCATION_CAPS_WAD", ","
            ),
            expectedTerminalAssets: vm.envAddress(
                "LENDING_OPTIMIZER_TERMINAL_ASSETS", ","
            )
        });

        _verify(config);
    }

    function verify(Config calldata config) external view {
        _verify(config);
    }

    function _verify(Config memory config) internal view {
        _requireContract(config.optimizer);
        _requireContract(config.expectedUnderlying);
        _requireContract(config.expectedCentralRegistry);

        uint256 numExpectedMarkets = config.expectedMarkets.length;
        if (
            numExpectedMarkets == 0
                || numExpectedMarkets
                    != config.expectedAllocationCapsWad.length
        ) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }

        ILendingOptimizer optimizer = ILendingOptimizer(config.optimizer);
        if (
            keccak256(bytes(IERC20(config.optimizer).name()))
                    != keccak256(bytes(config.expectedName))
                || keccak256(bytes(IERC20(config.optimizer).symbol()))
                    != keccak256(bytes(config.expectedSymbol))
                || optimizer.asset() != config.expectedUnderlying
                || address(optimizer.centralRegistry())
                    != config.expectedCentralRegistry
                || optimizer.fee() != config.expectedFeeBps
                || optimizer.numApprovedMarkets() != numExpectedMarkets
        ) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }

        _verifyTerminalAssets(config);
        TraversalState memory state = TraversalState({
            graphNodes: new address[](MAX_GRAPH_NODES),
            terminalAssetsUsed: new bool[](
                config.expectedTerminalAssets.length
            ),
            graphNodeCount: 0
        });

        ICentralRegistry centralRegistry =
            ICentralRegistry(config.expectedCentralRegistry);
        uint256 totalAllocationCaps;
        for (uint256 i; i < numExpectedMarkets; ++i) {
            address expectedMarket = config.expectedMarkets[i];
            _requireContract(expectedMarket);

            if (
                optimizer.approvedCTokensList(i) != expectedMarket
                    || optimizer.allocationCaps(expectedMarket)
                        != config.expectedAllocationCapsWad[i]
                    || !ICToken(expectedMarket).isBorrowable()
                    || ICToken(expectedMarket).asset()
                        != config.expectedUnderlying
            ) {
                revert VerifyLendingOptimizerLaunch__InvalidConfig();
            }

            _enqueueGraphNode(state, expectedMarket);
            totalAllocationCaps += config.expectedAllocationCapsWad[i];
        }

        _verifyConnectedCTokenGraph(config, centralRegistry, state);
        _requireAllTerminalAssetsUsed(state.terminalAssetsUsed);

        if (totalAllocationCaps < WAD) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }
    }

    function _verifyTerminalAssets(Config memory config) internal view {
        _requireTerminalAsset(config, config.expectedUnderlying);

        uint256 numTerminalAssets = config.expectedTerminalAssets.length;
        for (uint256 i; i < numTerminalAssets; ++i) {
            address terminalAsset = config.expectedTerminalAssets[i];
            _requireTerminalAsset(config, terminalAsset);
            if (terminalAsset == config.expectedUnderlying) {
                revert VerifyLendingOptimizerLaunch__InvalidConfig();
            }

            for (uint256 j; j < i; ++j) {
                if (config.expectedTerminalAssets[j] == terminalAsset) {
                    revert VerifyLendingOptimizerLaunch__InvalidConfig();
                }
            }
        }
    }

    function _requireTerminalAsset(Config memory config, address terminalAsset)
        internal
        view
    {
        _requireContract(terminalAsset);
        if (
            terminalAsset == config.optimizer
                || ERC165Checker.supportsInterface(
                    terminalAsset, type(ICToken).interfaceId
                ) || _hasKnownDependencySurface(terminalAsset)
        ) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }
    }

    function _verifyConnectedCTokenGraph(
        Config memory config,
        ICentralRegistry centralRegistry,
        TraversalState memory state
    ) internal view {
        uint256 graphNodeIndex;
        while (graphNodeIndex < state.graphNodeCount) {
            address graphNode = state.graphNodes[graphNodeIndex++];
            IMarketManager marketManager =
                _requireRegisteredCToken(centralRegistry, graphNode);
            address[] memory listedTokens = marketManager.queryTokensListed();
            uint256 numListedTokens = listedTokens.length;
            bool graphNodeFound;

            if (numListedTokens == 0) {
                revert VerifyLendingOptimizerLaunch__InvalidConfig();
            }

            for (uint256 i; i < numListedTokens; ++i) {
                address listedToken = listedTokens[i];
                if (listedToken == graphNode) {
                    graphNodeFound = true;
                }

                for (uint256 j; j < i; ++j) {
                    if (listedTokens[j] == listedToken) {
                        revert VerifyLendingOptimizerLaunch__InvalidConfig();
                    }
                }

                if (
                    address(
                            _requireRegisteredCToken(
                                centralRegistry, listedToken
                            )
                        ) != address(marketManager)
                ) {
                    revert VerifyLendingOptimizerLaunch__InvalidConfig();
                }

                // Sibling edges are graph expansion, not asset-ancestry
                // edges. A sibling pointing back to an already processed
                // market is therefore deduplicated rather than treated as a
                // receipt cycle.
                _enqueueGraphNode(state, listedToken);
            }

            if (!graphNodeFound) {
                revert VerifyLendingOptimizerLaunch__InvalidConfig();
            }

            _verifyReceiptAncestryAndQueue(
                config, centralRegistry, graphNode, state
            );
        }
    }

    function _verifyReceiptAncestryAndQueue(
        Config memory config,
        ICentralRegistry centralRegistry,
        address rootReceipt,
        TraversalState memory state
    ) internal view {
        address[] memory visited = new address[](MAX_RECEIPT_DEPTH);
        address current = rootReceipt;
        uint256 depth;

        while (true) {
            if (current == config.optimizer) {
                revert VerifyLendingOptimizerLaunch__InvalidConfig();
            }

            if (_isTerminalAsset(config, current, state.terminalAssetsUsed)) {
                return;
            }

            if (depth == MAX_RECEIPT_DEPTH) {
                revert VerifyLendingOptimizerLaunch__InvalidConfig();
            }

            for (uint256 i; i < depth; ++i) {
                if (visited[i] == current) {
                    revert VerifyLendingOptimizerLaunch__InvalidConfig();
                }
            }

            _requireRegisteredCToken(centralRegistry, current);
            _enqueueGraphNode(state, current);
            visited[depth] = current;
            current = ICToken(current).asset();
            ++depth;
        }
    }

    function _enqueueGraphNode(TraversalState memory state, address graphNode)
        internal
        pure
    {
        uint256 numGraphNodes = state.graphNodeCount;
        for (uint256 i; i < numGraphNodes; ++i) {
            if (state.graphNodes[i] == graphNode) {
                return;
            }
        }

        if (numGraphNodes == MAX_GRAPH_NODES) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }

        state.graphNodes[numGraphNodes] = graphNode;
        state.graphNodeCount = numGraphNodes + 1;
    }

    function _requireRegisteredCToken(
        ICentralRegistry centralRegistry,
        address cToken
    ) internal view returns (IMarketManager marketManager) {
        _requireContract(cToken);
        if (!ERC165Checker.supportsInterface(
                cToken, type(ICToken).interfaceId
            )) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }

        marketManager = ICToken(cToken).marketManager();
        _requireContract(address(marketManager));
        if (
            !centralRegistry.isMarketManager(address(marketManager))
                || !marketManager.isListed(cToken)
        ) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }
    }

    function _isTerminalAsset(
        Config memory config,
        address asset,
        bool[] memory terminalAssetsUsed
    ) internal pure returns (bool) {
        if (asset == config.expectedUnderlying) {
            return true;
        }

        uint256 numTerminalAssets = config.expectedTerminalAssets.length;
        for (uint256 i; i < numTerminalAssets; ++i) {
            if (config.expectedTerminalAssets[i] == asset) {
                terminalAssetsUsed[i] = true;
                return true;
            }
        }

        return false;
    }

    function _requireAllTerminalAssetsUsed(bool[] memory terminalAssetsUsed)
        internal
        pure
    {
        uint256 numTerminalAssets = terminalAssetsUsed.length;
        for (uint256 i; i < numTerminalAssets; ++i) {
            if (!terminalAssetsUsed[i]) {
                revert VerifyLendingOptimizerLaunch__InvalidConfig();
            }
        }
    }

    function _hasKnownDependencySurface(address target)
        internal
        view
        returns (bool)
    {
        return _respondsToAddressSelector(target, ICToken.asset.selector)
            || _respondsToAddressSelector(
            target, IUnderlyingDependency.underlying.selector
        ) || _respondsToAddressSelector(target, ILPDependency.token0.selector)
            || _respondsToAddressSelector(
            target, ILPDependency.token1.selector
        );
    }

    /// @dev Any successful ABI-sized response is dependency-like, including
    ///      address(0); a zero edge is not evidence that a contract is terminal.
    function _respondsToAddressSelector(address target, bytes4 selector)
        internal
        view
        returns (bool)
    {
        (bool success, bytes memory returnData) =
            target.staticcall(abi.encodeWithSelector(selector));
        return success && returnData.length >= 32;
    }

    function _requireContract(address target) internal view {
        if (target == address(0) || target.code.length == 0) {
            revert VerifyLendingOptimizerLaunch__InvalidConfig();
        }
    }
}
