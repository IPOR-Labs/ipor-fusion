// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CcipFixtureToken} from "./CcipExecutorFixture.sol";

/// @title CcipFreshFundsGuardTest
/// @notice IL-9143 (ccip-exec C-010): `InsufficientFreshFunds` is asserted nowhere. A send must not spend tokens that
///         back `idleLedger`, otherwise NAV counts them twice (`idleLedger` + `outboundInFlight`). Uses the real
///         18-local / 6-shared decimals shape (rate 1e12), where comparing a shared-decimals ledger with a local
///         token balance would make the reserve almost zero.
contract CcipFreshFundsGuardTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    MockCcipRouter internal router;
    CcipFixtureToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        router = new MockCcipRouter();
        token = new CcipFixtureToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            6,
            _safety()
        );
        CcipRouteConfig memory back = _route(EXECUTOR_SELECTOR, address(executor));
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            back,
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = _route(DISPATCHER_SELECTOR, address(dispatcher));
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);

        // 100e18 bridged and attested, then 60e18 recalled and left unclaimed: idleLedger = 60e6 SD backed by 60e18.
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 500_000);
        vm.warp(block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1);
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            100e18,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 500_000);
    }

    function _route(uint64 selector_, address peer_) private pure returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: address(0),
                messageGasLimit: 500_000,
                tokenGasLimit: 500_000,
                maxFee: 0,
                enabled: true
            });
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
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
            });
    }

    function testShouldRefuseSendThatWouldSpendLedgerBackedTokens() public {
        assertEq(executor.DECIMAL_CONVERSION_RATE(), 1e12, "18/6 shape");
        assertEq(executor.idleLedger(), 60e6, "idle in shared decimals");
        assertEq(token.balanceOf(address(executor)), 60e18, "idle fully backed, no fresh funds");

        uint256 outboundBefore = executor.outboundInFlight(REMOTE_CHAIN);
        uint8 pendingBefore = executor.pendingTransferCount(REMOTE_CHAIN);

        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.InsufficientFreshFunds.selector, 60e18, 60e18, 1e18)
        );
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1e18, 0, address(0), 500_000);

        assertEq(executor.idleLedger(), 60e6, "idleLedger unchanged");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), outboundBefore, "outboundInFlight unchanged");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), pendingBefore, "no pending transfer opened");
        assertEq(token.balanceOf(address(executor)), 60e18, "token balance unchanged");
    }

    function testShouldAllowSendOnceExactlyTheAmountIsFresh() public {
        token.mint(address(executor), 1e18); // exactly the requested amount of fresh funds

        uint256 remoteIdleBefore = dispatcher.trackedIdle();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1e18, 0, address(0), 500_000);

        assertEq(dispatcher.trackedIdle(), remoteIdleBefore + 1e6, "send delivered, in shared decimals");
        assertEq(executor.idleLedger(), 60e6, "idle untouched");
        assertEq(token.balanceOf(address(executor)), 60e18, "idle still fully backed");
    }

    function testShouldRefuseSendWhenFreshFundsAreOneWeiShort() public {
        token.mint(address(executor), 1e18 - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainExecutor.InsufficientFreshFunds.selector,
                60e18 + 1e18 - 1,
                60e18,
                1e18
            )
        );
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 1e18, 0, address(0), 500_000);
    }
}
