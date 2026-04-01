// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasRedemptionVault} from "../../../../../../contracts/fuses/midas/ext/IMidasRedemptionVault.sol";

/// @title MockMidasRedemptionVaultForSupplyFuse
/// @notice Configurable mock for IMidasRedemptionVault used by MidasSupplyFuse unit tests.
///         On redeemInstant: transfers `tokenOutToTransfer` of `tokenOutAddress` to msg.sender.
///         Can be set to revert for testing exception-catch behavior.
///         Tracks last call arguments for assertion.
contract MockMidasRedemptionVaultForSupplyFuse is IMidasRedemptionVault {
    // The tokenOut mock address — used to transfer tokenOut to caller
    address public tokenOutAddress;

    // How many tokenOut tokens to transfer to caller on next redeemInstant call
    uint256 public tokenOutToTransfer;

    // When true, redeemInstant reverts with a custom error
    bool public shouldRevert;

    // Custom error message when shouldRevert = true
    bytes public revertData;

    // Last recorded redeemInstant arguments
    address public lastTokenOut;
    uint256 public lastAmountMTokenIn;
    uint256 public lastMinReceiveAmount;

    // Call counter
    uint256 public redeemInstantCallCount;

    constructor(address tokenOutAddress_) {
        tokenOutAddress = tokenOutAddress_;
    }

    /// @notice Configure how many tokenOut tokens to transfer to caller on next call
    function setTokenOutToTransfer(uint256 amount) external {
        tokenOutToTransfer = amount;
    }

    /// @notice Configure whether to revert on next redeemInstant call
    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
        revertData = abi.encodeWithSignature("MockRedemptionVaultReverted()");
    }

    /// @notice Configure revert with custom bytes (for precise revert matching)
    function setShouldRevertWithData(bytes memory data) external {
        shouldRevert = true;
        revertData = data;
    }

    /// @notice Simulates redeemInstant: records args, optionally reverts, transfers tokenOut to msg.sender
    function redeemInstant(
        address tokenOut,
        uint256 amountMTokenIn,
        uint256 minReceiveAmount
    ) external override {
        if (shouldRevert) {
            bytes memory data = revertData;
            assembly {
                revert(add(data, 32), mload(data))
            }
        }

        lastTokenOut = tokenOut;
        lastAmountMTokenIn = amountMTokenIn;
        lastMinReceiveAmount = minReceiveAmount;
        redeemInstantCallCount++;

        // Transfer tokenOut to caller (simulating the vault transferring to PlasmaVault context)
        if (tokenOutToTransfer > 0 && tokenOutAddress != address(0)) {
            (bool success,) = tokenOutAddress.call(
                abi.encodeWithSignature("transfer(address,uint256)", msg.sender, tokenOutToTransfer)
            );
            require(success, "MockMidasRedemptionVault: transfer failed");
        }
    }

    // ---- Unused interface stubs ----

    function redeemRequest(
        address, /* tokenOut */
        uint256 /* amountMTokenIn */
    ) external pure override returns (uint256) {
        revert("MockMidasRedemptionVaultForSupplyFuse: not used");
    }

    function redeemRequests(uint256 /* requestId */) external pure override returns (Request memory) {
        revert("MockMidasRedemptionVaultForSupplyFuse: not used");
    }

    function mToken() external pure override returns (address) {
        return address(0);
    }
}
