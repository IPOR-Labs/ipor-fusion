// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FactoryTestBase} from "./FactoryTestBase.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockStargatePool} from "./mocks/MockStargatePool.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainMessages, DeploymentTicket} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateCrosschainFactory} from "../../contracts/crosschain/stargate/StargateCrosschainFactory.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";

/// @title StargateFactoryCreationCodeLifecycleTest
/// @notice IL-9102: the split creation-code lifecycle of the real `StargateCrosschainFactory` (the documented
///         mainnet path): both split orders, the one-shot guards, owner-only setters, `CreationCodesNotConfigured`,
///         and the pinned owner-only overwrite of a half-configured side by `configureCreationCodes` (IL-9101).
/// @dev The factory starts WITHOUT creation codes. Requires the oversized real factory (skips under
///      `--code-size-limit 60000`).
contract StargateFactoryCreationCodeLifecycleTest is FactoryTestBase {
    bytes32 internal constant MARKER_A = keccak256("executor-code-A");
    bytes32 internal constant MARKER_B = keccak256("executor-code-B");

    StargateCrosschainFactory internal sf;
    address internal attacker = address(0xBAD);

    event CreationCodesConfigured(bytes32 executorCodeHash, bytes32 dispatcherCodeHash);

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
    // Split configuration, both orders
    // ------------------------------------------------------------------

    function testShouldConfigureExecutorThenDispatcher() public requiresFactory {
        bytes memory executorCode = _initcode(MARKER_A);
        bytes memory dispatcherCode = type(StargateCrosschainDispatcher).creationCode;

        sf.configureExecutorCreationCode(executorCode);
        assertFalse(sf.creationCodesConfigured(), "one leg is not enough");
        assertEq(sf.executorCreationCodeHash(), keccak256(executorCode), "executor hash recorded");
        assertEq(sf.dispatcherCreationCodeHash(), bytes32(0), "dispatcher hash still empty");

        vm.expectEmit(address(sf));
        emit CreationCodesConfigured(keccak256(executorCode), keccak256(dispatcherCode));
        sf.configureDispatcherCreationCode(dispatcherCode);

        assertTrue(sf.creationCodesConfigured(), "both legs configured");
        assertEq(sf.dispatcherCreationCodeHash(), keccak256(dispatcherCode), "dispatcher hash recorded");
        assertEq(_createExecutor(), _marker(MARKER_A), "createExecutor works after the split");
    }

    function testShouldConfigureDispatcherThenExecutor() public requiresFactory {
        bytes memory executorCode = _initcode(MARKER_A);
        bytes memory dispatcherCode = type(StargateCrosschainDispatcher).creationCode;

        sf.configureDispatcherCreationCode(dispatcherCode);
        assertFalse(sf.creationCodesConfigured(), "one leg is not enough");
        assertEq(sf.dispatcherCreationCodeHash(), keccak256(dispatcherCode), "dispatcher hash recorded");
        assertEq(sf.executorCreationCodeHash(), bytes32(0), "executor hash still empty");

        vm.expectEmit(address(sf));
        emit CreationCodesConfigured(keccak256(executorCode), keccak256(dispatcherCode));
        sf.configureExecutorCreationCode(executorCode);

        assertTrue(sf.creationCodesConfigured(), "both legs configured");
        assertEq(sf.executorCreationCodeHash(), keccak256(executorCode), "executor hash recorded");
        assertEq(_createExecutor(), _marker(MARKER_A), "createExecutor works after the split");
    }

    // ------------------------------------------------------------------
    // One-shot guards
    // ------------------------------------------------------------------

    function testShouldRevertCombinedConfigureAfterCombinedConfigure() public requiresFactory {
        sf.configureCreationCodes(_initcode(MARKER_A), type(StargateCrosschainDispatcher).creationCode);
        vm.expectRevert(CrosschainErrors.CreationCodesAlreadyConfigured.selector);
        sf.configureCreationCodes(_initcode(MARKER_B), type(StargateCrosschainDispatcher).creationCode);
        assertEq(sf.executorCreationCodeHash(), keccak256(_initcode(MARKER_A)), "first code untouched");
    }

    function testShouldRevertCombinedConfigureAfterSplitConfigure() public requiresFactory {
        sf.configureExecutorCreationCode(_initcode(MARKER_A));
        sf.configureDispatcherCreationCode(type(StargateCrosschainDispatcher).creationCode);
        vm.expectRevert(CrosschainErrors.CreationCodesAlreadyConfigured.selector);
        sf.configureCreationCodes(_initcode(MARKER_B), type(StargateCrosschainDispatcher).creationCode);
    }

    function testShouldRevertExecutorConfiguredTwiceBeforeDispatcher() public requiresFactory {
        sf.configureExecutorCreationCode(_initcode(MARKER_A));
        assertFalse(sf.creationCodesConfigured(), "flag still false: only the length guard can stop the repeat");
        vm.expectRevert(CrosschainErrors.CreationCodesAlreadyConfigured.selector);
        sf.configureExecutorCreationCode(_initcode(MARKER_B));
        assertEq(sf.executorCreationCodeHash(), keccak256(_initcode(MARKER_A)), "first executor code untouched");
    }

    function testShouldRevertExecutorConfigureAfterFullConfiguration() public requiresFactory {
        sf.configureCreationCodes(_initcode(MARKER_A), type(StargateCrosschainDispatcher).creationCode);
        vm.expectRevert(CrosschainErrors.CreationCodesAlreadyConfigured.selector);
        sf.configureExecutorCreationCode(_initcode(MARKER_B));
    }

    function testShouldRevertDispatcherConfiguredTwiceBeforeExecutor() public requiresFactory {
        bytes memory dispatcherCode = type(StargateCrosschainDispatcher).creationCode;
        sf.configureDispatcherCreationCode(dispatcherCode);
        assertFalse(sf.creationCodesConfigured(), "flag still false: only the length guard can stop the repeat");
        vm.expectRevert(CrosschainErrors.CreationCodesAlreadyConfigured.selector);
        sf.configureDispatcherCreationCode(hex"6000");
        assertEq(sf.dispatcherCreationCodeHash(), keccak256(dispatcherCode), "first dispatcher code untouched");
    }

    function testShouldRevertDispatcherConfigureAfterFullConfiguration() public requiresFactory {
        sf.configureCreationCodes(_initcode(MARKER_A), type(StargateCrosschainDispatcher).creationCode);
        vm.expectRevert(CrosschainErrors.CreationCodesAlreadyConfigured.selector);
        sf.configureDispatcherCreationCode(hex"6000");
    }

    // ------------------------------------------------------------------
    // Pinned (IL-9101 / C-010): the combined call is not blocked by one split leg; owner-only overwrite
    // ------------------------------------------------------------------

    function testShouldLetOwnerOverwriteHalfConfiguredExecutorWithCombinedConfigure() public requiresFactory {
        bytes memory firstExecutor = _initcode(MARKER_A);
        bytes memory secondExecutor = _initcode(MARKER_B);
        bytes memory dispatcherCode = type(StargateCrosschainDispatcher).creationCode;

        sf.configureExecutorCreationCode(firstExecutor);
        assertFalse(sf.creationCodesConfigured(), "half configured");

        vm.expectEmit(address(sf));
        emit CreationCodesConfigured(keccak256(secondExecutor), keccak256(dispatcherCode));
        sf.configureCreationCodes(secondExecutor, dispatcherCode);

        assertTrue(sf.creationCodesConfigured(), "configured by the combined call");
        assertEq(sf.executorCreationCodeHash(), keccak256(secondExecutor), "executor hash overwritten");
        assertTrue(keccak256(firstExecutor) != sf.executorCreationCodeHash(), "old hash is gone");
        assertEq(_createExecutor(), _marker(MARKER_B), "the overwriting code is the one deployed");
    }

    function testShouldLetOwnerOverwriteHalfConfiguredDispatcherWithCombinedConfigure() public requiresFactory {
        bytes memory dispatcherCode = type(StargateCrosschainDispatcher).creationCode;
        sf.configureDispatcherCreationCode(hex"6000");
        assertEq(sf.dispatcherCreationCodeHash(), keccak256(hex"6000"), "half-configured hash");

        sf.configureCreationCodes(_initcode(MARKER_A), dispatcherCode);

        assertTrue(sf.creationCodesConfigured(), "configured by the combined call");
        assertEq(sf.dispatcherCreationCodeHash(), keccak256(dispatcherCode), "dispatcher hash overwritten");
    }

    // ------------------------------------------------------------------
    // Owner-only entries
    // ------------------------------------------------------------------

    function testShouldRevertConfigureCreationCodesWhenCallerIsNotOwner() public requiresFactory {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        sf.configureCreationCodes(_initcode(MARKER_A), type(StargateCrosschainDispatcher).creationCode);
    }

    function testShouldRevertConfigureExecutorCreationCodeWhenCallerIsNotOwner() public requiresFactory {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        sf.configureExecutorCreationCode(_initcode(MARKER_A));
    }

    function testShouldRevertConfigureDispatcherCreationCodeWhenCallerIsNotOwner() public requiresFactory {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        vm.prank(attacker);
        sf.configureDispatcherCreationCode(type(StargateCrosschainDispatcher).creationCode);
    }

    // ------------------------------------------------------------------
    // CreationCodesNotConfigured
    // ------------------------------------------------------------------

    function testShouldRevertCreateExecutorBeforeAnyConfiguration() public requiresFactory {
        _enableUsdc();
        sf.setCreationRestricted(false);
        vm.expectRevert(CrosschainErrors.CreationCodesNotConfigured.selector);
        sf.createExecutor(keccak256("early"), _params(address(this)));
    }

    function testShouldRevertCreateExecutorWithOnlyExecutorLegConfigured() public requiresFactory {
        _enableUsdc();
        sf.setCreationRestricted(false);
        sf.configureExecutorCreationCode(_initcode(MARKER_A));
        vm.expectRevert(CrosschainErrors.CreationCodesNotConfigured.selector);
        sf.createExecutor(keccak256("half"), _params(address(this)));
    }

    /// @dev A CREATE_DISPATCHER delivery to a factory without creation codes reverts out of `lzReceive` with
    ///      `CreationCodesNotConfigured` (no NACK is sent): LayerZero retains the packet, so it can be retried once
    ///      the owner configures the codes.
    function testShouldRevertDispatcherDeliveryBeforeCreationCodesAreConfigured() public requiresFactory {
        _enableUsdc();
        factory.schedulePathConfig(REMOTE_CHAIN, REMOTE_EID, _factoryPathOptions(REMOTE_EID));
        _warpConfigDelay();
        factory.executePathConfig(REMOTE_CHAIN);
        vm.deal(address(sf), 100 ether);

        address creator = address(0xC0FFEE);
        bytes32 userSalt = keccak256("not-configured");
        address predicted = sf.computeExecutorAddress(creator, userSalt);
        DeploymentTicket memory ticket = DeploymentTicket({
            requestId: 1,
            salt: keccak256(abi.encode(creator, userSalt)),
            executor: predicted,
            srcChainId: REMOTE_CHAIN,
            dstChainId: LOCAL_CHAIN,
            assetId: ASSET_ID,
            admin: admin,
            guardian: guardian,
            rescueDelay: 3 days,
            immutableParamsHash: keccak256(
                abi.encode(admin, guardian, uint256(3 days), REMOTE_CHAIN, LOCAL_CHAIN, ASSET_ID)
            ),
            expiresAt: block.timestamp + 7 days
        });
        bytes memory message = CrosschainMessages.encodeDeploymentTicket(ticket);
        uint256 sentBefore = endpoint.sentCount();

        vm.expectRevert(CrosschainErrors.CreationCodesNotConfigured.selector);
        endpoint.deliverLz(address(sf), REMOTE_EID, bytes32(uint256(uint160(address(sf)))), keccak256("guid"), message);

        assertEq(predicted.code.length, 0, "no dispatcher deployed");
        assertEq(endpoint.sentCount(), sentBefore, "no NACK sent");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Enables USDC, opens creation and deploys an executor from the configured code; returns its runtime.
    function _createExecutor() private returns (bytes memory) {
        _enableUsdc();
        sf.setCreationRestricted(false);
        address executor = sf.createExecutor(keccak256("lifecycle"), _params(address(this)));
        return executor.code;
    }

    function _marker(bytes32 marker_) private pure returns (bytes memory) {
        return abi.encodePacked(marker_);
    }

    /// @dev Small initcode that returns `marker_` (copied from the end of the code) as the runtime.
    function _initcode(bytes32 marker_) private pure returns (bytes memory) {
        uint256 length = 13 + 32;
        return abi.encodePacked(hex"6020", hex"61", uint16(length - 32), hex"600039", hex"60206000f3", marker_);
    }
}
