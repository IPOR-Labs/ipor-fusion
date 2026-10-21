// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockCoreDepositWallet
/// @notice Test double for Hyperliquid/Circle's CoreDepositWallet contract that HyperCore token 0
///         (USDC) routes EVM -> Core deposits through on networks where USDC is CCTP-native. Pulls
///         `amount` of `token()` from the caller via `transferFrom` on `deposit`/`depositFor` and
///         records the last call for assertions.
contract MockCoreDepositWallet {
    address public immutable token;

    bool public paused;

    address public lastCaller;
    address public lastRecipient;
    uint256 public lastAmount;
    uint32 public lastDestinationDex;
    uint256 public depositForCallCount;

    event Deposited(address indexed caller, address indexed recipient, uint256 amount, uint32 destinationDex);

    constructor(address token_) {
        token = token_;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function deposit(uint256 amount_, uint32 destinationDex_) external {
        _deposit(msg.sender, amount_, destinationDex_);
    }

    function depositFor(address recipient_, uint256 amount_, uint32 destinationDex_) external {
        _deposit(recipient_, amount_, destinationDex_);
    }

    function _deposit(address recipient_, uint256 amount_, uint32 destinationDex_) internal {
        require(!paused, "MockCoreDepositWallet: paused");
        IERC20(token).transferFrom(msg.sender, address(this), amount_);

        lastCaller = msg.sender;
        lastRecipient = recipient_;
        lastAmount = amount_;
        lastDestinationDex = destinationDex_;
        depositForCallCount += 1;

        emit Deposited(msg.sender, recipient_, amount_, destinationDex_);
    }
}
