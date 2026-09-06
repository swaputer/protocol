// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwapVMKernel} from "./SwapVMKernel.sol";
import {SwapVMRouter} from "./SwapVMRouter.sol";
import {SwapVMSRC20Market} from "./SwapVMSRC20Market.sol";
import {SwapVMWorldFactory} from "./SwapVMWorldFactory.sol";

/// @notice Permissionless deployment registry for one isolated escrow market per SRC20 program.
/// @dev A creator first deploys the canonical MarketEscrow Mini Contract with the address returned
///      by predictMarket, then registers it here. The factory verifies the escrow's immutable token
///      and trusted-market bindings before deploying the market at that predicted address.
contract SwaputerSRC20MarketFactory {
    bytes4 public constant TOKEN_ACCOUNT_SELECTOR = bytes4(keccak256("tokenAccount()"));
    bytes4 public constant TRUSTED_MARKET_SELECTOR = bytes4(keccak256("trustedMarket()"));

    SwapVMRouter public immutable router;
    SwapVMKernel public immutable kernel;
    bytes32 public immutable worldId;
    bytes32 public immutable escrowCodeHash;
    bytes32 public immutable trustedTokenCodeHash;

    uint256 public marketCount;
    mapping(bytes32 token => address market) public marketFor;
    mapping(uint256 index => bytes32 token) public tokenAt;

    error ZeroAddress();
    error InvalidWorld();
    error InvalidRouter();
    error InvalidToken();
    error InvalidEscrow();
    error MarketExists(bytes32 token, address market);
    error EscrowBindingMismatch(
        bytes32 expectedToken, bytes32 actualToken, address expectedMarket, address actualMarket
    );
    error PredictionMismatch(address expected, address actual);
    error UntrustedTokenCodeHash(bytes32 expected, bytes32 actual);

    event MarketCreated(
        bytes32 indexed token,
        address indexed market,
        bytes32 indexed escrow,
        bytes32 tokenCodeHash,
        uint256 marketIndex
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

    function predictMarket(bytes32 token, bytes32 tokenCodeHash, bytes32 escrow)
        public
        view
        returns (address predicted)
    {
        bytes32 salt = _salt(token);
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(SwapVMSRC20Market).creationCode,
                abi.encode(router, worldId, token, tokenCodeHash, escrow, escrowCodeHash)
            )
        );
        predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function createMarket(bytes32 token, bytes32 tokenCodeHash, bytes32 escrow) external returns (address market) {
        address existing = marketFor[token];
        if (existing != address(0)) revert MarketExists(token, existing);
        if (token == bytes32(0) || tokenCodeHash == bytes32(0)) revert InvalidToken();
        if (tokenCodeHash != trustedTokenCodeHash) {
            revert UntrustedTokenCodeHash(trustedTokenCodeHash, tokenCodeHash);
        }
        if (escrow == bytes32(0)) revert InvalidEscrow();
        if (kernel.programCodeHash(worldId, token) != tokenCodeHash) revert InvalidToken();
        if (kernel.programCodeHash(worldId, escrow) != escrowCodeHash) revert InvalidEscrow();

        address predicted = predictMarket(token, tokenCodeHash, escrow);
        bytes32 escrowToken = _readBytes32(escrow, TOKEN_ACCOUNT_SELECTOR);
        address escrowMarket = _readAddress(escrow, TRUSTED_MARKET_SELECTOR);
        if (escrowToken != token || escrowMarket != predicted) {
            revert EscrowBindingMismatch(token, escrowToken, predicted, escrowMarket);
        }

        market = address(
            new SwapVMSRC20Market{salt: _salt(token)}(router, worldId, token, tokenCodeHash, escrow, escrowCodeHash)
        );
        if (market != predicted) revert PredictionMismatch(predicted, market);
        marketFor[token] = market;
        uint256 index = ++marketCount;
        tokenAt[index] = token;
        emit MarketCreated(token, market, escrow, tokenCodeHash, index);
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
