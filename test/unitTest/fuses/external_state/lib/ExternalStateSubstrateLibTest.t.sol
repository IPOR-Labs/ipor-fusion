// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVaultConfigLib} from "../../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ExternalStateSubstrateLib, ExternalStateSubstrateType} from "../../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";
import {ExternalStateErrors} from "../../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {IporFusionMarkets} from "../../../../../contracts/libraries/IporFusionMarkets.sol";

/// @title ExternalStateSubstrateLibHarness
/// @notice Harness exposing the internal library as external functions so Foundry can call them,
///         and granting substrates into the harness's own storage for `validate*Granted` tests.
contract ExternalStateSubstrateLibHarness {
    function encodeAsset(address a_) external pure returns (bytes32) {
        return ExternalStateSubstrateLib.encodeAssetSubstrate(a_);
    }

    function encodeCustodian(address a_) external pure returns (bytes32) {
        return ExternalStateSubstrateLib.encodeCustodianSubstrate(a_);
    }

    function encodeBalanceAccount(address a_) external pure returns (bytes32) {
        return ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(a_);
    }

    function encodeTarget(address a_, bytes4 s_) external pure returns (bytes32) {
        return ExternalStateSubstrateLib.encodeTargetSubstrate(a_, s_);
    }

    function encodeStaleness(uint256 v_) external pure returns (bytes32) {
        return ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(v_);
    }

    function encodeBigChange(uint256 v_) external pure returns (bytes32) {
        return ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(v_);
    }

    function encodeDust(uint256 v_) external pure returns (bytes32) {
        return ExternalStateSubstrateLib.encodeDustThresholdSubstrate(v_);
    }

    function encodeMinInterval(uint256 v_) external pure returns (bytes32) {
        return ExternalStateSubstrateLib.encodeMinUpdateIntervalSubstrate(v_);
    }

    function decodeType(bytes32 s_) external pure returns (ExternalStateSubstrateType) {
        return ExternalStateSubstrateLib.decodeSubstrateType(s_);
    }

    function decodeAddress(bytes32 s_) external pure returns (address) {
        return ExternalStateSubstrateLib.decodeAddressPayload(s_);
    }

    function decodeTarget(bytes32 s_) external pure returns (address, bytes4) {
        return ExternalStateSubstrateLib.decodeTargetPayload(s_);
    }

    function decodeUint248(bytes32 s_) external pure returns (uint256) {
        return ExternalStateSubstrateLib.decodeUint248Payload(s_);
    }

    function isAsset(bytes32 s_) external pure returns (bool) {
        return ExternalStateSubstrateLib.isAssetSubstrate(s_);
    }

    function isTarget(bytes32 s_) external pure returns (bool) {
        return ExternalStateSubstrateLib.isTargetSubstrate(s_);
    }

    function isCustodian(bytes32 s_) external pure returns (bool) {
        return ExternalStateSubstrateLib.isCustodianSubstrate(s_);
    }

    function isBalanceAccount(bytes32 s_) external pure returns (bool) {
        return ExternalStateSubstrateLib.isBalanceAccountSubstrate(s_);
    }

    function isStaleness(bytes32 s_) external pure returns (bool) {
        return ExternalStateSubstrateLib.isStalenessMaxSubstrate(s_);
    }

    function isBigChange(bytes32 s_) external pure returns (bool) {
        return ExternalStateSubstrateLib.isBigChangeBpsSubstrate(s_);
    }

    function isDust(bytes32 s_) external pure returns (bool) {
        return ExternalStateSubstrateLib.isDustThresholdSubstrate(s_);
    }

    function isMinInterval(bytes32 s_) external pure returns (bool) {
        return ExternalStateSubstrateLib.isMinUpdateIntervalSubstrate(s_);
    }

    function validateAsset(uint256 m_, address a_) external view {
        ExternalStateSubstrateLib.validateAssetGranted(m_, a_);
    }

    function validateBalanceAccount(uint256 m_, address a_) external view {
        ExternalStateSubstrateLib.validateBalanceAccountGranted(m_, a_);
    }

    function validateTarget(uint256 m_, address a_, bytes4 s_) external view {
        ExternalStateSubstrateLib.validateTargetSelectorGranted(m_, a_, s_);
    }

    function grantSubstrates(uint256 m_, bytes32[] memory subs_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(m_, subs_);
    }
}

