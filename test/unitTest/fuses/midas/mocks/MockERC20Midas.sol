// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MockERC20Midas
/// @notice Minimal ERC20 mock for testing MidasRequestSupplyFuse.
///         Supports configurable decimals, mint, and transfer tracking.
contract MockERC20Midas {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public totalSupply;

    /// @dev Tracks last safeTransfer call for assertion
    address public lastTransferTo;
    uint256 public lastTransferAmount;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "MockERC20Midas: burn exceeds balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockERC20Midas: transfer exceeds balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        lastTransferTo = to;
        lastTransferAmount = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "MockERC20Midas: transferFrom exceeds balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "MockERC20Midas: allowance exceeded");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        lastTransferTo = to;
        lastTransferAmount = amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @dev Allow force-setting balance for test setup
    function setBalance(address account, uint256 amount) external {
        if (balanceOf[account] <= totalSupply) {
            totalSupply = totalSupply - balanceOf[account] + amount;
        } else {
            totalSupply = amount;
        }
        balanceOf[account] = amount;
    }
}
