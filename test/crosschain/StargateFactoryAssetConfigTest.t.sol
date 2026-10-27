// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateFactoryAssetConfigTest
/// @notice IL-9096: the real `StargateCrosschainFactory` asset configuration (`validateAssetConfig` through
///         `scheduleAssetConfig` / `executeAssetConfig`) and the creation-code size bounds (`CreationCodeTooLarge`,
///         `EmptyCreationCode`, the exact 20,000 / 40,000-byte limits with a create-and-run round trip).
/// @dev The factory starts WITHOUT creation codes. Requires the oversized real factory (skips under
///      `--code-size-limit 60000`).
contract StargateFactoryAssetConfigTest is FactoryTestBase {
    uint256 internal constant CHUNK = 20_000;
    bytes32 internal constant MARKER = keccak256("synthetic-executor-runtime");

    StargateCrosschainFactory internal sf;

    function setUp() public {
        vm.chainId(LOCAL_CHAIN);
        vm.warp(365 days);
        endpoint = new MockLzEndpoint();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        try this.deployFactoryExt(CrosschainConstants.MIN_CONFIG_DELAY) returns (address f) {
            sf = StargateCrosschainFactory(payable(f));
            factory = sf;
            factoryReady = true;
        } catch {
            factoryReady = false;
        }
    }

    // ------------------------------------------------------------------
    // validateAssetConfig through scheduleAssetConfig
    // ------------------------------------------------------------------

    function testShouldRevertZeroAddressWhenTokenIsZero() public requiresFactory {
        vm.expectRevert(CrosschainErrors.ZeroAddress.selector);
        sf.scheduleAssetConfig(ASSET_ID, address(0), address(pool));
    }

    function testShouldRevertZeroAddressWhenPoolIsZero() public requiresFactory {
        vm.expectRevert(CrosschainErrors.ZeroAddress.selector);
        sf.scheduleAssetConfig(ASSET_ID, address(usdc), address(0));
    }

    function testShouldRevertNotAContractWhenTokenHasNoCode() public requiresFactory {
        address eoaToken = address(0xDEAD1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NotAContract.selector, eoaToken));
        sf.scheduleAssetConfig(ASSET_ID, eoaToken, address(pool));
    }

    function testShouldRevertNotAContractWhenPoolHasNoCode() public requiresFactory {
        address eoaPool = address(0xDEAD2);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NotAContract.selector, eoaPool));
        sf.scheduleAssetConfig(ASSET_ID, address(usdc), eoaPool);
    }

    function testShouldRevertStargatePoolAssetMismatchWhenPoolTokenDiffers() public requiresFactory {
        MockERC20 other = new MockERC20("Other", "OTH", 6);
        MockStargatePool otherPool = new MockStargatePool(address(other), 6);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.StargatePoolAssetMismatch.selector, address(usdc), address(other))
        );
        sf.scheduleAssetConfig(ASSET_ID, address(usdc), address(otherPool));
    }

    function testShouldRevertInvalidDecimalsWhenLocalBelowShared() public requiresFactory {
        MockStargatePool wide = new MockStargatePool(address(usdc), 8); // local 6 < shared 8
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidDecimals.selector, uint8(6), uint8(8)));
        sf.scheduleAssetConfig(ASSET_ID, address(usdc), address(wide));
    }

    function testShouldScheduleWhenLocalDecimalsEqualShared() public requiresFactory {
        sf.scheduleAssetConfig(ASSET_ID, address(usdc), address(pool)); // 6 == 6
        (address token, address poolAddr, , bool exists) = sf.scheduledAssetConfig(ASSET_ID);
        assertEq(token, address(usdc), "token scheduled");
        assertEq(poolAddr, address(pool), "pool scheduled");
        assertTrue(exists, "scheduled");
    }

    // ------------------------------------------------------------------
    // validateAssetConfig again at executeAssetConfig (state changed inside the timelock)
    // ------------------------------------------------------------------

    function testShouldRevertExecuteWhenPoolTokenChangedDuringTimelock() public requiresFactory {
        sf.scheduleAssetConfig(ASSET_ID, address(usdc), address(pool));
        address swapped = address(0xBEEF);
        vm.mockCall(address(pool), abi.encodeWithSignature("token()"), abi.encode(swapped));
        _warpConfigDelay();
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.StargatePoolAssetMismatch.selector, address(usdc), swapped)
        );
        sf.executeAssetConfig(ASSET_ID);
    }

    function testShouldRevertExecuteWhenTokenCodeRemovedDuringTimelock() public requiresFactory {
        sf.scheduleAssetConfig(ASSET_ID, address(usdc), address(pool));
        vm.etch(address(usdc), "");
        _warpConfigDelay();
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NotAContract.selector, address(usdc)));
        sf.executeAssetConfig(ASSET_ID);
    }

    function testShouldEnableAssetWhenStateUnchangedAtExecute() public requiresFactory {
        _enableUsdc();
        (address token, address poolAddr, bool enabled) = sf.assetConfig(ASSET_ID);
        assertEq(token, address(usdc), "token enabled");
        assertEq(poolAddr, address(pool), "pool enabled");
        assertTrue(enabled, "enabled");
    }

    // ------------------------------------------------------------------
    // Creation-code bounds
    // ------------------------------------------------------------------

    function testShouldRevertCreationCodeTooLargeWhenExecutorCodeExceedsTwoChunks() public requiresFactory {
        vm.expectRevert(CrosschainErrors.CreationCodeTooLarge.selector);
        sf.configureExecutorCreationCode(_filler(2 * CHUNK + 1));
        assertEq(sf.executorCreationCodeHash(), bytes32(0), "nothing recorded");
    }

    function testShouldRevertCreationCodeTooLargeWhenDispatcherCodeExceedsTwoChunks() public requiresFactory {
        vm.expectRevert(CrosschainErrors.CreationCodeTooLarge.selector);
        sf.configureDispatcherCreationCode(_filler(2 * CHUNK + 1));
        assertEq(sf.dispatcherCreationCodeHash(), bytes32(0), "nothing recorded");
    }

    function testShouldRevertCreationCodeTooLargeFromCombinedConfigure() public requiresFactory {
        bytes memory dispatcherCode = type(StargateCrosschainDispatcher).creationCode;
        vm.expectRevert(CrosschainErrors.CreationCodeTooLarge.selector);
        sf.configureCreationCodes(_filler(2 * CHUNK + 1), dispatcherCode);
    }

    function testShouldAcceptCreationCodeOfExactlyTwoChunks() public requiresFactory {
        bytes memory code = _filler(2 * CHUNK);
        sf.configureExecutorCreationCode(code);
        assertEq(sf.executorCreationCodeHash(), keccak256(code), "40,000 B accepted");
    }

    function testShouldRevertEmptyCreationCodeForExecutor() public requiresFactory {
        vm.expectRevert(CrosschainErrors.EmptyCreationCode.selector);
        sf.configureExecutorCreationCode("");
    }

    function testShouldRevertEmptyCreationCodeForDispatcher() public requiresFactory {
        vm.expectRevert(CrosschainErrors.EmptyCreationCode.selector);
        sf.configureDispatcherCreationCode("");
    }

    function testShouldRevertEmptyCreationCodeFromCombinedConfigureForEitherSide() public requiresFactory {
        bytes memory dispatcherCode = type(StargateCrosschainDispatcher).creationCode;
        bytes memory executorCode = type(StargateCrosschainExecutor).creationCode;
        vm.expectRevert(CrosschainErrors.EmptyCreationCode.selector);
        sf.configureCreationCodes("", dispatcherCode);
        vm.expectRevert(CrosschainErrors.EmptyCreationCode.selector);
        sf.configureCreationCodes(executorCode, "");
    }

    // ------------------------------------------------------------------
    // Chunk boundary round trip: store, read back, deploy, run
    // ------------------------------------------------------------------

    function testShouldRoundTripCreationCodeOfExactlyOneChunk() public requiresFactory {
        _assertRoundTrip(CHUNK);
    }

    function testShouldRoundTripCreationCodeOfOneByteOverOneChunk() public requiresFactory {
        _assertRoundTrip(CHUNK + 1);
    }

    function _assertRoundTrip(uint256 length_) private {
        bytes memory code = _syntheticInitcode(length_, MARKER);
        assertEq(code.length, length_, "synthetic length");
        sf.configureExecutorCreationCode(code);
        sf.configureDispatcherCreationCode(type(StargateCrosschainDispatcher).creationCode);
        assertEq(sf.executorCreationCodeHash(), keccak256(code), "hash is keccak of the full code");
        assertTrue(sf.creationCodesConfigured(), "configured");

        _enableUsdc();
        sf.setCreationRestricted(false);
        address executor = sf.createExecutor(keccak256("round-trip"), _params(address(this)));
        assertEq(executor.code, abi.encodePacked(MARKER), "deployed runtime is the marker from the END of the code");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _filler(uint256 length_) private pure returns (bytes memory code) {
        code = new bytes(length_);
        for (uint256 i; i < length_; ++i) code[i] = 0xAA;
    }

    /// @dev Initcode of exactly `length_` bytes: a 13-byte prolog that CODECOPYs the last 32 bytes (the marker)
    ///      to memory and returns them as runtime, non-zero filler, then the marker. The marker sits at the very end,
    ///      so it is only deployed correctly if the whole code (both stores) is read back byte for byte.
    function _syntheticInitcode(uint256 length_, bytes32 marker_) private pure returns (bytes memory code) {
        code = _filler(length_);
        bytes memory prolog = abi.encodePacked(hex"6020", hex"61", uint16(length_ - 32), hex"600039", hex"60206000f3");
        for (uint256 i; i < prolog.length; ++i) code[i] = prolog[i];
        for (uint256 i; i < 32; ++i) code[length_ - 32 + i] = marker_[i];
    }
}
