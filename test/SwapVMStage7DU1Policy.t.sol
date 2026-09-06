// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Stage7A2DeployScript} from "../script/Stage7A2Deploy.s.sol";

contract SwapVMStage7DU1PolicyTest is Test {
    Stage7A2DeployScript internal deployment;

    function setUp() public {
        deployment = new Stage7A2DeployScript();
    }

    function test_releasePolicyAcceptsOnlyV12GasOptimizedUnauditedLocalOrTestnet() public view {
        deployment.validateReleasePolicy(
            "local", "unaudited", "swaputer-v1.2-gas-optimized", "9fe7b09427d43ae892224094dfdd0af291e71b06", 31337
        );
        deployment.validateReleasePolicy(
            "testnet", "unaudited", "swaputer-v1.2-gas-optimized", "9fe7b09427d43ae892224094dfdd0af291e71b06", 11155111
        );
    }

    function test_releasePolicyHasNoMainnetOrAuditBypass() public {
        _expectRejected(
            "mainnet", "unaudited", "swaputer-v1.2-gas-optimized", "9fe7b09427d43ae892224094dfdd0af291e71b06", 1
        );
        _expectRejected(
            "testnet", "unaudited", "swaputer-v1.2-gas-optimized", "9fe7b09427d43ae892224094dfdd0af291e71b06", 1
        );
        _expectRejected(
            "local", "unaudited", "swaputer-v1.2-gas-optimized", "9fe7b09427d43ae892224094dfdd0af291e71b06", 31338
        );
        _expectRejected(
            "testnet", "audited", "swaputer-v1.2-gas-optimized", "9fe7b09427d43ae892224094dfdd0af291e71b06", 11155111
        );
        _expectRejected("testnet", "unaudited", "moved-tag", "9fe7b09427d43ae892224094dfdd0af291e71b06", 11155111);
        _expectRejected(
            "testnet", "unaudited", "swaputer-v1.2-gas-optimized", "0000000000000000000000000000000000000000", 11155111
        );
    }

    function _expectRejected(
        string memory environment,
        string memory status,
        string memory tag,
        string memory commit,
        uint256 chainId
    ) private {
        vm.expectPartialRevert(Stage7A2DeployScript.ReleasePolicyViolation.selector);
        deployment.validateReleasePolicy(environment, status, tag, commit, chainId);
    }
}
