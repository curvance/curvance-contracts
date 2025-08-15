// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { PythAdaptor } from "contracts/oracles/adaptors/pyth/PythAdaptor.sol";
import { ChainlinkAdaptor } from "contracts/oracles/adaptors/chainlink/ChainlinkAdaptor.sol";
import { OracleManager } from "contracts/oracles/OracleManager.sol";
import { ICentralRegistry } from "contracts/interfaces/ICentralRegistry.sol";
import { TestBaseOracleManager } from "../TestBaseOracleManager.sol";

contract TestPythAdaptor is TestBaseOracleManager {
    address internal _PYTH_ADDRESS =
        0x4305FB66699C3B2702D4d05CF36551390A4c69C6;

    PythAdaptor public adaptor;

    receive() external payable {}

    function setUp() public override {
        _fork(18031848);

        
        _deployCentralRegistry();
        _deployOracleManager();

        chainlinkAdaptor = new ChainlinkAdaptor(
            ICentralRegistry(address(centralRegistry))
        );

        adaptor = new PythAdaptor(
            ICentralRegistry(address(centralRegistry)),
            address(0),
            _PYTH_ADDRESS,
            _WETH_ADDRESS
        );

        adaptor.addAsset(
            _WBTC_ADDRESS,
            true,
            1 days,
            0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
        );
        vm.warp(1711335100);

        oracleManager.addApprovedAdaptor(address(chainlinkAdaptor));

        oracleManager.addApprovedAdaptor(address(adaptor));
    }

    function testReturnsCorrectPrice() public {
        bytes[] memory priceUpdateData = new bytes[](1);
        priceUpdateData[
            0
        ] = hex"504e41550100000003b801000000030d020a7b7ffb72301af2e092a12e041ae6a78170dd07c24e217cbdb0a8039e7d18bb7c6ee9ef2ccda22577215495b143d8c4fc1176df69b764b40f158016a8cf36b60104757f964d92c47d33631cee4dfccc3f45f42bff015c2aa83acd9e74c67f9fbb511883c492b57008527dd56aa7e9c7ab6ad1eb4673893bbd009416bd61b7a4ceae010610d9d51d01e93ced4f599587306e2cbf14f471a1a1b1bc39acca921e151e900153ce57ccd5c4c19db9ec502e08c79efc685732f8ae5d3e0335dd089c01631ce1010755010fd2bc0912835c143b27631a1f09b6b86fa9f822a2662b86657a27a4167a2fa8edf27d95ecd61dbf58117708bfb53c066d3b3469557d1d00ed8f5c8834740108f4f2534dfe7b5e87281781e484a73d551c43a653e42eb9fd6a7ead250818127e5752b2ff21d506e2bdf282f285cf69c0524c1cf7e2af57a94873cb6960d324d9000ae6b90a7c36433981ece47bceaae676f9ccddf914d8946cfe96a8ebe8cb216a4c1771dcbd25185dfbf357b286d4184f05eb8aef1291cd63812adeb985335d03dc010b78e0948b52499efb548bb218faa4571a10262b8b0272a8ff49ba22c233f571f54089fe5c3ebcf288b26167fe5b8b9a228a9e6dff67f41891c4753bda84909776000c5d6372be8617082f53254f65208281699e8e596d7d1e88fb582972db79b175477322fcf6552372705607547505608d66d619dadac3a9c851df4e899b61d44466010de8d731d9ff0d060c26b12e4dc49cd9b34135747110f0ec2a2d5e86607cce8f2d228fb25235f29792f4af72b462765aadf5cb08cf697f8a2ba578ed49c2e1160f000ed1bb44ca27af02ea6f6779add5b9f7b0195785c09d245c1616e13d9db157dabe75c9ce4a3acf87042e8ef1c40bed721a87c1d96c828a52b5698583445bc691ea000f94ba9e599f54e41b51fd4c491d005c0d5af40f0f10000a59abac698a4cbc49880ebe0e82747521b39e5f569ad1cf97e502327247b09a171e0765a490629c4a370110f22d63f7e49ff0b3873f5cb6877f32e0cf380085edb6a0e66802b8a24a9ebdf6051cfea4cf5da6aad6458b1a1594884729d409b38edb984a7aced5ab821345e5011221e43e4720c590a639eb09094bcfed44c5785cda54eb50353291c6a746f4d1d15548b670b3c3a28135612df19df50d3dbbdeb6cc9566dd4a259b18b100d3543d016600e58e00000000001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa710000000002c780310141555756000000000007d0d7e7000027101d0fab54a256ec0b3c3d1cfdf581e7e6247f470401005500e62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b4300000610b389158800000000b8380842fffffff8000000006600e58e000000006600e58e00000610a18e492000000000c09246340a941e1745f663bb2f0eea9f8e51a7036d28a429632fe998b4d09fa9eb8a81c4cc48e6ed6417f53e8f49671b3ebceff073d9aea4752c8a8cc7fd70d0e3204f5d77edd037f1be9594667373c44c2cc78f64be672d431343901f8cbd68b2aad00861c1a6a962d6c58076ebfd33b19e54a97917a8c27987ce112e71b572ade229c085913ca65a283db13d8d936027d9e7ff1e3c18ce00f076d7f4503ed097bf8f36a55d815057287f9662e45a90bc4475fcc14514eca3077251162e95954ca370843e8d4e5c1a49299797";
        adaptor.updateFeedsWithNative{ value: 1 ether }(priceUpdateData);
        oracleManager.addAssetPriceFeed(_WBTC_ADDRESS, address(adaptor));

        (uint256 price, uint256 errorCode) = oracleManager.getPrice(
            _WBTC_ADDRESS,
            true,
            false
        );
        assertEq(errorCode, 0);
        assertEq(price, 66688013490000000000000);
    }
}
