// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

contract SafetyConfigToken is ERC20 {
    constructor() ERC20("Safety Config USDC", "sUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipSafetyConfigTest
/// @notice IL-8058: regression tests for the `SafetyConfig` boundaries added to
///         `CcipCrosschainExecutor`'s constructor. Each `Reject*` test mutates exactly one field of an
///         otherwise in-range base config and asserts construction reverts; each `Accept*` test drives the
///         field(s) it names to their admissible boundary and asserts construction succeeds with the
///         matching getter set. Written and run against the unmodified contract first (fail-without-fix
///         evidence in `audit/IL-7942/IL-8058/cycle-1-implementation.md`): the eight `Reject*` tests that
///         cover a boundary this ticket adds failed there; the five marked `Control` already passed on
///         HEAD and are included to pin that the pre-existing rejections still fire.
contract CcipSafetyConfigTest is Test {
    /// @dev Reference production safety config.
    uint256 internal constant REFERENCE_RESCUE_DELAY = 24 hours;
    uint256 internal constant REFERENCE_STALENESS_MAX = 1 hours;
    uint256 internal constant REFERENCE_TRANSFER_STALENESS_MAX = 1 hours;
    uint256 internal constant REFERENCE_MIN_UPDATE_INTERVAL = 1 minutes;
    uint256 internal constant REFERENCE_BIG_CHANGE_BPS = 1_000;

    MockCcipRouter internal router;
    SafetyConfigToken internal token;
    address internal factory = address(0xFAC7);
    address internal manager;

    function setUp() public {
        router = new MockCcipRouter();
        token = new SafetyConfigToken();
        manager = address(this);
    }

    function _base() internal pure returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: REFERENCE_RESCUE_DELAY,
                balanceStalenessMax: REFERENCE_STALENESS_MAX,
                bigChangeBps: REFERENCE_BIG_CHANGE_BPS,
                minUpdateInterval: REFERENCE_MIN_UPDATE_INTERVAL,
                transferStalenessMax: REFERENCE_TRANSFER_STALENESS_MAX
            });
    }

    function _deploy(CcipCrosschainExecutor.SafetyConfig memory cfg_) internal returns (CcipCrosschainExecutor) {
        return
            new CcipCrosschainExecutor(address(router), factory, manager, address(token), keccak256("USDC"), 6, cfg_);
    }

    // ---------------------------------------------------------------------
    // minUpdateInterval
    // ---------------------------------------------------------------------

    function testShouldRejectZeroMinUpdateInterval() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.minUpdateInterval = 0;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    function testShouldRejectMinUpdateIntervalEqualToBalanceStalenessMax() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.minUpdateInterval = cfg.balanceStalenessMax;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    function testShouldRejectMinUpdateIntervalAboveBalanceStalenessMax() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.minUpdateInterval = cfg.balanceStalenessMax + 1;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    function testShouldAcceptMinUpdateIntervalJustBelowBalanceStalenessMax() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.minUpdateInterval = cfg.balanceStalenessMax - 1;
        CcipCrosschainExecutor e = _deploy(cfg);
        assertEq(e.MIN_UPDATE_INTERVAL(), cfg.balanceStalenessMax - 1, "min update interval set");
    }

    // ---------------------------------------------------------------------
    // bigChangeBps
    // ---------------------------------------------------------------------

    function testShouldRejectZeroBigChangeBps() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.bigChangeBps = 0;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    function testShouldRejectBigChangeBpsAboveAnchorBand() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.bigChangeBps = CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS + 1;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    /// @notice Control: passes on HEAD too (`bigChangeBps > 10_000` was already rejected there). After the
    ///         fix the check that fires is the `ATTESTATION_ANCHOR_BAND_BPS` ceiling, not the superseded
    ///         100% ceiling — `10_001` exceeds both, so the outcome is unchanged.
    function testShouldRejectBigChangeBpsAboveHundredPercent() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.bigChangeBps = 10_001;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    /// @notice The TODO's named case: `bigChangeBps == 10_000` is not `> 10_000`, so it constructed on
    ///         HEAD. After the fix it is rejected by the new anchor-band ceiling.
    function testShouldRejectBigChangeBpsAtHundredPercent() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.bigChangeBps = 10_000;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    function testShouldAcceptBigChangeBpsEqualToAnchorBand() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.bigChangeBps = CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS;
        CcipCrosschainExecutor e = _deploy(cfg);
        assertEq(e.BIG_CHANGE_BPS(), CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS, "big change bps set");
    }

    // ---------------------------------------------------------------------
    // Staleness windows
    // ---------------------------------------------------------------------

    function testShouldRejectBalanceStalenessMaxAboveCeiling() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.balanceStalenessMax = CrosschainConstants.MAX_STALENESS_WINDOW + 1;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    function testShouldRejectTransferStalenessMaxAboveCeiling() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.transferStalenessMax = CrosschainConstants.MAX_STALENESS_WINDOW + 1;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    function testShouldAcceptStalenessWindowsAtCeiling() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.balanceStalenessMax = CrosschainConstants.MAX_STALENESS_WINDOW;
        cfg.transferStalenessMax = CrosschainConstants.MAX_STALENESS_WINDOW;
        cfg.minUpdateInterval = 1 hours;
        CcipCrosschainExecutor e = _deploy(cfg);
        assertEq(e.BALANCE_STALENESS_MAX(), CrosschainConstants.MAX_STALENESS_WINDOW, "balance staleness at ceiling");
        assertEq(e.TRANSFER_STALENESS_MAX(), CrosschainConstants.MAX_STALENESS_WINDOW, "transfer staleness at ceiling");
    }

    // ---------------------------------------------------------------------
    // Controls: pre-existing rejections, unchanged by this fix
    // ---------------------------------------------------------------------

    /// @notice Control: passes on HEAD (`balanceStalenessMax == 0` was already rejected there).
    function testShouldRejectZeroBalanceStalenessMax() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.balanceStalenessMax = 0;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    /// @notice Control: passes on HEAD (`transferStalenessMax == 0` was already rejected there).
    function testShouldRejectZeroTransferStalenessMax() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.transferStalenessMax = 0;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    /// @notice Control: passes on HEAD (`balanceStalenessMax < MIN_PROPOSAL_APPROVAL_WINDOW` was already
    ///         rejected there). The base `minUpdateInterval` (60 s) stays below the mutated value, so this
    ///         isolates only the approval-window predicate.
    function testShouldRejectBalanceStalenessMaxBelowApprovalWindow() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.balanceStalenessMax = CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW - 1;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    /// @notice Control: passes on HEAD (`proposer == approver` was already rejected there).
    function testShouldRejectProposerEqualsApprover() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        cfg.balanceApprover = cfg.balanceProposer;
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(cfg);
    }

    // ---------------------------------------------------------------------
    // Reference config
    // ---------------------------------------------------------------------

    /// @notice Control: passes on HEAD and after the fix — every timing and bps field of `_base()` is
    ///         already the reference production value. The four role addresses are test
    ///         placeholders, not the config's; the constructor only requires each of them nonzero and
    ///         each pair — rescue admin/guardian (`RescueModule`), proposer/approver — distinct, so they
    ///         carry no reference value to preserve.
    function testShouldConstructWithReferenceMainnetConfig() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _base();
        CcipCrosschainExecutor e = _deploy(cfg);
        assertEq(e.RESCUE_DELAY(), REFERENCE_RESCUE_DELAY, "reference rescue delay");
        assertEq(e.BALANCE_STALENESS_MAX(), REFERENCE_STALENESS_MAX, "reference balance staleness max");
        assertEq(e.TRANSFER_STALENESS_MAX(), REFERENCE_TRANSFER_STALENESS_MAX, "reference transfer staleness max");
        assertEq(e.MIN_UPDATE_INTERVAL(), REFERENCE_MIN_UPDATE_INTERVAL, "reference min update interval");
        assertEq(e.BIG_CHANGE_BPS(), REFERENCE_BIG_CHANGE_BPS, "reference big change bps");
    }
}
