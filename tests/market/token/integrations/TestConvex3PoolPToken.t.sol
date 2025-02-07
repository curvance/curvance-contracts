// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

// Need evm_version shanghai to make this tests pass

// import { SwapperLib } from "contracts/libraries/SwapperLib.sol";
// import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
// import { Convex3PoolPToken, IERC20 } from "contracts/market/token/Convex3PoolPToken.sol";

// import "tests/market/TestBaseMarket.sol";

// contract TestConvex3PoolPToken is TestBaseMarket {
//     address internal constant _UNISWAP_V2_ROUTER =
//         0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

//     IERC20 public constant CVX =
//         IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
//     IERC20 public constant CRV =
//         IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
//     IERC20 public constant WETH =
//         IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
//     IERC20 public CONVEX_USDT_WBTC_WETH_POOL =
//         IERC20(0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4);
//     uint256 public CONVEX_USDT_WBTC_WETH_POOL_ID = 188;
//     address public CONVEX_USDT_WBTC_WETH_REWARD =
//         0xb05262D4aaAA38D0Af4AaB244D446ebDb5afd4A7;
//     address public CONVEX_BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

//     Convex3PoolPToken public pToken;

//     /*
//     LP token address	0xf5f5B97624542D72A9E06f04804Bf81baA15e2B4
//     Deposit contract address	0xF403C135812408BFbE8713b5A23a04b3D48AAE31
//     Rewards contract address	0xb05262D4aaAA38D0Af4AaB244D446ebDb5afd4A7
//     Convex pool id	188
//     Convex pool url	https://www.convexfinance.com/stake/ethereum/188
//     */

//     receive() external payable {}

//     fallback() external payable {}

//     function setUp() public override {
//         super.setUp();

//         centralRegistry.addHarvester(address(this));
//         centralRegistry.setFeeManager(address(this));

//         // start epoch
//         // vm.warp(gaugeManager.gaugeStartTime());
//         vm.roll(block.number + 1000);

//         pToken = new Convex3PoolPToken(
//             ICentralRegistry(address(centralRegistry)),
//             CONVEX_USDT_WBTC_WETH_POOL,
//             address(marketManager),
//             CONVEX_USDT_WBTC_WETH_POOL_ID,
//             CONVEX_USDT_WBTC_WETH_REWARD,
//             CONVEX_BOOSTER
//         );

//         address owner = address(this);
//         deal(address(CONVEX_USDT_WBTC_WETH_POOL), owner, 1 ether);
//         CONVEX_USDT_WBTC_WETH_POOL.approve(address(pToken), 1 ether);
//         marketManager.listToken(address(pToken));
//     }

//     function testConvexUsdtWbtcWethPool() public {
//         uint256 assets = 100e18;
//         deal(address(CONVEX_USDT_WBTC_WETH_POOL), user1, assets);

//         vm.prank(user1);
//         CONVEX_USDT_WBTC_WETH_POOL.approve(address(pToken), assets);

//         vm.prank(user1);
//         pToken.deposit(assets, user1);

//         assertEq(
//             pToken.totalAssets(),
//             assets + 42069,
//             "Total Assets should equal user deposit."
//         );

//         // Advance time to earn CRV and CVX rewards
//         vm.warp(block.timestamp + 3 days);

//         // Mint some extra rewards for Vault.
//         deal(address(CRV), address(pToken), 100e18);
//         deal(address(CVX), address(pToken), 100e18);
//         deal(address(WETH), address(pToken), 1 ether);

//         pToken.harvest(abi.encode(new SwapperLib.Swap[](0)));

//         assertEq(
//             pToken.totalAssets(),
//             assets + 42069,
//             "Total Assets should equal user deposit."
//         );

//         vm.warp(block.timestamp + 8 days);

//         // Mint some extra rewards for Vault.
//         deal(address(CRV), address(pToken), 100e18);
//         deal(address(CVX), address(pToken), 100e18);
//         deal(address(WETH), address(pToken), 1 ether);
//         pToken.harvest(abi.encode(new SwapperLib.Swap[](0)));
//         vm.warp(block.timestamp + 7 days);

//         uint256 totalAssets = pToken.totalAssets();

//         assertGt(
//             totalAssets,
//             assets + 42069,
//             "Total Assets should greater than original deposit."
//         );

//         vm.startPrank(user1);
//         pToken.withdraw(pToken.balanceOf(user1), user1, user1);
//         vm.stopPrank();
//     }
// }