/// @title ExternalStateSubstrateLibTest
/// @notice 28 unit tests targeting 100% coverage of ExternalStateSubstrateLib.
contract ExternalStateSubstrateLibTest is Test {
    ExternalStateSubstrateLibHarness internal h;
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;

    function setUp() public {
        h = new ExternalStateSubstrateLibHarness();
    }

    // ---------- 1.1 ----------
    function test_encodeAssetSubstrate_decodesBackToAddress() public view {
        address asset = address(0x1234567890123456789012345678901234567890);
        bytes32 encoded = h.encodeAsset(asset);
        assertEq(uint8(h.decodeType(encoded)), uint8(ExternalStateSubstrateType.ASSET));
        assertEq(h.decodeAddress(encoded), asset);
    }

    // ---------- 1.2 ----------
    function test_encodeTargetSubstrate_decodesBackToAddressAndSelector() public view {
        address target = address(0xaAbbcCddeeff11223344556677889900aabbCcDd);
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));
        bytes32 encoded = h.encodeTarget(target, selector);
        assertEq(uint8(h.decodeType(encoded)), uint8(ExternalStateSubstrateType.TARGET));
        (address t, bytes4 s) = h.decodeTarget(encoded);
        assertEq(t, target);
        assertEq(s, selector);
    }

    // ---------- 1.3 ----------
    function test_encodeCustodianSubstrate_typeMatchesCustodian() public {
        address c = makeAddr("custodian");
        bytes32 encoded = h.encodeCustodian(c);
        assertEq(uint8(h.decodeType(encoded)), uint8(ExternalStateSubstrateType.CUSTODIAN));
        assertTrue(h.isCustodian(encoded));
        assertEq(h.decodeAddress(encoded), c);
    }

    // ---------- 1.4 ----------
    function test_encodeBalanceAccountSubstrate_decodesBackToAddress() public {
        address ba = makeAddr("balanceAccount");
        bytes32 encoded = h.encodeBalanceAccount(ba);
        assertEq(uint8(h.decodeType(encoded)), uint8(ExternalStateSubstrateType.BALANCE_ACCOUNT));
        assertEq(h.decodeAddress(encoded), ba);
    }

    // ---------- 1.5 ----------
    function test_encodeStalenessMaxSubstrate_withinUint248() public view {
        uint256 value = 86_400;
        bytes32 encoded = h.encodeStaleness(value);
        assertEq(h.decodeUint248(encoded), value);
        assertTrue(h.isStaleness(encoded));
    }

    // ---------- 1.6 ----------
    function test_encodeStalenessMaxSubstrate_revertsOnOverflow() public {
        uint256 overflow = uint256(type(uint248).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateSubstratePayloadOverflow.selector, uint8(ExternalStateSubstrateType.STALENESS_MAX), overflow
            )
        );
        h.encodeStaleness(overflow);
    }

    // ---------- 1.7 ----------
    function test_encodeBigChangeBpsSubstrate_revertsOnOverflow() public {
        uint256 overflow = uint256(type(uint248).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateSubstratePayloadOverflow.selector, uint8(ExternalStateSubstrateType.BIG_CHANGE_BPS), overflow
            )
        );
        h.encodeBigChange(overflow);
    }

    // ---------- 1.8 ----------
    function test_encodeDustThresholdSubstrate_revertsOnOverflow() public {
        uint256 overflow = uint256(type(uint248).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateSubstratePayloadOverflow.selector, uint8(ExternalStateSubstrateType.DUST_THRESHOLD), overflow
            )
        );
        h.encodeDust(overflow);
    }

    // ---------- 1.9 ----------
    function test_encodeMinUpdateIntervalSubstrate_revertsOnOverflow() public {
        uint256 overflow = uint256(type(uint248).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateSubstratePayloadOverflow.selector, uint8(ExternalStateSubstrateType.MIN_UPDATE_INTERVAL), overflow
            )
        );
        h.encodeMinInterval(overflow);
    }

    // ---------- 1.10 ----------
    function test_decodeSubstrateType_returnsUndefinedForZero() public view {
        assertEq(uint8(h.decodeType(bytes32(0))), uint8(ExternalStateSubstrateType.UNDEFINED));
    }

    // ---------- 1.11 ----------
    function test_decodeSubstrateType_recognizesAllEightTypes() public view {
        assertEq(uint8(h.decodeType(h.encodeAsset(address(0x01)))), uint8(ExternalStateSubstrateType.ASSET));
        assertEq(uint8(h.decodeType(h.encodeTarget(address(0x02), bytes4(0x11223344)))), uint8(ExternalStateSubstrateType.TARGET));
        assertEq(uint8(h.decodeType(h.encodeCustodian(address(0x03)))), uint8(ExternalStateSubstrateType.CUSTODIAN));
        assertEq(uint8(h.decodeType(h.encodeBalanceAccount(address(0x04)))), uint8(ExternalStateSubstrateType.BALANCE_ACCOUNT));
        assertEq(uint8(h.decodeType(h.encodeStaleness(1))), uint8(ExternalStateSubstrateType.STALENESS_MAX));
        assertEq(uint8(h.decodeType(h.encodeBigChange(1))), uint8(ExternalStateSubstrateType.BIG_CHANGE_BPS));
        assertEq(uint8(h.decodeType(h.encodeDust(1))), uint8(ExternalStateSubstrateType.DUST_THRESHOLD));
        assertEq(uint8(h.decodeType(h.encodeMinInterval(1))), uint8(ExternalStateSubstrateType.MIN_UPDATE_INTERVAL));
    }

    // ---------- 1.12 ----------
    function test_isAssetSubstrate_trueOnlyForAsset() public view {
        assertTrue(h.isAsset(h.encodeAsset(address(0x11))));
        assertFalse(h.isAsset(h.encodeCustodian(address(0x22))));
    }

    // ---------- 1.13 ----------
    function test_isTargetSubstrate_trueOnlyForTarget() public view {
        assertTrue(h.isTarget(h.encodeTarget(address(0x11), bytes4(0x01020304))));
        assertFalse(h.isTarget(h.encodeAsset(address(0x22))));
    }

    // ---------- 1.14 ----------
    function test_isCustodianSubstrate_trueOnlyForCustodian() public view {
        assertTrue(h.isCustodian(h.encodeCustodian(address(0x11))));
        assertFalse(h.isCustodian(h.encodeBalanceAccount(address(0x22))));
    }

    // ---------- 1.15 ----------
    function test_isBalanceAccountSubstrate_trueOnlyForBalanceAccount() public view {
        assertTrue(h.isBalanceAccount(h.encodeBalanceAccount(address(0x11))));
        assertFalse(h.isBalanceAccount(h.encodeAsset(address(0x22))));
    }

    // ---------- 1.16 ----------
    function test_isStalenessMaxSubstrate_trueOnlyForStaleness() public view {
        assertTrue(h.isStaleness(h.encodeStaleness(1)));
        assertFalse(h.isStaleness(h.encodeBigChange(1)));
    }

    // ---------- 1.17 ----------
    function test_isBigChangeBpsSubstrate_trueOnlyForBigChange() public view {
        assertTrue(h.isBigChange(h.encodeBigChange(1)));
        assertFalse(h.isBigChange(h.encodeDust(1)));
    }

    // ---------- 1.18 ----------
    function test_isDustThresholdSubstrate_trueOnlyForDust() public view {
        assertTrue(h.isDust(h.encodeDust(1)));
        assertFalse(h.isDust(h.encodeMinInterval(1)));
    }

    // ---------- 1.19 ----------
    function test_isMinUpdateIntervalSubstrate_trueOnlyForMinInterval() public view {
        assertTrue(h.isMinInterval(h.encodeMinInterval(1)));
        assertFalse(h.isMinInterval(h.encodeStaleness(1)));
    }

    // ---------- 1.20 ----------
    function test_validateAssetGranted_passesWhenGranted() public {
        address asset = makeAddr("asset");
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = h.encodeAsset(asset);
        h.grantSubstrates(MARKET_ID, subs);
        h.validateAsset(MARKET_ID, asset); // no revert
    }

    // ---------- 1.21 ----------
    function test_validateAssetGranted_revertsWhenNotGranted() public {
        address asset = makeAddr("asset-missing");
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.ASSET),
                ExternalStateSubstrateLib.encodeAssetSubstrate(asset)
            )
        );
        h.validateAsset(MARKET_ID, asset);
    }

    // ---------- 1.22 ----------
    function test_validateBalanceAccountGranted_passesWhenGranted() public {
        address ba = makeAddr("ba");
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = h.encodeBalanceAccount(ba);
        h.grantSubstrates(MARKET_ID, subs);
        h.validateBalanceAccount(MARKET_ID, ba);
    }

    // ---------- 1.23 ----------
    function test_validateBalanceAccountGranted_revertsWhenNotGranted() public {
        address ba = makeAddr("ba-missing");
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.BALANCE_ACCOUNT),
                ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(ba)
            )
        );
        h.validateBalanceAccount(MARKET_ID, ba);
    }

    // ---------- 1.24 ----------
    function test_validateTargetSelectorGranted_passesWhenGranted() public {
        address t = makeAddr("target");
        bytes4 s = bytes4(keccak256("approve(address,uint256)"));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = h.encodeTarget(t, s);
        h.grantSubstrates(MARKET_ID, subs);
        h.validateTarget(MARKET_ID, t, s);
    }

    // ---------- 1.25 ----------
    function test_validateTargetSelectorGranted_revertsWhenTargetNotGranted() public {
        address t = makeAddr("target-missing");
        bytes4 s = bytes4(0x12345678);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.TARGET),
                ExternalStateSubstrateLib.encodeTargetSubstrate(t, s)
            )
        );
        h.validateTarget(MARKET_ID, t, s);
    }

    // ---------- 1.26 ----------
    function test_validateTargetSelectorGranted_revertsWhenSelectorMismatch() public {
        address t = makeAddr("target");
        bytes4 granted = bytes4(keccak256("approve(address,uint256)"));
        bytes4 requested = bytes4(keccak256("transfer(address,uint256)"));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = h.encodeTarget(t, granted);
        h.grantSubstrates(MARKET_ID, subs);
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.TARGET),
                ExternalStateSubstrateLib.encodeTargetSubstrate(t, requested)
            )
        );
        h.validateTarget(MARKET_ID, t, requested);
    }

    // ---------- 1.27 ----------
    function test_decodeTargetPayload_highAndLowBoundaryAddresses() public view {
        address high = address(type(uint160).max);
        address low = address(1);
        bytes4 sel = bytes4(0xdeadbeef);

        (address t1, bytes4 s1) = h.decodeTarget(h.encodeTarget(high, sel));
        assertEq(t1, high);
        assertEq(s1, sel);

        (address t2, bytes4 s2) = h.decodeTarget(h.encodeTarget(low, sel));
        assertEq(t2, low);
        assertEq(s2, sel);
    }

    // ---------- 1.28 ----------
    function test_decodeUint248Payload_maxValue() public view {
        uint256 max = type(uint248).max;
        bytes32 encoded = h.encodeStaleness(max);
        assertEq(h.decodeUint248(encoded), max);
    }
}
