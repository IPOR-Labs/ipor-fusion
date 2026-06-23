// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MockEVC
/// @notice Minimal Ethereum Vault Connector mock implementing only the operator methods the
///         EulerSwap fuses call.
contract MockEVC {
    mapping(address => mapping(address => bool)) public authorized;

    address public lastAccount;
    address public lastOperator;
    bool public lastAuthorized;
    uint256 public setOperatorCallCount;

    function setAccountOperator(address account, address operator, bool authorized_) external payable {
        authorized[account][operator] = authorized_;
        lastAccount = account;
        lastOperator = operator;
        lastAuthorized = authorized_;
        setOperatorCallCount++;
    }

    function isAccountOperatorAuthorized(address account, address operator) external view returns (bool) {
        return authorized[account][operator];
    }

    // ---------------------------------------------------------------------
    // call(): forwards to the target on behalf of `onBehalfOfAccount`.
    // The real EVC appends onBehalfOfAccount to calldata so the target's
    // EVCUtil._msgSender() resolves to it. The mocks don't enforce that, so we
    // simply record the on-behalf account and forward the raw call, returning
    // its return data (mirroring IEVC.call's bytes return).
    // ---------------------------------------------------------------------
    address public lastCallTarget;
    address public lastOnBehalfOfAccount;
    uint256 public lastCallValue;
    uint256 public callCount;

    function call(
        address targetContract,
        address onBehalfOfAccount,
        uint256 value,
        bytes calldata data
    ) external payable returns (bytes memory result) {
        lastCallTarget = targetContract;
        lastOnBehalfOfAccount = onBehalfOfAccount;
        lastCallValue = value;
        callCount++;

        bool ok;
        (ok, result) = targetContract.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }
}
