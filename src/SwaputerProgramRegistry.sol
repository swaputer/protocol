// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Immutable registry of the canonical SwapVM v1 reference packages.
/// @dev Recognition requires the interface ID, exact ABI hash and exact ProgramPackageV1 hash.
contract SwaputerProgramRegistry {
    bytes4 public constant SRC165_INTERFACE_ID = 0x01ffc9a7;

    bytes4 public constant SRC20_INTERFACE_ID = 0x2633673d;
    bytes32 public constant SRC20_ABI_HASH = 0xf286f500d4395f9fbb4b97ce7d1ac7840507066f2de7d595433dca18b4490067;
    bytes32 public constant SRC20_CODE_HASH = 0x8699a93b015eb99ed1e30d713f1183f710eb92d6bbdb92fd7086490e84fde792;

    bytes4 public constant SRC721_INTERFACE_ID = 0xfd386dba;
    bytes32 public constant SRC721_ABI_HASH = 0x123327446b41849e72eb3b41f073d20c3f12cf346af19f02d4aa6311a5285c00;
    bytes32 public constant SRC721_CODE_HASH = 0x473bc4130c5de9e9981bca274ea85f315c5e7f67aa6654f675ec3b49475c8aad;

    bytes4 public constant SRC1155_INTERFACE_ID = 0xb9544cff;
    bytes32 public constant SRC1155_ABI_HASH = 0x7daaf0b8583b5027779e7b2a4b8558b6b3bb0431fc7ff7c589f0a072ccd5e070;
    bytes32 public constant SRC1155_CODE_HASH = 0x258c71844de4694f71453b9aabe1344ce6f43061ffc61fdc85e5940af66404ed;

    bytes4 public constant CPAMM_INTERFACE_ID = 0x94baf55f;
    bytes32 public constant CPAMM_ABI_HASH = 0x867173fe3dcbf09ae1202bb62b8ec3913ef83cef075906344821673ec239807b;
    bytes32 public constant CPAMM_CODE_HASH = 0x2d5b233b9056011f5a1fbed8781b5c12963ba6bcbcf9a79cfcc0d1ebaf8a3e4b;

    function isVerified(bytes4 interfaceId, bytes32 abiHash, bytes32 codeHash) public pure returns (bool) {
        if (interfaceId == SRC20_INTERFACE_ID) return abiHash == SRC20_ABI_HASH && codeHash == SRC20_CODE_HASH;
        if (interfaceId == SRC721_INTERFACE_ID) return abiHash == SRC721_ABI_HASH && codeHash == SRC721_CODE_HASH;
        if (interfaceId == SRC1155_INTERFACE_ID) return abiHash == SRC1155_ABI_HASH && codeHash == SRC1155_CODE_HASH;
        if (interfaceId == CPAMM_INTERFACE_ID) return abiHash == CPAMM_ABI_HASH && codeHash == CPAMM_CODE_HASH;
        return false;
    }

    function verifyPackage(bytes4 interfaceId, bytes calldata packageBytes) external pure returns (bool) {
        if (packageBytes.length < 44) return false;
        bytes32 abiHash;
        assembly ("memory-safe") {
            abiHash := calldataload(add(packageBytes.offset, 12))
        }
        return isVerified(interfaceId, abiHash, keccak256(packageBytes));
    }
}
