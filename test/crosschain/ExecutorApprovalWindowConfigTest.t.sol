// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

contract ApprovalWindowToken is ERC20 {
    constructor() ERC20("Approval Window USDC", "awUSDC") {}
}

/// @title ExecutorApprovalWindowConfigTest
/// @notice IL-9664: the CCIP and Stargate executor constructors require
///         `stalenessMax - minUpdateInterval >= MIN_PROPOSAL_APPROVAL_WINDOW` (15 minutes). An observation is
///         approvable only while its age is at most that difference, so a smaller gap makes the immutable
///         configuration unapprovable in practice. Exactly 15 minutes is accepted; one second less reverts.
contract ExecutorApprovalWindowConfigTest is CrosschainTestBase {
    uint256 internal constant STALENESS = 1 hours;

    MockCcipRouter internal ccipRouter;
    ApprovalWindowToken internal ccipToken;

    function setUp() public {
        _baseSetUp();
        // Created here so `vm.expectRevert` is consumed by the executor constructor, not by a helper deployment.
        ccipRouter = new MockCcipRouter();
        ccipToken = new ApprovalWindowToken();
    }

    // ---------------------------------------------------------------------
    // Stargate

    function _stargateParams(uint256 minUpdateInterval_) internal view returns (ExecutorInitParams memory p) {
        p = _params();
        p.stalenessMax = STALENESS;
        p.minUpdateInterval = minUpdateInterval_;
    }

    function testShouldRejectStargateWindowBelowMinimumApprovalWindow() public {
        ExecutorInitParams memory p = _stargateParams(STALENESS - CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW + 1);
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p);
    }

    function testShouldAcceptStargateWindowExactlyMinimumApprovalWindow() public {
        uint256 interval = STALENESS - CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW;
        ExecutorInitParams memory p = _stargateParams(interval);
        assertEq(_deployExecutor(address(factory), p).MIN_UPDATE_INTERVAL(), interval, "interval set");
    }

    function testShouldRejectStargateIntervalJustBelowStalenessMax() public {
        ExecutorInitParams memory p = _stargateParams(STALENESS - 1);
        vm.expectRevert(CrosschainErrors.InvalidTimingParameter.selector);
        _deployExecutor(address(factory), p);
    }

    // ---------------------------------------------------------------------
    // CCIP

    function _ccipSafety(
        uint256 minUpdateInterval_
    ) internal pure returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 24 hours,
                balanceStalenessMax: STALENESS,
                bigChangeBps: 1_000,
                anchorBandBps: 2_000,
                minUpdateInterval: minUpdateInterval_,
                transferStalenessMax: 1 hours
            });
    }

    function _deployCcip(CcipCrosschainExecutor.SafetyConfig memory cfg_) internal returns (CcipCrosschainExecutor) {
        return
            new CcipCrosschainExecutor(
                address(ccipRouter),
                address(0xFAC7),
                address(this),
                address(ccipToken),
                keccak256("USDC"),
                6,
                cfg_
            );
    }

    function testShouldRejectCcipWindowBelowMinimumApprovalWindow() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _ccipSafety(
            STALENESS - CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW + 1
        );
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deployCcip(cfg);
    }

    function testShouldAcceptCcipWindowExactlyMinimumApprovalWindow() public {
        uint256 interval = STALENESS - CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW;
        CcipCrosschainExecutor e = _deployCcip(_ccipSafety(interval));
        assertEq(e.MIN_UPDATE_INTERVAL(), interval, "interval set");
    }

    function testShouldRejectCcipIntervalJustBelowStalenessMax() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _ccipSafety(STALENESS - 1);
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deployCcip(cfg);
    }
}
