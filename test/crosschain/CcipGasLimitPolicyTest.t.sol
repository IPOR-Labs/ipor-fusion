// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteLib} from "../../contracts/crosschain/ccip/lib/CcipRouteLib.sol";
import {CcipSendLib} from "../../contracts/crosschain/ccip/lib/CcipSendLib.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

contract GasPolicyToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @notice IL-8593 / IL-8562: the executor's destination gas limit is bound by the timelocked route policy.
contract CcipGasLimitPolicyTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    uint96 internal constant MESSAGE_LIMIT = 300_000;
    uint96 internal constant TOKEN_LIMIT = 700_000;

    MockCcipRouter internal router;
    GasPolicyToken internal token;
    CcipCrosschainExecutor internal executor;
    MockCcipRouteValidator internal routeValidator;

    function setUp() public {
        router = new MockCcipRouter();
        token = new GasPolicyToken();
        routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: address(0xA33),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory back = _route(EXECUTOR_SELECTOR, address(executor), 500_000, 500_000);
        CcipCrosschainDispatcher dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute =
            _route(DISPATCHER_SELECTOR, address(dispatcher), MESSAGE_LIMIT, TOKEN_LIMIT);
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setAutoDeliver(false);
        token.mint(address(executor), 100e18);
    }

    function _route(uint64 selector_, address peer_, uint96 messageGas_, uint96 tokenGas_)
        private
        pure
        returns (CcipRouteConfig memory)
    {
        return CcipRouteConfig({
            chainSelector: selector_,
            peer: peer_,
            feeToken: address(0),
            messageGasLimit: messageGas_,
            tokenGasLimit: tokenGas_,
            maxFee: 0,
            enabled: true
        });
    }

    /// @dev `GenericExtraArgsV2` = 4-byte tag, then abi.encode(gasLimit, allowOutOfOrderExecution).
    function _sentGasLimit() private view returns (uint256 gasLimit) {
        bytes memory args = router.lastExtraArgs();
        bytes memory body = new bytes(args.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = args[i + 4];
        }
        (gasLimit,) = abi.decode(body, (uint256, bool));
    }

    function testShouldUseRoutePolicyWhenGasLimitIsZeroForTokenSend() public {
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 0);
        assertEq(_sentGasLimit(), TOKEN_LIMIT, "token send uses tokenGasLimit");
    }

    function testShouldUseRoutePolicyWhenGasLimitIsZeroForMessageSend() public {
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 0);
        assertEq(_sentGasLimit(), MESSAGE_LIMIT, "message send uses messageGasLimit");
    }

    function testShouldUseTokenGasLimitForTokenBearingSend() public {
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), TOKEN_LIMIT);
        assertEq(_sentGasLimit(), TOKEN_LIMIT, "token-bearing send is bound by tokenGasLimit");
    }

    function testShouldUseMessageGasLimitForDataOnlySend() public {
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), MESSAGE_LIMIT);
        assertEq(_sentGasLimit(), MESSAGE_LIMIT, "data-only send is bound by messageGasLimit");
    }

    function testShouldClampGasLimitAboveRoutePolicy() public {
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 10_000_000);
        assertEq(_sentGasLimit(), TOKEN_LIMIT, "token send clamped to tokenGasLimit");
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 10_000_000);
        assertEq(_sentGasLimit(), MESSAGE_LIMIT, "message send clamped to messageGasLimit");
    }

    function testShouldRevertGasLimitBelowRoutePolicy() public {
        vm.expectRevert(abi.encodeWithSelector(CcipSendLib.CcipGasLimitBelowRoutePolicy.selector, 1, TOKEN_LIMIT));
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 1);
        vm.expectRevert(
            abi.encodeWithSelector(CcipSendLib.CcipGasLimitBelowRoutePolicy.selector, MESSAGE_LIMIT - 1, MESSAGE_LIMIT)
        );
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), MESSAGE_LIMIT - 1);
    }

    function testShouldRevertMessageLimitOnTokenSendBecauseTokenPolicyIsHigher() public {
        vm.expectRevert(
            abi.encodeWithSelector(CcipSendLib.CcipGasLimitBelowRoutePolicy.selector, MESSAGE_LIMIT, TOKEN_LIMIT)
        );
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), MESSAGE_LIMIT);
    }

    function _pack(uint96 messageGas_, uint96 tokenGas_, bool enabled_) private pure returns (uint256) {
        return uint256(messageGas_) | (uint256(tokenGas_) << 96) | (enabled_ ? 1 << 192 : 0);
    }

    function testShouldRevertUpdatePolicyWithZeroMessageLimitOnEnabledRoute() public {
        vm.expectRevert(abi.encodeWithSelector(CcipRouteLib.CcipRouteGasPolicyUnset.selector, REMOTE_CHAIN));
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _pack(0, TOKEN_LIMIT, true), 0);
    }

    function testShouldRevertUpdatePolicyWithZeroTokenLimitOnEnabledRoute() public {
        vm.expectRevert(abi.encodeWithSelector(CcipRouteLib.CcipRouteGasPolicyUnset.selector, REMOTE_CHAIN));
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _pack(MESSAGE_LIMIT, 0, true), 0);
    }

    function testShouldAcceptUpdatePolicyWithZeroLimitsOnDisabledRoute() public {
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _pack(0, 0, false), 0);
        vm.expectRevert(abi.encodeWithSelector(CcipSendLib.CcipUnknownChain.selector, REMOTE_CHAIN));
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 0);
    }
}
