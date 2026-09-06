// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Immutable-policy ERC-20 used as the real SwapVM byte-gas token.
contract SwapVMGasToken {
    string public constant name = "SwapVM Gas Token";
    string public constant symbol = "SVMG";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance(address account, uint256 balance, uint256 required);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 required);
    error InvalidRecipient();

    constructor(uint256 fixedSupply, address initialHolder) {
        if (initialHolder == address(0)) revert InvalidRecipient();
        totalSupply = fixedSupply;
        balanceOf[initialHolder] = fixedSupply;
        emit Transfer(address(0), initialHolder, fixedSupply);
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

    /// @notice Burns tokens owned by the caller, including tokens just taken by the Hook.
    function burn(uint256 amount) external {
        uint256 balance = balanceOf[msg.sender];
        if (balance < amount) revert InsufficientBalance(msg.sender, balance, amount);
        unchecked {
            balanceOf[msg.sender] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(msg.sender, address(0), amount);
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
