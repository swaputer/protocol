// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {SwapVMRouter} from "../src/SwapVMRouter.sol";
import {SwaputerSRC20AuctionFactory} from "../src/SwaputerSRC20AuctionFactory.sol";

contract DeploySRC20AuctionFactoryScript is Script {
    bytes32 internal constant ESCROW_CODE_HASH = 0x0b68683f866e3e83789420824530612988d5e7bfa4f372c2f84c80b75c7cf53a;
    // The auction page is a reference application for the canonical public-mint
    // SRC20 program, not part of the protocol indexer surface.
    bytes32 internal constant TRUSTED_TOKEN_CODE_HASH =
        0xaedd7bd1543d57afaeb94f6b46e28ba4c1ef7cdd2ad4affca011b17056036869;

    function run() external returns (SwaputerSRC20AuctionFactory auctionFactory) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address router = vm.envAddress("SVM_ROUTER_ADDRESS");
        bytes32 worldId = vm.envBytes32("SVM_WORLD_ID");
        vm.startBroadcast(deployerKey);
        auctionFactory = new SwaputerSRC20AuctionFactory(
            SwapVMRouter(payable(router)), worldId, ESCROW_CODE_HASH, TRUSTED_TOKEN_CODE_HASH
        );
        vm.stopBroadcast();

        console2.log("SRC20 auction factory", address(auctionFactory));
        console2.logBytes32(auctionFactory.worldId());
        console2.logBytes32(auctionFactory.escrowCodeHash());
        console2.logBytes32(auctionFactory.trustedTokenCodeHash());
    }
}
