// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IMidasRedemptionVault} from "../../../../../../contracts/fuses/midas/ext/IMidasRedemptionVault.sol";
import {IMidasDataFeed} from "../../../../../../contracts/fuses/midas/ext/IMidasDataFeed.sol";

/// @title MockMidasRedemptionVaultForSupplyFuse
/// @notice Configurable mock for IMidasRedemptionVault used by MidasSupplyFuse unit tests.
///         On redeemInstant: transfers `tokenOutToTransfer` of `tokenOutAddress` to msg.sender.
///         Can be set to revert for testing exception-catch behavior.
///         Tracks last call arguments for assertion.
///         Also serves the read-only views of IMidasRedemptionVaultLimits (IL-9617) with neutral defaults: mToken rate
///         1e18 (the mock is its own mToken data feed), stable tokenOut, no fees, unlimited allowance and daily limit,
///         minimum 0. With `simulateMidasPayout` it pays tokenOut like a Midas redemption vault instead of the fixed
///         `tokenOutToTransfer`. The views are declared here without inheriting the new interface, so the mock also
///         compiles against the audited base (regression proof).
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

    // ---- IMidasRedemptionVaultLimits views (neutral defaults) ----
    uint256 private constant _ONE_HUNDRED_PERCENT = 100_00;
    uint256 private constant _STABLECOIN_RATE = 1e18;

    address private _mTokenDataFeed;
    uint256 public mTokenRate = 1e18;
    uint256 public instantFee;
    uint256 public instantDailyLimit = type(uint256).max;
    mapping(uint256 => uint256) public dailyLimits;
    uint256 public minAmount;

    address private _tokenOutDataFeed;
    uint256 private _tokenFee;
    uint256 private _tokenAllowance = type(uint256).max;
    bool private _tokenStable = true;

    // When true, redeemInstant pays tokenOut with the Midas formula instead of `tokenOutToTransfer`
    bool public simulateMidasPayout;

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

    // ---- Configuration of the IMidasRedemptionVaultLimits views ----

    function setMTokenRate(uint256 rate_) external {
        mTokenRate = rate_;
    }

    function setMTokenDataFeed(address dataFeed_) external {
        _mTokenDataFeed = dataFeed_;
    }

    function setInstantFee(uint256 fee_) external {
        instantFee = fee_;
    }

    function setInstantDailyLimit(uint256 limit_) external {
        instantDailyLimit = limit_;
    }

    function setDailyLimitUsed(uint256 day_, uint256 used_) external {
        dailyLimits[day_] = used_;
    }

    function setMinAmount(uint256 minAmount_) external {
        minAmount = minAmount_;
    }

    function setTokenConfig(address dataFeed_, uint256 fee_, uint256 allowance_, bool stable_) external {
        _tokenOutDataFeed = dataFeed_;
        _tokenFee = fee_;
        _tokenAllowance = allowance_;
        _tokenStable = stable_;
    }

    function setSimulateMidasPayout(bool simulate_) external {
        simulateMidasPayout = simulate_;
    }

    // ---- IMidasRedemptionVaultLimits views ----

    /// @notice mToken data feed; the mock itself unless set
    function mTokenDataFeed() external view returns (address) {
        return _mTokenDataFeed == address(0) ? address(this) : _mTokenDataFeed;
    }

    /// @notice Data feed answer of the mock when it is its own mToken data feed
    function getDataInBase18() external view returns (uint256) {
        return mTokenRate;
    }

    function tokensConfig(
        address /* token */
    ) external view returns (address dataFeed, uint256 fee, uint256 allowance, bool stable) {
        return (_tokenOutDataFeed, _tokenFee, _tokenAllowance, _tokenStable);
    }

    /// @notice tokenOut paid by Midas for `amountMTokenIn_`: fee taken in mTokens (rounded down), the rest converted at
    ///         mTokenRate / tokenOutRate and rounded down to the tokenOut decimals
    function midasPayout(uint256 amountMTokenIn_) public view returns (uint256) {
        uint256 feePercent = instantFee + _tokenFee;
        if (feePercent > _ONE_HUNDRED_PERCENT) feePercent = _ONE_HUNDRED_PERCENT;
        uint256 withoutFee = amountMTokenIn_ - (amountMTokenIn_ * feePercent) / _ONE_HUNDRED_PERCENT;
        uint256 rate = _tokenStable ? _STABLECOIN_RATE : IMidasDataFeed(_tokenOutDataFeed).getDataInBase18();
        uint256 payoutBase18 = (withoutFee * _rateOfMToken()) / rate;
        (, bytes memory data) = tokenOutAddress.staticcall(abi.encodeWithSignature("decimals()"));
        uint256 decimals = abi.decode(data, (uint8));
        return decimals >= 18 ? payoutBase18 * 10 ** (decimals - 18) : payoutBase18 / 10 ** (18 - decimals);
    }

    function _rateOfMToken() private view returns (uint256) {
        return _mTokenDataFeed == address(0) ? mTokenRate : IMidasDataFeed(_mTokenDataFeed).getDataInBase18();
    }

    /// @notice Simulates redeemInstant: records args, optionally reverts, transfers tokenOut to msg.sender
    function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) external override {
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

        uint256 toTransfer = simulateMidasPayout ? midasPayout(amountMTokenIn) : tokenOutToTransfer;

        // Transfer tokenOut to caller (simulating the vault transferring to PlasmaVault context)
        if (toTransfer > 0 && tokenOutAddress != address(0)) {
            (bool success, ) = tokenOutAddress.call(
                abi.encodeWithSignature("transfer(address,uint256)", msg.sender, toTransfer)
            );
            require(success, "MockMidasRedemptionVault: transfer failed");
        }
    }

    // ---- Unused interface stubs ----

    function redeemRequest(
        address /* tokenOut */,
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

/// @title MockRevertingMidasDataFeed
/// @notice Data feed whose `getDataInBase18` reverts with a reason, like a Midas feed that failed its health check
contract MockRevertingMidasDataFeed {
    error MockMidasDataFeedUnhealthy();

    function getDataInBase18() external pure returns (uint256) {
        revert MockMidasDataFeedUnhealthy();
    }
}

/// @title MockMidasRedemptionVaultWithoutDailyLimits
/// @notice Redemption vault of an older Midas version: has every limits view of IMidasRedemptionVaultLimits except
///         `dailyLimits(uint256)` (no fallback, so a call to it reverts with empty data)
contract MockMidasRedemptionVaultWithoutDailyLimits {
    address public immutable MOCK_FEED;

    constructor(address feed_) {
        MOCK_FEED = feed_;
    }

    function mTokenDataFeed() external view returns (address) {
        return MOCK_FEED;
    }

    function instantDailyLimit() external pure returns (uint256) {
        return type(uint256).max;
    }

    function minAmount() external pure returns (uint256) {
        return 0;
    }

    function instantFee() external pure returns (uint256) {
        return 0;
    }

    function tokensConfig(
        address /* token */
    ) external pure returns (address dataFeed, uint256 fee, uint256 allowance, bool stable) {
        return (address(0), 0, type(uint256).max, true);
    }

    function redeemInstant(address, uint256, uint256) external pure {
        revert("MockMidasRedemptionVaultWithoutDailyLimits: not used");
    }
}
