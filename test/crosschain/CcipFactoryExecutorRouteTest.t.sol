// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {CcipCrosschainFactory} from "../../contracts/crosschain/ccip/CcipCrosschainFactory.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

/// @dev Unregistered contract that nevertheless reports the caller as its MANAGER, so only the factory's
///      `isExecutor` check can reject it.
contract CcipFakeExecutor {
    address public immutable MANAGER;

    constructor(address manager_) {
        MANAGER = manager_;
    }
}

/// @title CcipFactoryExecutorRouteTest
/// @notice IL-9151: every check of `CcipCrosschainFactory.registerExecutorRoute` on the real factory (no route
///         validator mock). The executor peer must equal the executor itself and every transport field must match
///         the timelocked factory route; a rejected call leaves the executor's route table untouched.
contract CcipFactoryExecutorRouteTest is Test {
    MockCcipRouter internal router;
    MockERC20 internal token;
    CcipCrosschainFactory internal factory;
    CcipCrosschainExecutor internal executor;

    bytes32 internal constant ASSET_ID = keccak256("USDC");
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant REMOTE_SELECTOR = 15971525489660198786;
    uint64 internal constant OTHER_SELECTOR = 5009297550715157269;
    uint96 internal constant MESSAGE_GAS = 500_000;
    uint96 internal constant TOKEN_GAS = 700_000;
    uint256 internal constant MAX_FEE = 0.01 ether;

    address internal manager;

    function setUp() public {
        manager = makeAddr("manager");
        router = new MockCcipRouter();
        token = new MockERC20("USD Coin", "USDC", 6);
        factory = new CcipCrosschainFactory(address(router), address(this));
        factory.scheduleAsset(ASSET_ID, address(token), 6);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeAsset(ASSET_ID, address(token), 6);
        factory.configureCreationCodes(
            type(CcipCrosschainExecutor).creationCode,
            type(CcipCrosschainDispatcher).creationCode
        );
        _setFactoryRoute(true);

        executor = CcipCrosschainExecutor(
            payable(factory.createExecutor(bytes32("salt"), ASSET_ID, manager, _safety()))
        );
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _setFactoryRoute(bool enabled_) private {
        CcipRouteConfig memory route = CcipRouteConfig({
            chainSelector: REMOTE_SELECTOR,
            peer: address(factory),
            feeToken: address(0),
            messageGasLimit: MESSAGE_GAS,
            tokenGasLimit: TOKEN_GAS,
            maxFee: MAX_FEE,
            enabled: enabled_
        });
        factory.scheduleFactoryRoute(REMOTE_CHAIN, route);
        vm.warp(block.timestamp + factory.CONFIG_DELAY());
        factory.executeFactoryRoute(REMOTE_CHAIN, route);
    }

    function _safety() private pure returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    /// @dev The route that matches the factory route exactly, with the executor as peer.
    function _goodRoute() private view returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: REMOTE_SELECTOR,
                peer: address(executor),
                feeToken: address(0),
                messageGasLimit: MESSAGE_GAS,
                tokenGasLimit: TOKEN_GAS,
                maxFee: MAX_FEE,
                enabled: true
            });
    }

    function _expectMismatchAndUntouched(CcipRouteConfig memory route_) private {
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainFactory.ExecutorRouteMismatch.selector,
                address(executor),
                REMOTE_CHAIN
            )
        );
        factory.registerExecutorRoute(address(executor), REMOTE_CHAIN, route_);

        CcipRouteConfig memory stored = executor.ccipRoute(REMOTE_CHAIN);
        assertEq(stored.chainSelector, 0, "executor route table untouched: selector");
        assertEq(stored.peer, address(0), "executor route table untouched: peer");
        assertFalse(stored.enabled, "executor route table untouched: enabled");
    }

    // ---------------------------------------------------------------------
    // Positive twin
    // ---------------------------------------------------------------------

    function testShouldRegisterExecutorRouteWhenAllFieldsMatch() public {
        vm.prank(manager);
        factory.registerExecutorRoute(address(executor), REMOTE_CHAIN, _goodRoute());

        CcipRouteConfig memory stored = executor.ccipRoute(REMOTE_CHAIN);
        assertEq(stored.chainSelector, REMOTE_SELECTOR, "selector");
        assertEq(stored.peer, address(executor), "peer");
        assertEq(stored.feeToken, address(0), "feeToken");
        assertEq(stored.messageGasLimit, MESSAGE_GAS, "messageGasLimit");
        assertEq(stored.tokenGasLimit, TOKEN_GAS, "tokenGasLimit");
        assertEq(stored.maxFee, MAX_FEE, "maxFee");
        assertTrue(stored.enabled, "enabled");
    }

    // ---------------------------------------------------------------------
    // One field at a time -> ExecutorRouteMismatch
    // ---------------------------------------------------------------------

    function testShouldRevertWhenPeerIsNotTheExecutor() public {
        CcipRouteConfig memory route = _goodRoute();
        route.peer = address(factory);
        _expectMismatchAndUntouched(route);
    }

    function testShouldRevertWhenChainSelectorDiffers() public {
        CcipRouteConfig memory route = _goodRoute();
        route.chainSelector = OTHER_SELECTOR;
        _expectMismatchAndUntouched(route);
    }

    function testShouldRevertWhenFeeTokenDiffers() public {
        CcipRouteConfig memory route = _goodRoute();
        route.feeToken = address(0xFEE);
        _expectMismatchAndUntouched(route);
    }

    function testShouldRevertWhenMessageGasLimitDiffers() public {
        CcipRouteConfig memory route = _goodRoute();
        route.messageGasLimit = MESSAGE_GAS + 1;
        _expectMismatchAndUntouched(route);
    }

    function testShouldRevertWhenTokenGasLimitDiffers() public {
        CcipRouteConfig memory route = _goodRoute();
        route.tokenGasLimit = TOKEN_GAS + 1;
        _expectMismatchAndUntouched(route);
    }

    function testShouldRevertWhenMaxFeeDiffers() public {
        CcipRouteConfig memory route = _goodRoute();
        route.maxFee = MAX_FEE + 1;
        _expectMismatchAndUntouched(route);
    }

    function testShouldRevertWhenSuppliedRouteIsDisabled() public {
        CcipRouteConfig memory route = _goodRoute();
        route.enabled = false;
        _expectMismatchAndUntouched(route);
    }

    function testShouldRevertWhenFactoryRouteIsDisabled() public {
        _setFactoryRoute(false);
        _expectMismatchAndUntouched(_goodRoute());
    }

    function testShouldRevertWhenChainHasNoFactoryRoute() public {
        // chain without any factory route: configured.enabled == false and selector 0
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainFactory.ExecutorRouteMismatch.selector, address(executor), 1)
        );
        factory.registerExecutorRoute(address(executor), 1, _goodRoute());
    }

    // ---------------------------------------------------------------------
    // InvalidExecutor
    // ---------------------------------------------------------------------

    function testShouldRevertInvalidExecutorWhenCallerIsNotManager() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(CcipCrosschainFactory.InvalidExecutor.selector);
        factory.registerExecutorRoute(address(executor), REMOTE_CHAIN, _goodRoute());

        assertEq(executor.ccipRoute(REMOTE_CHAIN).chainSelector, 0, "route not registered");
    }

    function testShouldRevertInvalidExecutorWhenExecutorIsNotRegistered() public {
        CcipFakeExecutor fake = new CcipFakeExecutor(manager);
        CcipRouteConfig memory route = _goodRoute();
        route.peer = address(fake);

        vm.prank(manager);
        vm.expectRevert(CcipCrosschainFactory.InvalidExecutor.selector);
        factory.registerExecutorRoute(address(fake), REMOTE_CHAIN, route);
    }
}
