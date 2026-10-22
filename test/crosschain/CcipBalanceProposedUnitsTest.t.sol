// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title CcipBalanceProposedUnitsTest
/// @notice IL-8478 (B-21). `BalanceProposed` must report the balance in shared decimals (floored), the same
///         units as `BalanceApproved` and the stored proposal, even when the local asset has more decimals
///         than the shared precision (18 local / 6 shared here).
contract CcipBalanceProposedUnitsTest is Test {
    event BalanceProposed(
        uint256 proposalId, uint256 chainId, uint256 balance, uint64 stateVersion, bytes32 trackedPositionSetHash
    );
    event BalanceApproved(uint256 proposalId, uint256 chainId, uint256 balance);

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant APPROVER = address(0xA33);
    address internal constant RESCUE_ADMIN = address(0xA11);

    CcipCrosschainExecutor internal executor;

    function setUp() public {
        vm.warp(365 days);
        MockCcipRouter router = new MockCcipRouter();
        MockERC20 token = new MockERC20("Wrapped", "W18", 18);
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("W18"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory route = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(0xD15),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, route);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, route);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function testShouldEmitBalanceProposedInSharedDecimalsForEighteenDecimalAsset() public {
        assertEq(executor.LOCAL_DECIMALS(), 18, "local decimals");
        assertEq(executor.SHARED_DECIMALS(), 6, "shared decimals");
        uint256 dust = 123_456_789; // < 1e12, below shared precision
        _anchorSettled(100e18);
        vm.warp(block.timestamp + 1 hours);
        uint64 version = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        bytes32 setHash = keccak256("set");

        vm.expectEmit(false, false, false, true, address(executor));
        emit BalanceProposed(1, REMOTE_CHAIN, 100e6, version, setHash);
        uint256 id = executor.proposeBalance(
            REMOTE_CHAIN,
            100e18 + dust,
            version,
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            setHash
        );
        assertEq(id, 1, "proposal id");

        vm.expectEmit(false, false, false, true, address(executor));
        emit BalanceApproved(id, REMOTE_CHAIN, 100e6);
        vm.prank(APPROVER);
        executor.approveBalance(id);
    }

    /// @dev A non-zero attested balance needs a non-zero settled anchor; use the timelocked rescue.
    function _anchorSettled(uint256 settledLD_) internal {
        uint256 arg = (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) |
            (block.timestamp << 128) | settledLD_;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + 3 days);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }
}
