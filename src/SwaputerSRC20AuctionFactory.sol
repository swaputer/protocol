// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwapVMKernel} from "./SwapVMKernel.sol";
import {SwapVMRouter} from "./SwapVMRouter.sol";
import {SwapVMSRC20AuctionHouse} from "./SwapVMSRC20AuctionHouse.sol";
import {SwapVMWorldFactory} from "./SwapVMWorldFactory.sol";

/// @notice Permissionless registry for one SRC20 auction house per token program.
contract SwaputerSRC20AuctionFactory {
    bytes4 public constant TOKEN_ACCOUNT_SELECTOR = bytes4(keccak256("tokenAccount()"));
    bytes4 public constant TRUSTED_AUCTION_SELECTOR = bytes4(keccak256("trustedAuction()"));

    SwapVMRouter public immutable router;
    SwapVMKernel public immutable kernel;
    bytes32 public immutable worldId;
    bytes32 public immutable escrowCodeHash;
    bytes32 public immutable trustedTokenCodeHash;

    uint256 public auctionHouseCount;
    mapping(bytes32 token => address auctionHouse) public auctionHouseFor;
    mapping(uint256 index => bytes32 token) public tokenAt;

    error ZeroAddress();
    error InvalidWorld();
    error InvalidRouter();
    error InvalidToken();
    error InvalidEscrow();
    error AuctionHouseExists(bytes32 token, address auctionHouse);
    error EscrowBindingMismatch(
        bytes32 expectedToken, bytes32 actualToken, address expectedAuction, address actualAuction
    );
    error PredictionMismatch(address expected, address actual);
    error UntrustedTokenCodeHash(bytes32 expected, bytes32 actual);

    event AuctionHouseCreated(
        bytes32 indexed token,
        address indexed auctionHouse,
        bytes32 indexed escrow,
        bytes32 tokenCodeHash,
        uint256 auctionHouseIndex
    );

    constructor(
        SwapVMRouter boundRouter,
        bytes32 boundWorldId,
        bytes32 canonicalEscrowCodeHash,
        bytes32 trustedTokenCodeHash_
    ) {
        if (address(boundRouter) == address(0)) revert ZeroAddress();
        if (boundWorldId == bytes32(0)) revert InvalidWorld();
        if (canonicalEscrowCodeHash == bytes32(0)) revert InvalidEscrow();
        if (trustedTokenCodeHash_ == bytes32(0)) revert InvalidToken();
        SwapVMWorldFactory boundFactory = SwapVMWorldFactory(address(boundRouter.factory()));
        if (boundFactory.router() != address(boundRouter)) revert InvalidRouter();
        SwapVMWorldFactory.WorldConfig memory config = boundFactory.getWorldConfig(boundWorldId);
        if (!config.isSealed || config.kernel == address(0)) revert InvalidWorld();
        router = boundRouter;
        kernel = SwapVMKernel(config.kernel);
        worldId = boundWorldId;
        escrowCodeHash = canonicalEscrowCodeHash;
        trustedTokenCodeHash = trustedTokenCodeHash_;
    }

    function predictAuctionHouse(bytes32 token, bytes32 tokenCodeHash, bytes32 escrow)
        public
        view
        returns (address predicted)
    {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(SwapVMSRC20AuctionHouse).creationCode,
                abi.encode(router, worldId, token, tokenCodeHash, escrow, escrowCodeHash)
            )
        );
        predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(token), initCodeHash))))
        );
    }

    function createAuctionHouse(bytes32 token, bytes32 tokenCodeHash, bytes32 escrow)
        external
        returns (address auctionHouse)
    {
        address existing = auctionHouseFor[token];
        if (existing != address(0)) revert AuctionHouseExists(token, existing);
        if (token == bytes32(0) || tokenCodeHash == bytes32(0)) revert InvalidToken();
        if (tokenCodeHash != trustedTokenCodeHash) {
            revert UntrustedTokenCodeHash(trustedTokenCodeHash, tokenCodeHash);
        }
        if (escrow == bytes32(0)) revert InvalidEscrow();
        if (kernel.programCodeHash(worldId, token) != tokenCodeHash) revert InvalidToken();
        if (kernel.programCodeHash(worldId, escrow) != escrowCodeHash) revert InvalidEscrow();

        address predicted = predictAuctionHouse(token, tokenCodeHash, escrow);
        bytes32 escrowToken = _readBytes32(escrow, TOKEN_ACCOUNT_SELECTOR);
        address escrowAuction = _readAddress(escrow, TRUSTED_AUCTION_SELECTOR);
        if (escrowToken != token || escrowAuction != predicted) {
            revert EscrowBindingMismatch(token, escrowToken, predicted, escrowAuction);
        }

        auctionHouse = address(
            new SwapVMSRC20AuctionHouse{salt: _salt(token)}(
                router, worldId, token, tokenCodeHash, escrow, escrowCodeHash
            )
        );
        if (auctionHouse != predicted) revert PredictionMismatch(predicted, auctionHouse);
        auctionHouseFor[token] = auctionHouse;
        uint256 index = ++auctionHouseCount;
        tokenAt[index] = token;
        emit AuctionHouseCreated(token, auctionHouse, escrow, tokenCodeHash, index);
    }

    function _readBytes32(bytes32 target, bytes4 selector) private view returns (bytes32 value) {
        (bytes memory output,) = kernel.staticCall(worldId, target, abi.encodePacked(selector), 2_000);
        if (output.length != 32) revert InvalidEscrow();
        value = abi.decode(output, (bytes32));
    }

    function _readAddress(bytes32 target, bytes4 selector) private view returns (address value) {
        (bytes memory output,) = kernel.staticCall(worldId, target, abi.encodePacked(selector), 2_000);
        if (output.length != 32) revert InvalidEscrow();
        value = abi.decode(output, (address));
    }

    function _salt(bytes32 token) private view returns (bytes32) {
        return keccak256(abi.encode(worldId, token));
    }
}
