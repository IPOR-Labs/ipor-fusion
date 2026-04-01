// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasDepositVault} from "../../../../../../contracts/fuses/midas/ext/IMidasDepositVault.sol";

/// @title MockMidasDepositVaultForSupplyFuse
/// @notice Configurable mock for IMidasDepositVault used by MidasSupplyFuse unit tests.
///         On depositInstant: mints `mTokensToMint` to msg.sender (simulating real Midas vault behavior).
///         Tracks last call arguments for assertions on WAD conversion and correct arguments.
contract MockMidasDepositVaultForSupplyFuse is IMidasDepositVault {
    // The mToken mock address — used to mint tokens to the caller
    address public mTokenAddress;

    // How many mTokens to mint to caller on next depositInstant call
    uint256 public mTokensToMint;

    // Last recorded depositInstant arguments
    address public lastTokenIn;
    uint256 public lastAmountToken; // amountInWad received
    uint256 public lastMinReceiveAmount;
    bytes32 public lastReferrerId;

    // Call counter
    uint256 public depositInstantCallCount;

    constructor(address mTokenAddress_) {
        mTokenAddress = mTokenAddress_;
    }

    /// @notice Configure how many mTokens to mint to caller on the next call
    function setMTokensToMint(uint256 amount) external {
        mTokensToMint = amount;
    }

    /// @notice Simulates depositInstant: records args, mints mTokens to msg.sender
    function depositInstant(
        address tokenIn,
        uint256 amountToken,
        uint256 minReceiveAmount,
        bytes32 referrerId
    ) external override {
        lastTokenIn = tokenIn;
        lastAmountToken = amountToken;
        lastMinReceiveAmount = minReceiveAmount;
        lastReferrerId = referrerId;
        depositInstantCallCount++;

        // Mint mTokens to caller (simulating the vault minting to PlasmaVault context)
        if (mTokensToMint > 0 && mTokenAddress != address(0)) {
            // Call mint on the mock ERC20 (requires MockERC20ForSupplyFuse.mint interface)
            (bool success,) = mTokenAddress.call(abi.encodeWithSignature("mint(address,uint256)", msg.sender, mTokensToMint));
            require(success, "MockMidasDepositVault: mint failed");
        }
    }

    // ---- Unused interface stubs ----

    function depositRequest(
        address, /* tokenIn */
        uint256, /* amountToken */
        bytes32 /* referrerId */
    ) external pure override returns (uint256) {
        revert("MockMidasDepositVaultForSupplyFuse: not used");
    }

    function mintRequests(uint256 /* requestId */) external pure override returns (Request memory) {
        revert("MockMidasDepositVaultForSupplyFuse: not used");
    }

    function mToken() external view override returns (address) {
        return mTokenAddress;
    }

    function mTokenDataFeed() external pure override returns (address) {
        return address(0);
    }
}
