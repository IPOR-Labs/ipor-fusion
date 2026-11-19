// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {CcipBandToken} from "./CcipLeveragedLegBandRegressionTest.t.sol";

/// @title CcipAnchorBandConfigTest
/// @notice IL-9720: the constructor bounds of the per-executor anchor band on the CCIP executor,
///         `0 < bigChangeBps <= anchorBandBps <= MAX_ATTESTATION_ANCHOR_BAND_BPS` (50_000), and the getter.
contract CcipAnchorBandConfigTest is Test {
    uint256 internal constant MAX_BAND = 50_000;

    MockCcipRouter internal router;
    CcipBandToken internal token;

    function setUp() public {
        router = new MockCcipRouter();
        token = new CcipBandToken();
    }

    function _config(
        uint256 bigChangeBps_,
        uint256 bandBps_
    ) internal view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: bigChangeBps_,
                anchorBandBps: bandBps_,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    function _deploy(uint256 bigChangeBps_, uint256 bandBps_) internal returns (CcipCrosschainExecutor) {
        return
            new CcipCrosschainExecutor(
                address(router),
                address(0xFAC7),
                address(this),
                address(token),
                keccak256("USDC"),
                18,
                _config(bigChangeBps_, bandBps_)
            );
    }

    function testShouldPinTheMaximumBandConstant() public pure {
        assertEq(CrosschainConstants.MAX_ATTESTATION_ANCHOR_BAND_BPS, MAX_BAND, "D3: 50_000 bps");
    }

    function testShouldRejectBandBelowBigChange() public {
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(2_000, 1_999);
    }

    function testShouldRejectBandBelowBigChangeAlsoAtWideBand() public {
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(10_000, 9_999);
    }

    function testShouldRejectBandAboveTheMaximum() public {
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(2_000, MAX_BAND + 1);
    }

    function testShouldRejectZeroBigChange() public {
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(0, 10_000);
    }

    function testShouldRejectZeroBand() public {
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(2_000, 0);
        // a zero band cannot be built in any way: it is below every admissible `bigChangeBps` (>= 1)
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(1, 0);
    }

    function testShouldRejectBigChangeAboveTheMaximumBand() public {
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deploy(MAX_BAND + 1, MAX_BAND);
    }

    function testShouldAcceptBandEqualToBigChange() public {
        CcipCrosschainExecutor e = _deploy(2_000, 2_000);
        assertEq(e.attestationAnchorBandBps(), 2_000, "band == bigChangeBps");
        assertEq(e.BIG_CHANGE_BPS(), 2_000);
    }

    function testShouldAcceptTheMaximumBand() public {
        CcipCrosschainExecutor e = _deploy(2_000, MAX_BAND);
        assertEq(e.attestationAnchorBandBps(), MAX_BAND, "band == MAX_ATTESTATION_ANCHOR_BAND_BPS");
        e = _deploy(MAX_BAND, MAX_BAND);
        assertEq(e.attestationAnchorBandBps(), MAX_BAND, "bigChangeBps == band == maximum");
    }

    function testShouldReturnTheConfiguredBand() public {
        assertEq(_deploy(1_000, 10_000).attestationAnchorBandBps(), 10_000);
        assertEq(_deploy(1_000, 5_000).attestationAnchorBandBps(), 5_000);
        assertEq(_deploy(2_000, 2_000).attestationAnchorBandBps(), 2_000, "the reference band");
    }

    /// @dev The band lives in state and is never written afterwards; an executor built with the minimum band stays
    ///      alive: a positive attestation from a fresh bridge is admitted at the anchor itself.
    function testFuzz_shouldAcceptEveryBandInRangeAndRejectEveryBandOutsideIt(
        uint256 bigChangeBps_,
        uint256 bandBps_
    ) public {
        bigChangeBps_ = bound(bigChangeBps_, 1, MAX_BAND);
        bandBps_ = bound(bandBps_, 0, MAX_BAND + 5_000);
        bool valid = bigChangeBps_ <= bandBps_ && bandBps_ <= MAX_BAND;
        if (!valid) vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        CcipCrosschainExecutor e = _deploy(bigChangeBps_, bandBps_);
        if (valid) assertEq(e.attestationAnchorBandBps(), bandBps_);
    }
}
