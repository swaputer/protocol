// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwaputerSRC20MarketFactory} from "../src/SwaputerSRC20MarketFactory.sol";

contract DeploySRC20MarketFactoryScript is Script {
    bytes32 internal constant ESCROW_CODE_HASH = 0x6da9921193ebfe79468ef74f5b94925b66bf8230e145234a77868f1e5a85614b;
    bytes32 internal constant TRUSTED_TOKEN_CODE_HASH =
        0xaedd7bd1543d57afaeb94f6b46e28ba4c1ef7cdd2ad4affca011b17056036869;

    function run() external returns (SwaputerSRC20MarketFactory marketFactory) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address router = vm.envAddress("SVM_ROUTER_ADDRESS");
        bytes32 worldId = vm.envBytes32("SVM_WORLD_ID");
        vm.startBroadcast(deployerKey);
        marketFactory = new SwaputerSRC20MarketFactory(
            SwapVMRouter(payable(router)), worldId, ESCROW_CODE_HASH, TRUSTED_TOKEN_CODE_HASH
        );
        vm.stopBroadcast();

        console2.log("SRC20 market factory", address(marketFactory));
        console2.logBytes32(marketFactory.worldId());
        console2.logBytes32(marketFactory.escrowCodeHash());
        console2.logBytes32(marketFactory.trustedTokenCodeHash());
    }
}
