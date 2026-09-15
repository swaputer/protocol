// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ERC-20 implementation used only for Swaputer testnet curve rehearsals.
/// @dev These tokens have no production value. BaseSepoliaTestETH intentionally has an open faucet.
abstract contract SwaputerTestERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(address account, uint256 balance, uint256 required);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 required);
    error InvalidRecipient();

    constructor(string memory tokenName, string memory tokenSymbol) {
        name = tokenName;
        symbol = tokenSymbol;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(msg.sender, allowed, amount);
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _mint(address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidRecipient();
        totalSupply += amount;
        balanceOf[recipient] += amount;
        emit Transfer(address(0), recipient, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert InvalidRecipient();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

/// @notice Freely mintable ERC-20 stand-in for test ETH on Base Sepolia and local forks.
contract BaseSepoliaTestETH is SwaputerTestERC20 {
    uint256 public constant FAUCET_AMOUNT = 1_000_000 ether;

    constructor() SwaputerTestERC20("Swaputer Test ETH", "tETH") {}

    function faucet(address recipient) external returns (uint256 amount) {
        amount = FAUCET_AMOUNT;
        _mint(recipient, amount);
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

/// @notice Fixed-supply test representation of the proposed Swaputer gas token issuance.
contract BaseSepoliaSPuter is SwaputerTestERC20 {
    uint256 public constant INITIAL_SUPPLY = 10_000 ether;

    constructor(address initialHolder) SwaputerTestERC20("Swaputer", "sPuter") {
        _mint(initialHolder, INITIAL_SUPPLY);
    }
}
