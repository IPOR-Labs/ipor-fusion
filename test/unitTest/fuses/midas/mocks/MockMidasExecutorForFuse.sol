// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MockMidasExecutorForFuse
/// @notice Mock that replaces MidasExecutor when pre-set in the harness ERC-7201 storage slot.
///         Returns a configurable requestId for depositRequest() and redeemRequest().
///         The harness pre-sets this contract's address in the executor storage slot to avoid
///         auto-deployment of a real MidasExecutor.
contract MockMidasExecutorForFuse {
    /// @dev Next requestId returned by depositRequest()
    uint256 public nextDepositRequestId;

    /// @dev Next requestId returned by redeemRequest()
    uint256 public nextRedeemRequestId;

    /// @dev Track last call parameters
    address public lastDepositTokenIn;
    uint256 public lastDepositAmount;
    address public lastDepositVault;

    address public lastRedeemMToken;
    uint256 public lastRedeemAmount;
    address public lastRedeemTokenOut;
    address public lastRedeemVault;

    address public immutable PLASMA_VAULT;

    constructor(address plasmaVault_) {
        PLASMA_VAULT = plasmaVault_;
    }

    function setNextDepositRequestId(uint256 id) external {
        nextDepositRequestId = id;
    }

    function setNextRedeemRequestId(uint256 id) external {
        nextRedeemRequestId = id;
    }

    function depositRequest(
        address tokenIn,
        uint256 amount,
        address depositVault
    ) external returns (uint256 requestId) {
        lastDepositTokenIn = tokenIn;
        lastDepositAmount = amount;
        lastDepositVault = depositVault;
        return nextDepositRequestId;
    }

    function redeemRequest(
        address mToken,
        uint256 amount,
        address tokenOut,
        address redemptionVault
    ) external returns (uint256 requestId) {
        lastRedeemMToken = mToken;
        lastRedeemAmount = amount;
        lastRedeemTokenOut = tokenOut;
        lastRedeemVault = redemptionVault;
        return nextRedeemRequestId;
    }
}
