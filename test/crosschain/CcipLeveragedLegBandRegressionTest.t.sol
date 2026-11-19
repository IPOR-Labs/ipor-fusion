// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CcipAnchorBandRegressionConfig} from "./helpers/CcipAnchorBandRegressionConfig.sol";

/// @notice 18-decimal token for the anchor band suites.
contract CcipBandToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipBandFixtureBase
/// @notice A real CCIP executor wired to a real dispatcher through the in-memory router, with the relative step
///         (`bigChangeBps`) and the anchor band chosen per test. The configuration is built through field assignments and
///         `CcipAnchorBandRegressionConfig.withBand`, so this file also compiles on the base commit (IL-9720): it uses no
///         symbol the base does not have, and no revert is asserted through a declaration the base lacks.
abstract contract CcipBandFixtureBase is Test {
    using stdStorage for StdStorage;

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;
    uint256 internal constant MIN_UPDATE_INTERVAL = 1 hours;
    /// @dev `AttestationOutsideAnchorBand(uint256,uint256,uint256,uint256)`, derived from the signature on purpose.
    bytes4 internal constant OUTSIDE_BAND =
        bytes4(keccak256("AttestationOutsideAnchorBand(uint256,uint256,uint256,uint256)"));
    bytes4 internal constant BIG_CHANGE = bytes4(keccak256("BigChangeExceeded(uint256,uint256,uint256)"));

    MockCcipRouter internal router;
    CcipBandToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function _config(
        uint256 bigChangeBps_,
        uint256 bandBps_
    ) internal view returns (CcipCrosschainExecutor.SafetyConfig memory c) {
        c.rescueAdmin = RESCUE_ADMIN;
        c.rescueGuardian = address(0xB22);
        c.balanceProposer = address(this);
        c.balanceApprover = APPROVER;
        c.rescueDelay = RESCUE_DELAY;
        c.balanceStalenessMax = 7 days;
        c.bigChangeBps = bigChangeBps_;
        c.minUpdateInterval = MIN_UPDATE_INTERVAL;
        c.transferStalenessMax = 1 days;
        return CcipAnchorBandRegressionConfig.withBand(c, bandBps_);
    }

    function _setUpBand(uint256 bigChangeBps_, uint256 bandBps_) internal {
        router = new MockCcipRouter();
        token = new CcipBandToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _config(bigChangeBps_, bandBps_)
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            RESCUE_ADMIN,
            address(0xB22),
            RESCUE_DELAY
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    /// @dev Bridge `amount_` and let the in-memory router settle it: credits `settled` and the anchor.
    function _bridge(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    /// @dev Waits the update interval, proposes and tries to approve `balance_`.
    function _tryAttest(uint256 balance_) internal returns (bool ok, bytes memory reason) {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(APPROVER);
        try executor.approveBalance(proposalId) {
            ok = true;
        } catch (bytes memory data) {
            reason = data;
        }
    }

    function _attest(uint256 balance_) internal {
        (bool ok, bytes memory reason) = _tryAttest(balance_);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /// @dev Remote loss realised on the dispatcher's tracked idle (tokens and accounting move together).
    function _realiseLoss(uint256 amount_) internal {
        vm.prank(address(dispatcher));
        token.transfer(address(0xdead), amount_);
        stdstore.target(address(dispatcher)).sig("trackedIdle()").checked_write(dispatcher.trackedIdle() - amount_);
    }

    /// @dev Yield realised as tracked idle on the dispatcher (tokens and accounting move together).
    function _accrueYield(uint256 amount_) internal {
        token.mint(address(dispatcher), amount_);
        stdstore.target(address(dispatcher)).sig("trackedIdle()").checked_write(dispatcher.trackedIdle() + amount_);
    }
}

/// @title CcipLeveragedLegBandRegressionTest
/// @notice IL-9720 (3sigma #26): a leveraged leg (10x to 20x) moves its equity by multiples of the underlying move, so
///         it leaves a +-20% window around the anchor after a 1% to 2% move. The relative step stays 20% per approval
///         (the only value both the base and the new code accept), and the leg is walked to its true value with ordinary
///         approvals, each within 20% of the previous one: 8.0M -> 9.6M -> 11.2M (+40% from the anchor) and
///         8.0M -> 6.4M -> 5.6M (-30%). With a band of 10_000 bps every step is admitted; on the base commit (band fixed
///         at 2_000) the second step of each sequence reverts `AttestationOutsideAnchorBand` and this file fails, which
///         `base_regression.sh` records. A jump in a single step is not the scenario: the 20% relative step rejects it.
contract CcipLeveragedLegBandRegressionTest is CcipBandFixtureBase {
    uint256 internal constant ANCHOR = 8_000_000e18;

    function setUp() public {
        _setUpBand(2_000, 10_000);
        _bridge(ANCHOR);
    }

    function testShouldWalkALeveragedLegUpFortyPercentWithOrdinaryAttestations() public {
        _attest(9_600_000e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 9_600_000e18, "first step: +20% from the anchor");
        _attest(11_200_000e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 11_200_000e18, "second step: +40% from the anchor");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), ANCHOR, "approvals never move the anchor");
    }

    function testShouldWalkALeveragedLegDownThirtyPercentWithOrdinaryAttestations() public {
        _attest(6_400_000e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 6_400_000e18, "first step: -20% from the anchor");
        _attest(5_600_000e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 5_600_000e18, "second step: -30% from the anchor");
    }

    function testShouldStillRejectAJumpInOneStep() public {
        (bool ok, bytes memory reason) = _tryAttest(11_200_000e18);
        assertFalse(ok, "a +40% jump is refused");
        assertEq(bytes4(reason), BIG_CHANGE, "by the relative step, not by the band");
    }
}
