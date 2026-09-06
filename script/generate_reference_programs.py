#!/usr/bin/env python3
"""Generate the canonical SwapVM v1 SRC and constant-product AMM reference packages."""

import json
from pathlib import Path
from typing import Optional

from Crypto.Hash import keccak


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "reference"


def k256(data: bytes) -> bytes:
    digest = keccak.new(digest_bits=256)
    digest.update(data)
    return digest.digest()


def selector(signature: str) -> int:
    return int.from_bytes(k256(signature.encode())[:4], "big")


class Assembler:
    def __init__(self):
        self.code = bytearray()
        self.labels = {}
        self.fixups = []

    def op(self, value: int):
        self.code.append(value)

    def raw(self, value: bytes):
        self.code.extend(value)

    def push(self, value: int, size: Optional[int] = None):
        if value == 0 and size is None:
            self.op(0x5F)
            return
        if size is None:
            size = max(1, (value.bit_length() + 7) // 8)
        if not 1 <= size <= 32 or value >= 1 << (8 * size):
            raise ValueError((value, size))
        self.op(0x5F + size)
        self.raw(value.to_bytes(size, "big"))

    def push_label(self, name: str):
        self.op(0x61)
        self.fixups.append((len(self.code), name))
        self.raw(b"\x00\x00")

    def label(self, name: str):
        if name in self.labels:
            raise ValueError(f"duplicate label: {name}")
        self.labels[name] = len(self.code)
        self.op(0x5B)

    def jump(self, name: str):
        self.push_label(name)
        self.op(0x56)

    def jumpi(self, name: str):
        self.push_label(name)
        self.op(0x57)

    def finish(self) -> bytes:
        for position, name in self.fixups:
            target = self.labels[name]
            self.code[position : position + 2] = target.to_bytes(2, "big")
        return bytes(self.code)


def calldata(a: Assembler, offset: int):
    a.push(offset)
    a.op(0x35)


def mload(a: Assembler, offset: int):
    a.push(offset)
    a.op(0x51)


def mstore(a: Assembler, offset: int):
    a.push(offset)
    a.op(0x52)


def sload(a: Assembler, slot: int):
    a.push(slot)
    a.op(0x54)


def sstore(a: Assembler, slot: int):
    a.push(slot)
    a.op(0x55)


def hash_slot(a: Assembler, namespace: int, key_offsets: list[int]):
    a.push(namespace)
    mstore(a, 0x100)
    for index, offset in enumerate(key_offsets):
        mload(a, offset)
        mstore(a, 0x120 + 32 * index)
    a.push(32 * (1 + len(key_offsets)))
    a.push(0x100)
    a.op(0x20)


def mapping_load(a: Assembler, namespace: int, key_offsets: list[int]):
    hash_slot(a, namespace, key_offsets)
    a.op(0x54)


def mapping_store(a: Assembler, namespace: int, key_offsets: list[int]):
    hash_slot(a, namespace, key_offsets)
    a.op(0x55)


def require_valid(a: Assembler, revert_label: str):
    a.op(0x15)
    a.jumpi(revert_label)


def return_word(a: Assembler):
    mstore(a, 0)
    a.push(32)
    a.push(0)
    a.op(0xF3)


def return_true(a: Assembler):
    a.push(1)
    return_word(a)


def emit(a: Assembler, topic_values, data_offset: int, data_size: int):
    a.push(data_size)
    a.push(data_offset)
    for kind, value in topic_values:
        if kind == "constant":
            a.push(value, 32)
        elif kind == "memory":
            mload(a, value)
        elif kind == "caller":
            a.op(0x33)
        else:
            raise ValueError(kind)
    a.op(0xA0 + len(topic_values))


def begin_runtime(a: Assembler, methods: dict[str, str]) -> int:
    runtime_entry = len(a.code)
    a.label("runtime")
    calldata(a, 0)
    a.push(224)
    a.op(0x1C)
    for signature, label in methods.items():
        a.op(0x80)
        a.push(selector(signature), 4)
        a.op(0x14)
        a.jumpi(label)
    a.jump("revert")
    return runtime_entry


def handler(a: Assembler, name: str):
    a.label(name)
    a.op(0x50)


def supports_interface(a: Assembler, interface_ids: list[int]):
    calldata(a, 4)
    a.push(224)
    a.op(0x1C)
    a.push(interface_ids[0], 4)
    a.op(0x14)
    for interface_id in interface_ids[1:]:
        calldata(a, 4)
        a.push(224)
        a.op(0x1C)
        a.push(interface_id, 4)
        a.op(0x14)
        a.op(0x17)
    return_word(a)


def dispatch_revert(a: Assembler):
    a.label("revert")
    a.push(0)
    a.push(0)
    a.op(0xFD)


SRC165_SIG = "supportsInterface(bytes4)"
SRC165_ID = selector(SRC165_SIG)


def interface_id(signatures: list[str]) -> int:
    result = 0
    for signature in signatures:
        result ^= selector(signature)
    return result


def build_src20():
    functions = [
        "name()",
        "symbol()",
        "decimals()",
        "totalSupply()",
        "balanceOf(bytes32)",
        "allowance(bytes32,bytes32)",
        "transfer(bytes32,uint256)",
        "approve(bytes32,uint256)",
        "transferFrom(bytes32,bytes32,uint256)",
    ]
    src_id = interface_id(functions)
    transfer_topic = int.from_bytes(k256(b"Transfer(bytes32,bytes32,uint256)"), "big")
    approval_topic = int.from_bytes(k256(b"Approval(bytes32,bytes32,uint256)"), "big")
    a = Assembler()

    for offset, slot in ((0, 0), (32, 1), (64, 2), (96, 3)):
        calldata(a, offset)
        sstore(a, slot)
    calldata(a, 128)
    mstore(a, 0)
    calldata(a, 96)
    mstore(a, 32)
    mload(a, 0)
    require_valid(a, "revert")
    mload(a, 32)
    hash_slot(a, 0x20, [0])
    a.op(0x55)
    mload(a, 32)
    mstore(a, 64)
    emit(
        a,
        [("constant", transfer_topic), ("constant", 0), ("memory", 0)],
        64,
        32,
    )
    a.op(0x00)

    methods = {SRC165_SIG: "supports", **{signature: f"fn_{index}" for index, signature in enumerate(functions)}}
    runtime_entry = begin_runtime(a, methods)

    handler(a, "supports")
    supports_interface(a, [SRC165_ID, src_id])

    for index, slot in enumerate((0, 1, 2, 3)):
        handler(a, f"fn_{index}")
        sload(a, slot)
        return_word(a)

    handler(a, "fn_4")
    calldata(a, 4)
    mstore(a, 0)
    mapping_load(a, 0x20, [0])
    return_word(a)

    handler(a, "fn_5")
    calldata(a, 4)
    mstore(a, 0)
    calldata(a, 36)
    mstore(a, 32)
    mapping_load(a, 0x21, [0, 32])
    return_word(a)

    handler(a, "fn_6")
    calldata(a, 4)
    mstore(a, 0)
    calldata(a, 36)
    mstore(a, 32)
    a.op(0x33)
    mstore(a, 64)
    mload(a, 0)
    require_valid(a, "revert")
    mapping_load(a, 0x20, [64])
    mstore(a, 96)
    mload(a, 96)
    mload(a, 32)
    a.op(0x10)
    a.jumpi("revert")
    mload(a, 96)
    mload(a, 32)
    a.op(0x03)
    mapping_store(a, 0x20, [64])
    mapping_load(a, 0x20, [0])
    mload(a, 32)
    a.op(0x01)
    mapping_store(a, 0x20, [0])
    mload(a, 32)
    mstore(a, 128)
    emit(a, [("constant", transfer_topic), ("memory", 64), ("memory", 0)], 128, 32)
    return_true(a)

    handler(a, "fn_7")
    calldata(a, 4)
    mstore(a, 0)
    calldata(a, 36)
    mstore(a, 32)
    a.op(0x33)
    mstore(a, 64)
    mload(a, 0)
    require_valid(a, "revert")
    mload(a, 32)
    mapping_store(a, 0x21, [64, 0])
    mload(a, 32)
    mstore(a, 128)
    emit(a, [("constant", approval_topic), ("memory", 64), ("memory", 0)], 128, 32)
    return_true(a)

    handler(a, "fn_8")
    for offset, memory_offset in ((4, 0), (36, 32), (68, 64)):
        calldata(a, offset)
        mstore(a, memory_offset)
    a.op(0x33)
    mstore(a, 96)
    mload(a, 32)
    require_valid(a, "revert")
    mapping_load(a, 0x20, [0])
    mstore(a, 128)
    mload(a, 128)
    mload(a, 64)
    a.op(0x10)
    a.jumpi("revert")
    mload(a, 96)
    mload(a, 0)
    a.op(0x14)
    a.jumpi("src20_allowance_done")
    mapping_load(a, 0x21, [0, 96])
    mstore(a, 160)
    mload(a, 160)
    mload(a, 64)
    a.op(0x10)
    a.jumpi("revert")
    mload(a, 160)
    mload(a, 64)
    a.op(0x03)
    mapping_store(a, 0x21, [0, 96])
    a.label("src20_allowance_done")
    mload(a, 128)
    mload(a, 64)
    a.op(0x03)
    mapping_store(a, 0x20, [0])
    mapping_load(a, 0x20, [32])
    mload(a, 64)
    a.op(0x01)
    mapping_store(a, 0x20, [32])
    mload(a, 64)
    mstore(a, 192)
    emit(a, [("constant", transfer_topic), ("memory", 0), ("memory", 32)], 192, 32)
    return_true(a)
    dispatch_revert(a)

    abi = {
        "standard": "SRC-20",
        "version": 1,
        "accountType": "bytes32-tagged-AccountId",
        "constructor": "constructor(bytes32,bytes32,uint256,uint256,bytes32)",
        "functions": [SRC165_SIG, *functions],
        "events": ["Transfer(bytes32,bytes32,uint256)", "Approval(bytes32,bytes32,uint256)"],
        "returns": {"name()": "bytes32", "symbol()": "bytes32", "decimals()": "uint256"},
    }
    return a.finish(), runtime_entry, abi, src_id


def build_src721():
    functions = [
        "name()",
        "symbol()",
        "ownerOf(uint256)",
        "balanceOf(bytes32)",
        "approve(bytes32,uint256)",
        "setApprovalForAll(bytes32,bool)",
        "transferFrom(bytes32,bytes32,uint256)",
        "tokenURI(uint256)",
    ]
    src_id = interface_id(functions)
    transfer_topic = int.from_bytes(k256(b"Transfer(bytes32,bytes32,uint256)"), "big")
    approval_topic = int.from_bytes(k256(b"Approval(bytes32,bytes32,uint256)"), "big")
    all_topic = int.from_bytes(k256(b"ApprovalForAll(bytes32,bytes32,bool)"), "big")
    a = Assembler()
    calldata(a, 0)
    sstore(a, 0)
    calldata(a, 32)
    sstore(a, 1)
    for source, target in ((64, 0), (96, 32), (128, 64)):
        calldata(a, source)
        mstore(a, target)
    mload(a, 32)
    require_valid(a, "revert")
    mload(a, 32)
    mapping_store(a, 0x30, [0])
    a.push(1)
    mapping_store(a, 0x31, [32])
    mload(a, 64)
    mapping_store(a, 0x34, [0])
    mload(a, 0)
    mstore(a, 96)
    emit(a, [("constant", transfer_topic), ("constant", 0), ("memory", 32)], 96, 32)
    a.op(0x00)

    methods = {SRC165_SIG: "supports", **{signature: f"fn_{index}" for index, signature in enumerate(functions)}}
    runtime_entry = begin_runtime(a, methods)
    handler(a, "supports")
    supports_interface(a, [SRC165_ID, src_id])
    for index, slot in ((0, 0), (1, 1)):
        handler(a, f"fn_{index}")
        sload(a, slot)
        return_word(a)
    handler(a, "fn_2")
    calldata(a, 4)
    mstore(a, 0)
    mapping_load(a, 0x30, [0])
    a.op(0x80)
    require_valid(a, "revert")
    return_word(a)
    handler(a, "fn_3")
    calldata(a, 4)
    mstore(a, 0)
    mapping_load(a, 0x31, [0])
    return_word(a)

    handler(a, "fn_4")
    calldata(a, 4)
    mstore(a, 0)
    calldata(a, 36)
    mstore(a, 32)
    a.op(0x33)
    mstore(a, 64)
    mapping_load(a, 0x30, [32])
    mstore(a, 96)
    mload(a, 64)
    mload(a, 96)
    a.op(0x14)
    mapping_load(a, 0x33, [96, 64])
    a.op(0x17)
    require_valid(a, "revert")
    mload(a, 0)
    mapping_store(a, 0x32, [32])
    mload(a, 32)
    mstore(a, 128)
    emit(a, [("constant", approval_topic), ("memory", 96), ("memory", 0)], 128, 32)
    return_true(a)

    handler(a, "fn_5")
    calldata(a, 4)
    mstore(a, 0)
    calldata(a, 36)
    mstore(a, 32)
    a.op(0x33)
    mstore(a, 64)
    mload(a, 0)
    require_valid(a, "revert")
    mload(a, 32)
    mapping_store(a, 0x33, [64, 0])
    mload(a, 32)
    mstore(a, 96)
    emit(a, [("constant", all_topic), ("memory", 64), ("memory", 0)], 96, 32)
    return_true(a)

    handler(a, "fn_6")
    for offset, memory_offset in ((4, 0), (36, 32), (68, 64)):
        calldata(a, offset)
        mstore(a, memory_offset)
    a.op(0x33)
    mstore(a, 96)
    mload(a, 32)
    require_valid(a, "revert")
    mapping_load(a, 0x30, [64])
    mload(a, 0)
    a.op(0x14)
    require_valid(a, "revert")
    mload(a, 96)
    mload(a, 0)
    a.op(0x14)
    mapping_load(a, 0x32, [64])
    mload(a, 96)
    a.op(0x14)
    a.op(0x17)
    mapping_load(a, 0x33, [0, 96])
    a.op(0x17)
    require_valid(a, "revert")
    mload(a, 32)
    mapping_store(a, 0x30, [64])
    mapping_load(a, 0x31, [0])
    a.push(1)
    a.op(0x03)
    mapping_store(a, 0x31, [0])
    mapping_load(a, 0x31, [32])
    a.push(1)
    a.op(0x01)
    mapping_store(a, 0x31, [32])
    a.push(0)
    mapping_store(a, 0x32, [64])
    mload(a, 64)
    mstore(a, 128)
    emit(a, [("constant", transfer_topic), ("memory", 0), ("memory", 32)], 128, 32)
    return_true(a)

    handler(a, "fn_7")
    calldata(a, 4)
    mstore(a, 0)
    mapping_load(a, 0x34, [0])
    return_word(a)
    dispatch_revert(a)
    abi = {
        "standard": "SRC-721",
        "version": 1,
        "accountType": "bytes32-tagged-AccountId",
        "constructor": "constructor(bytes32,bytes32,uint256,bytes32,bytes32)",
        "functions": [SRC165_SIG, *functions],
        "events": [
            "Transfer(bytes32,bytes32,uint256)",
            "Approval(bytes32,bytes32,uint256)",
            "ApprovalForAll(bytes32,bytes32,bool)",
        ],
        "returns": {"name()": "bytes32", "symbol()": "bytes32", "tokenURI(uint256)": "bytes32"},
    }
    return a.finish(), runtime_entry, abi, src_id


def build_src1155():
    functions = [
        "balanceOf(bytes32,uint256)",
        "isApprovedForAll(bytes32,bytes32)",
        "setApprovalForAll(bytes32,bool)",
        "safeTransferFrom(bytes32,bytes32,uint256,uint256)",
        "uri(uint256)",
    ]
    src_id = interface_id(functions)
    single_topic = int.from_bytes(k256(b"TransferSingle(bytes32,bytes32,bytes32,uint256,uint256)"), "big")
    all_topic = int.from_bytes(k256(b"ApprovalForAll(bytes32,bytes32,bool)"), "big")
    a = Assembler()
    calldata(a, 0)
    sstore(a, 0)
    for source, target in ((32, 0), (64, 32), (96, 64)):
        calldata(a, source)
        mstore(a, target)
    mload(a, 64)
    require_valid(a, "revert")
    mload(a, 32)
    mapping_store(a, 0x40, [64, 0])
    mload(a, 0)
    mstore(a, 96)
    mload(a, 32)
    mstore(a, 128)
    emit(
        a,
        [("constant", single_topic), ("caller", 0), ("constant", 0), ("memory", 64)],
        96,
        64,
    )
    a.op(0x00)

    methods = {SRC165_SIG: "supports", **{signature: f"fn_{index}" for index, signature in enumerate(functions)}}
    runtime_entry = begin_runtime(a, methods)
    handler(a, "supports")
    supports_interface(a, [SRC165_ID, src_id])
    handler(a, "fn_0")
    calldata(a, 4)
    mstore(a, 0)
    calldata(a, 36)
    mstore(a, 32)
    mapping_load(a, 0x40, [0, 32])
    return_word(a)
    handler(a, "fn_1")
    calldata(a, 4)
    mstore(a, 0)
    calldata(a, 36)
    mstore(a, 32)
    mapping_load(a, 0x41, [0, 32])
    return_word(a)
    handler(a, "fn_2")
    calldata(a, 4)
    mstore(a, 0)
    calldata(a, 36)
    mstore(a, 32)
    a.op(0x33)
    mstore(a, 64)
    mload(a, 0)
    require_valid(a, "revert")
    mload(a, 32)
    mapping_store(a, 0x41, [64, 0])
    mload(a, 32)
    mstore(a, 96)
    emit(a, [("constant", all_topic), ("memory", 64), ("memory", 0)], 96, 32)
    return_true(a)
    handler(a, "fn_3")
    for offset, memory_offset in ((4, 0), (36, 32), (68, 64), (100, 96)):
        calldata(a, offset)
        mstore(a, memory_offset)
    a.op(0x33)
    mstore(a, 128)
    mload(a, 32)
    require_valid(a, "revert")
    mload(a, 128)
    mload(a, 0)
    a.op(0x14)
    mapping_load(a, 0x41, [0, 128])
    a.op(0x17)
    require_valid(a, "revert")
    mapping_load(a, 0x40, [0, 64])
    mstore(a, 160)
    mload(a, 160)
    mload(a, 96)
    a.op(0x10)
    a.jumpi("revert")
    mload(a, 160)
    mload(a, 96)
    a.op(0x03)
    mapping_store(a, 0x40, [0, 64])
    mapping_load(a, 0x40, [32, 64])
    mload(a, 96)
    a.op(0x01)
    mapping_store(a, 0x40, [32, 64])
    mload(a, 64)
    mstore(a, 192)
    mload(a, 96)
    mstore(a, 224)
    emit(
        a,
        [("constant", single_topic), ("memory", 128), ("memory", 0), ("memory", 32)],
        192,
        64,
    )
    return_true(a)
    handler(a, "fn_4")
    sload(a, 0)
    return_word(a)
    dispatch_revert(a)
    abi = {
        "standard": "SRC-1155",
        "version": 1,
        "accountType": "bytes32-tagged-AccountId",
        "constructor": "constructor(bytes32,uint256,uint256,bytes32)",
        "functions": [SRC165_SIG, *functions],
        "events": [
            "TransferSingle(bytes32,bytes32,bytes32,uint256,uint256)",
            "ApprovalForAll(bytes32,bytes32,bool)",
        ],
        "returns": {"uri(uint256)": "bytes32"},
        "note": "The v1 reference is intentionally single-transfer; batch extensions use a distinct ABI hash.",
    }
    return a.finish(), runtime_entry, abi, src_id


def call_contract(a: Assembler, target_kind: str, target: int, signature: str, argument_offsets: list[int]):
    call_base = 0x400
    output_base = 0x500
    a.push(selector(signature) << 224, 32)
    mstore(a, call_base)
    for index, offset in enumerate(argument_offsets):
        mload(a, offset)
        mstore(a, call_base + 4 + 32 * index)
    if target_kind == "storage":
        sload(a, target)
    elif target_kind == "memory":
        mload(a, target)
    else:
        raise ValueError(target_kind)
    a.push(4 + 32 * len(argument_offsets))
    a.push(call_base)
    a.push(32)
    a.push(output_base)
    a.op(0xF1)
    a.op(0x50)
    mload(a, output_base)
    require_valid(a, "revert")


def require_u128(a: Assembler, memory_offset: int):
    mload(a, memory_offset)
    a.push((1 << 128) - 1, 16)
    a.op(0x11)
    a.jumpi("revert")


def build_amm():
    functions = [
        "createPair(bytes32,bytes32,uint256)",
        "addLiquidity(uint256,uint256,uint256)",
        "removeLiquidity(uint256,uint256,uint256)",
        "swapExactIn(bytes32,uint256,uint256)",
        "getReserves()",
        "totalShares()",
        "sharesOf(bytes32)",
    ]
    amm_id = interface_id(functions)
    pair_topic = int.from_bytes(k256(b"PairCreated(bytes32,bytes32,uint256)"), "big")
    add_topic = int.from_bytes(k256(b"LiquidityAdded(bytes32,uint256,uint256,uint256)"), "big")
    remove_topic = int.from_bytes(k256(b"LiquidityRemoved(bytes32,uint256,uint256,uint256)"), "big")
    swap_topic = int.from_bytes(k256(b"Swap(bytes32,bytes32,uint256,uint256)"), "big")
    a = Assembler()
    a.op(0x00)
    methods = {SRC165_SIG: "supports", **{signature: f"fn_{index}" for index, signature in enumerate(functions)}}
    runtime_entry = begin_runtime(a, methods)
    handler(a, "supports")
    supports_interface(a, [SRC165_ID, amm_id])

    handler(a, "fn_0")
    sload(a, 6)
    a.op(0x15)
    require_valid(a, "revert")
    for source, target in ((4, 0), (36, 32), (68, 64)):
        calldata(a, source)
        mstore(a, target)
    mload(a, 0)
    require_valid(a, "revert")
    mload(a, 32)
    require_valid(a, "revert")
    mload(a, 0)
    mload(a, 32)
    a.op(0x14)
    a.op(0x15)
    require_valid(a, "revert")
    mload(a, 64)
    a.push(1_000_000)
    a.op(0x10)
    require_valid(a, "revert")
    mload(a, 0)
    sstore(a, 0)
    mload(a, 32)
    sstore(a, 1)
    mload(a, 64)
    sstore(a, 2)
    a.push(1)
    sstore(a, 6)
    mload(a, 64)
    mstore(a, 96)
    emit(a, [("constant", pair_topic), ("memory", 0), ("memory", 32)], 96, 32)
    return_true(a)

    handler(a, "fn_1")
    sload(a, 6)
    require_valid(a, "revert")
    for source, target in ((4, 0), (36, 32), (68, 64)):
        calldata(a, source)
        mstore(a, target)
    a.op(0x33)
    mstore(a, 96)
    require_u128(a, 0)
    require_u128(a, 32)
    mload(a, 0)
    require_valid(a, "revert")
    mload(a, 32)
    require_valid(a, "revert")
    sload(a, 5)
    mstore(a, 128)
    sload(a, 3)
    mstore(a, 160)
    sload(a, 4)
    mstore(a, 192)
    mload(a, 128)
    a.op(0x15)
    a.jumpi("amm_initial_liquidity")
    mload(a, 0)
    mload(a, 128)
    a.op(0x02)
    mload(a, 160)
    a.op(0x04)
    mstore(a, 224)
    mload(a, 32)
    mload(a, 128)
    a.op(0x02)
    mload(a, 192)
    a.op(0x04)
    mstore(a, 256)
    mload(a, 224)
    mload(a, 256)
    a.op(0x10)
    a.jumpi("amm_use_share0")
    mload(a, 256)
    mstore(a, 224)
    a.jump("amm_shares_ready")
    a.label("amm_use_share0")
    a.jump("amm_shares_ready")
    a.label("amm_initial_liquidity")
    mload(a, 0)
    mload(a, 32)
    a.op(0x10)
    a.jumpi("amm_initial_use0")
    mload(a, 32)
    mstore(a, 224)
    a.jump("amm_shares_ready")
    a.label("amm_initial_use0")
    mload(a, 0)
    mstore(a, 224)
    a.label("amm_shares_ready")
    mload(a, 224)
    require_valid(a, "revert")
    require_u128(a, 224)
    mload(a, 224)
    mload(a, 64)
    a.op(0x10)
    a.jumpi("revert")
    a.op(0x30)
    mstore(a, 288)
    call_contract(a, "storage", 0, "transferFrom(bytes32,bytes32,uint256)", [96, 288, 0])
    call_contract(a, "storage", 1, "transferFrom(bytes32,bytes32,uint256)", [96, 288, 32])
    mload(a, 160)
    mload(a, 0)
    a.op(0x01)
    mstore(a, 160)
    require_u128(a, 160)
    mload(a, 160)
    sstore(a, 3)
    mload(a, 192)
    mload(a, 32)
    a.op(0x01)
    mstore(a, 192)
    require_u128(a, 192)
    mload(a, 192)
    sstore(a, 4)
    mload(a, 128)
    mload(a, 224)
    a.op(0x01)
    mstore(a, 128)
    require_u128(a, 128)
    mload(a, 128)
    sstore(a, 5)
    mapping_load(a, 0x50, [96])
    mload(a, 224)
    a.op(0x01)
    mapping_store(a, 0x50, [96])
    mload(a, 0)
    mstore(a, 320)
    mload(a, 32)
    mstore(a, 352)
    mload(a, 224)
    mstore(a, 384)
    emit(a, [("constant", add_topic), ("memory", 96)], 320, 96)
    mload(a, 224)
    return_word(a)

    handler(a, "fn_2")
    sload(a, 6)
    require_valid(a, "revert")
    for source, target in ((4, 0), (36, 32), (68, 64)):
        calldata(a, source)
        mstore(a, target)
    a.op(0x33)
    mstore(a, 96)
    require_u128(a, 0)
    mload(a, 0)
    require_valid(a, "revert")
    sload(a, 5)
    mstore(a, 128)
    sload(a, 3)
    mstore(a, 160)
    sload(a, 4)
    mstore(a, 192)
    mapping_load(a, 0x50, [96])
    mstore(a, 224)
    mload(a, 224)
    mload(a, 0)
    a.op(0x10)
    a.jumpi("revert")
    mload(a, 0)
    mload(a, 160)
    a.op(0x02)
    mload(a, 128)
    a.op(0x04)
    mstore(a, 512)
    mload(a, 0)
    mload(a, 192)
    a.op(0x02)
    mload(a, 128)
    a.op(0x04)
    mstore(a, 544)
    mload(a, 512)
    mload(a, 32)
    a.op(0x10)
    a.jumpi("revert")
    mload(a, 544)
    mload(a, 64)
    a.op(0x10)
    a.jumpi("revert")
    mload(a, 224)
    mload(a, 0)
    a.op(0x03)
    mapping_store(a, 0x50, [96])
    mload(a, 128)
    mload(a, 0)
    a.op(0x03)
    sstore(a, 5)
    mload(a, 160)
    mload(a, 512)
    a.op(0x03)
    sstore(a, 3)
    mload(a, 192)
    mload(a, 544)
    a.op(0x03)
    sstore(a, 4)
    call_contract(a, "storage", 0, "transfer(bytes32,uint256)", [96, 512])
    call_contract(a, "storage", 1, "transfer(bytes32,uint256)", [96, 544])
    mload(a, 0)
    mstore(a, 320)
    mload(a, 512)
    mstore(a, 352)
    mload(a, 544)
    mstore(a, 384)
    emit(a, [("constant", remove_topic), ("memory", 96)], 320, 96)
    mload(a, 512)
    mstore(a, 0)
    mload(a, 544)
    mstore(a, 32)
    a.push(64)
    a.push(0)
    a.op(0xF3)

    handler(a, "fn_3")
    sload(a, 6)
    require_valid(a, "revert")
    for source, target in ((4, 0), (36, 32), (68, 64)):
        calldata(a, source)
        mstore(a, target)
    a.op(0x33)
    mstore(a, 96)
    require_u128(a, 32)
    mload(a, 32)
    require_valid(a, "revert")
    sload(a, 3)
    mstore(a, 128)
    sload(a, 4)
    mstore(a, 160)
    mload(a, 0)
    sload(a, 0)
    a.op(0x14)
    a.jumpi("amm_swap_zero_for_one")
    mload(a, 0)
    sload(a, 1)
    a.op(0x14)
    require_valid(a, "revert")
    a.push(1)
    mstore(a, 192)
    mload(a, 160)
    mstore(a, 224)
    mload(a, 128)
    mstore(a, 256)
    a.jump("amm_swap_direction_ready")
    a.label("amm_swap_zero_for_one")
    a.push(0)
    mstore(a, 192)
    mload(a, 128)
    mstore(a, 224)
    mload(a, 160)
    mstore(a, 256)
    a.label("amm_swap_direction_ready")
    mload(a, 32)
    a.push(1_000_000)
    sload(a, 2)
    a.op(0x03)
    a.op(0x02)
    a.push(1_000_000)
    a.op(0x04)
    mstore(a, 288)
    mload(a, 256)
    mload(a, 288)
    a.op(0x02)
    mload(a, 224)
    mload(a, 288)
    a.op(0x01)
    a.op(0x04)
    mstore(a, 320)
    mload(a, 320)
    require_valid(a, "revert")
    mload(a, 320)
    mload(a, 64)
    a.op(0x10)
    a.jumpi("revert")
    a.op(0x30)
    mstore(a, 352)
    call_contract(a, "memory", 0, "transferFrom(bytes32,bytes32,uint256)", [96, 352, 32])
    mload(a, 192)
    a.jumpi("amm_swap_output_token0")
    call_contract(a, "storage", 1, "transfer(bytes32,uint256)", [96, 320])
    mload(a, 128)
    mload(a, 32)
    a.op(0x01)
    mstore(a, 128)
    require_u128(a, 128)
    mload(a, 128)
    sstore(a, 3)
    mload(a, 160)
    mload(a, 320)
    a.op(0x03)
    sstore(a, 4)
    a.jump("amm_swap_updated")
    a.label("amm_swap_output_token0")
    call_contract(a, "storage", 0, "transfer(bytes32,uint256)", [96, 320])
    mload(a, 160)
    mload(a, 32)
    a.op(0x01)
    mstore(a, 160)
    require_u128(a, 160)
    mload(a, 160)
    sstore(a, 4)
    mload(a, 128)
    mload(a, 320)
    a.op(0x03)
    sstore(a, 3)
    a.label("amm_swap_updated")
    mload(a, 32)
    mstore(a, 384)
    mload(a, 320)
    mstore(a, 416)
    emit(a, [("constant", swap_topic), ("memory", 96), ("memory", 0)], 384, 64)
    mload(a, 320)
    return_word(a)

    handler(a, "fn_4")
    sload(a, 3)
    mstore(a, 0)
    sload(a, 4)
    mstore(a, 32)
    a.push(64)
    a.push(0)
    a.op(0xF3)
    handler(a, "fn_5")
    sload(a, 5)
    return_word(a)
    handler(a, "fn_6")
    calldata(a, 4)
    mstore(a, 0)
    mapping_load(a, 0x50, [0])
    return_word(a)
    dispatch_revert(a)
    abi = {
        "standard": "SwapVM-CPAMM",
        "version": 1,
        "accountType": "bytes32-tagged-AccountId",
        "constructor": "constructor()",
        "functions": [SRC165_SIG, *functions],
        "events": [
            "PairCreated(bytes32,bytes32,uint256)",
            "LiquidityAdded(bytes32,uint256,uint256,uint256)",
            "LiquidityRemoved(bytes32,uint256,uint256,uint256)",
            "Swap(bytes32,bytes32,uint256,uint256)",
        ],
        "feeDenominator": 1_000_000,
        "amountCeiling": "uint128.max",
        "returns": {
            "addLiquidity(uint256,uint256,uint256)": "uint256",
            "removeLiquidity(uint256,uint256,uint256)": "(uint256,uint256)",
            "swapExactIn(bytes32,uint256,uint256)": "uint256",
            "getReserves()": "(uint256,uint256)",
        },
    }
    return a.finish(), runtime_entry, abi, amm_id


def write_reference(name: str, builder):
    code, runtime_entry, abi, src_id = builder()
    abi_canonical = json.dumps(abi, sort_keys=True, separators=(",", ":"))
    abi_hash = k256(abi_canonical.encode())
    package = (
        b"SVM1"
        + (1).to_bytes(2, "big")
        + (0).to_bytes(2, "big")
        + runtime_entry.to_bytes(2, "big")
        + len(code).to_bytes(2, "big")
        + abi_hash
        + code
    )
    selectors = {signature: f"0x{selector(signature):08x}" for signature in abi["functions"]}
    result = {
        "standard": abi["standard"],
        "version": 1,
        "interfaceId": f"0x{src_id:08x}",
        "src165InterfaceId": f"0x{SRC165_ID:08x}",
        "abiCanonical": abi_canonical,
        "abiHash": "0x" + abi_hash.hex(),
        "constructorEntry": 0,
        "runtimeEntry": runtime_entry,
        "codeLength": len(code),
        "code": "0x" + code.hex(),
        "package": "0x" + package.hex(),
        "codeHash": "0x" + k256(package).hex(),
        "selectors": selectors,
        "eventTopics": {signature: "0x" + k256(signature.encode()).hex() for signature in abi["events"]},
    }
    OUTPUT.mkdir(exist_ok=True)
    (OUTPUT / f"{name}.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(name, result["interfaceId"], result["abiHash"], result["codeHash"], len(code), runtime_entry)


def main():
    write_reference("SRC20-v1", build_src20)
    write_reference("SRC721-v1", build_src721)
    write_reference("SRC1155-v1", build_src1155)
    write_reference("CPAMM-v1", build_amm)


if __name__ == "__main__":
    main()
