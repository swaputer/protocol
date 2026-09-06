// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @dev Exports independent flattened expectations from the real Kernel Events for Stage-6A golden fixtures.
library ReceiptFixture {
    bytes32 internal constant EVENTS_TOPIC = keccak256("Events(bytes32,uint64,bytes)");

    struct Expanded {
        uint256[] recordLengths;
        bytes32[] emitters;
        uint256[] topicCounts;
        bytes[] topicsPacked;
        uint256[] dataLengths;
        bytes[] data;
        string[] order;
    }

    function assertOrWrite(Vm vm, string memory scenario, address kernel, Vm.Log[] memory logs) public {
        (bytes32 worldId, uint256 executionHeight, bytes memory payload) = _find(kernel, logs);
        uint256 recordCount = _u16(payload, 2);
        Expanded memory expanded = _expand(vm, payload, recordCount);
        string memory generated = _serialize(vm, scenario, worldId, executionHeight, payload, expanded);
        string memory path = string.concat("tooling/receipt-codec/fixtures/raw/", scenario, ".json");
        if (vm.envOr("SWAPVM_WRITE_RECEIPT_FIXTURES", false)) {
            vm.writeFile(path, generated);
        } else {
            string memory committed = vm.readFile(path);
            require(keccak256(bytes(committed)) == keccak256(bytes(generated)), "Stage6AFixtureDrift");
        }
    }

    function _find(address kernel, Vm.Log[] memory logs)
        private
        pure
        returns (bytes32 worldId, uint256 executionHeight, bytes memory payload)
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == kernel && logs[i].topics.length == 3 && logs[i].topics[0] == EVENTS_TOPIC) {
                worldId = logs[i].topics[1];
                executionHeight = uint256(logs[i].topics[2]);
                payload = abi.decode(logs[i].data, (bytes));
                ++count;
            }
        }
        require(count == 1, "Stage6AExpectedOneEvents");
    }

    function _expand(Vm vm, bytes memory payload, uint256 recordCount) private pure returns (Expanded memory expanded) {
        require(payload.length >= 4, "Stage6ATruncatedHeader");
        expanded.recordLengths = new uint256[](recordCount);
        expanded.emitters = new bytes32[](recordCount);
        expanded.topicCounts = new uint256[](recordCount);
        expanded.topicsPacked = new bytes[](recordCount);
        expanded.dataLengths = new uint256[](recordCount);
        expanded.data = new bytes[](recordCount);
        expanded.order = new string[](recordCount);
        uint256 offset = 4;
        for (uint256 index; index < recordCount; ++index) {
            uint256 recordLength = _u32(payload, offset);
            uint256 bodyStart = offset + 4;
            bytes32 emitter = _word(payload, bodyStart);
            uint256 topicCount = uint8(payload[bodyStart + 32]);
            uint256 topicsStart = bodyStart + 33;
            uint256 dataLengthOffset = topicsStart + 32 * topicCount;
            uint256 dataLength = _u32(payload, dataLengthOffset);
            uint256 dataStart = dataLengthOffset + 4;
            require(recordLength == 32 + 1 + 32 * topicCount + 4 + dataLength, "Stage6ARecordLength");
            require(dataStart + dataLength == bodyStart + recordLength, "Stage6ARecordBoundary");
            require(dataStart + dataLength <= payload.length, "Stage6ARecordTruncated");

            expanded.recordLengths[index] = recordLength;
            expanded.emitters[index] = emitter;
            expanded.topicCounts[index] = topicCount;
            expanded.topicsPacked[index] = _slice(payload, topicsStart, topicCount * 32);
            expanded.dataLengths[index] = dataLength;
            expanded.data[index] = _slice(payload, dataStart, dataLength);
            bytes32 topic0 = topicCount == 0 ? bytes32(0) : _word(payload, topicsStart);
            expanded.order[index] = string.concat(vm.toString(emitter), ":", vm.toString(topic0));
            offset = dataStart + dataLength;
        }
        require(offset == payload.length, "Stage6ATrailingBytes");
    }

    function _serialize(
        Vm vm,
        string memory scenario,
        bytes32 worldId,
        uint256 executionHeight,
        bytes memory payload,
        Expanded memory expanded
    ) private returns (string memory json) {
        string memory key = string.concat("stage6a-", scenario);
        vm.serializeString(key, "scenario", scenario);
        vm.serializeBytes32(key, "worldId", worldId);
        vm.serializeUint(key, "executionHeight", executionHeight);
        vm.serializeBytes(key, "payload", payload);
        vm.serializeUint(key, "recordCount", expanded.recordLengths.length);
        vm.serializeUint(key, "recordLengths", expanded.recordLengths);
        vm.serializeBytes32(key, "emitters", expanded.emitters);
        vm.serializeUint(key, "topicCounts", expanded.topicCounts);
        vm.serializeBytes(key, "topicsPacked", expanded.topicsPacked);
        vm.serializeUint(key, "dataLengths", expanded.dataLengths);
        vm.serializeBytes(key, "data", expanded.data);
        json = vm.serializeString(key, "expectedRecordOrder", expanded.order);
    }

    function _slice(bytes memory source, uint256 start, uint256 length) private pure returns (bytes memory result) {
        result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = source[start + i];
        }
    }

    function _u16(bytes memory data, uint256 offset) private pure returns (uint16 value) {
        value = (uint16(uint8(data[offset])) << 8) | uint16(uint8(data[offset + 1]));
    }

    function _u32(bytes memory data, uint256 offset) private pure returns (uint32 value) {
        value = (uint32(uint8(data[offset])) << 24) | (uint32(uint8(data[offset + 1])) << 16)
            | (uint32(uint8(data[offset + 2])) << 8) | uint32(uint8(data[offset + 3]));
    }

    function _word(bytes memory data, uint256 offset) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }
}
