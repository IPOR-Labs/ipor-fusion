// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";

/// @title StargateAnchorBandConfigTest
/// @notice IL-9720: the constructor bounds of the per-executor anchor band on the Stargate executor,
///         `0 < bigChangeBps <= anchorBandBps <= MAX_ATTESTATION_ANCHOR_BAND_BPS` (50_000), and the getter.
contract StargateAnchorBandConfigTest is CrosschainTestBase {
    uint256 internal constant MAX_BAND = 50_000;

    function setUp() public {
        _baseSetUp();
    }

    function _deployWith(uint256 bigChangeBps_, uint256 bandBps_) internal returns (StargateCrosschainExecutor) {
        ExecutorInitParams memory p = _params();
        p.bigChangeBps = bigChangeBps_;
        p.anchorBandBps = bandBps_;
        return _deployExecutor(address(factory), p);
    }

    function testShouldPinTheMaximumBandConstant() public pure {
        assertEq(CrosschainConstants.MAX_ATTESTATION_ANCHOR_BAND_BPS, MAX_BAND, "D3: 50_000 bps");
    }

    function testShouldRejectBandBelowBigChange() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, uint256(2_000)));
        _deployWith(2_000, 1_999);
    }

    function testShouldRejectBandBelowBigChangeAlsoAtWideBand() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, uint256(10_000)));
        _deployWith(10_000, 9_999);
    }

    function testShouldRejectBandAboveTheMaximum() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidAnchorBandBps.selector, MAX_BAND + 1));
        _deployWith(2_000, MAX_BAND + 1);
    }

    function testShouldRejectZeroBigChange() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, uint256(0)));
        _deployWith(0, 10_000);
    }

    function testShouldRejectZeroBand() public {
        // a zero band cannot be built in any way: it is below every admissible `bigChangeBps` (>= 1)
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, uint256(2_000)));
        _deployWith(2_000, 0);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, uint256(1)));
        _deployWith(1, 0);
    }

    function testShouldRejectBigChangeAboveTheMaximumBand() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, MAX_BAND + 1));
        _deployWith(MAX_BAND + 1, MAX_BAND);
    }

    function testShouldAcceptBandEqualToBigChange() public {
        StargateCrosschainExecutor e = _deployWith(2_000, 2_000);
        assertEq(e.attestationAnchorBandBps(), 2_000, "band == bigChangeBps");
        assertEq(e.BIG_CHANGE_BPS(), 2_000);
    }

    function testShouldAcceptTheMaximumBand() public {
        assertEq(_deployWith(2_000, MAX_BAND).attestationAnchorBandBps(), MAX_BAND, "band == maximum");
        assertEq(
            _deployWith(MAX_BAND, MAX_BAND).attestationAnchorBandBps(),
            MAX_BAND,
            "bigChangeBps == band == maximum"
        );
    }

    function testShouldReturnTheConfiguredBand() public {
        assertEq(_deployWith(1_000, 10_000).attestationAnchorBandBps(), 10_000);
        assertEq(_deployWith(1_000, 5_000).attestationAnchorBandBps(), 5_000);
        assertEq(_deployWith(2_000, 2_000).attestationAnchorBandBps(), 2_000, "the reference band");
    }

    function testFuzz_shouldAcceptEveryBandInRangeAndRejectEveryBandOutsideIt(
        uint256 bigChangeBps_,
        uint256 bandBps_
    ) public {
        bigChangeBps_ = bound(bigChangeBps_, 1, MAX_BAND);
        bandBps_ = bound(bandBps_, 0, MAX_BAND + 5_000);
        if (bigChangeBps_ > bandBps_) {
            vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidBigChangeBps.selector, bigChangeBps_));
        } else if (bandBps_ > MAX_BAND) {
            vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidAnchorBandBps.selector, bandBps_));
        }
        StargateCrosschainExecutor e = _deployWith(bigChangeBps_, bandBps_);
        if (bigChangeBps_ <= bandBps_ && bandBps_ <= MAX_BAND) assertEq(e.attestationAnchorBandBps(), bandBps_);
    }
}
