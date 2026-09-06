// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Immutable bytecode container used only to supply release-pinned contract creation code.
/// @dev Runtime is STOP || payload. The leading STOP makes accidental calls inert.
contract SwapVMCreationCodeStore {
    error EmptyCreationCode();

    constructor(bytes memory creationCode) {
        if (creationCode.length == 0) revert EmptyCreationCode();
        bytes memory runtime = abi.encodePacked(bytes1(0x00), creationCode);
        assembly ("memory-safe") {
            return(add(runtime, 0x20), mload(runtime))
        }
    }
}

library SwapVMCreationCodeReader {
    error InvalidCreationCodeStore(address store);

    function read(address store) internal view returns (bytes memory creationCode) {
        uint256 size = store.code.length;
        if (size <= 1) revert InvalidCreationCodeStore(store);
        creationCode = new bytes(size - 1);
        assembly ("memory-safe") {
            extcodecopy(store, add(creationCode, 0x20), 1, sub(size, 1))
        }
    }
}
