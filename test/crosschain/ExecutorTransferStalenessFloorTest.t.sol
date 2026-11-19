// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";

contract TransferStalenessFloorToken is ERC20 {
    constructor() ERC20("Transfer Floor USDC", "tfUSDC") {}
}

/// @title ExecutorTransferStalenessFloorTest
/// @notice IL-9663: both executor constructors reject a nonzero `transferStalenessMax` below
///         `CrosschainConstants.MIN_TRANSFER_STALENESS_WINDOW` (1 hour) with
///         `TransferStalenessBelowMinimum(supplied, minimum)`. The immutable value stamps every `RETURN_REQUEST`
///         deadline, so a smaller one yields recalls that always expire. Exactly 1 hour is accepted.
contract ExecutorTransferStalenessFloorTest is CrosschainTestBase {
    /// @dev Mirror of `CrosschainConstants.MIN_TRANSFER_STALENESS_WINDOW`, spelled as a literal so the file also
    ///      compiles on a codebase without the constant; the accept-at-floor and reject-one-below tests pin it to the contract.
    uint256 internal constant FLOOR = 1 hours;

    /// @dev Selector spelled out so the file compiles against a codebase without the error.
    bytes4 internal constant BELOW_MIN_SELECTOR = bytes4(keccak256("TransferStalenessBelowMinimum(uint256,uint256)"));

    MockCcipRouter internal ccipRouter;
    TransferStalenessFloorToken internal ccipToken;

    function setUp() public {
        _baseSetUp();
        // Created here so `vm.expectRevert` is consumed by the executor constructor, not by a helper deployment.
        ccipRouter = new MockCcipRouter();
        ccipToken = new TransferStalenessFloorToken();
    }

    function _expectBelowMinimum(uint256 supplied_) internal {
        vm.expectRevert(abi.encodeWithSelector(BELOW_MIN_SELECTOR, supplied_, FLOOR));
    }

    function _ccipSafety(
        uint256 transferStalenessMax_
    ) internal pure returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 24 hours,
                balanceStalenessMax: 1 hours,
                bigChangeBps: 1_000,
                anchorBandBps: 2_000,
                minUpdateInterval: 10 minutes,
                transferStalenessMax: transferStalenessMax_
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

    function _stargateParams(uint256 transferStalenessMax_) internal view returns (ExecutorInitParams memory p) {
        p = _params();
        p.transferStalenessMax = transferStalenessMax_;
    }

    // ---------------------------------------------------------------------
    // Stargate

    function testShouldRejectStargateTransferStalenessFiftyNineMinutes() public {
        ExecutorInitParams memory p = _stargateParams(59 minutes);
        _expectBelowMinimum(59 minutes);
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectStargateTransferStalenessOneSecond() public {
        ExecutorInitParams memory p = _stargateParams(1);
        _expectBelowMinimum(1);
        _deployExecutor(address(factory), p);
    }

    function testShouldRejectStargateTransferStalenessOneSecondBelowFloor() public {
        ExecutorInitParams memory p = _stargateParams(FLOOR - 1);
        _expectBelowMinimum(FLOOR - 1);
        _deployExecutor(address(factory), p);
    }

    function testShouldAcceptStargateTransferStalenessExactlyFloor() public {
        ExecutorInitParams memory p = _stargateParams(FLOOR);
        assertEq(_deployExecutor(address(factory), p).TRANSFER_STALENESS_MAX(), FLOOR, "transfer staleness set");
    }

    // ---------------------------------------------------------------------
    // CCIP

    function testShouldRejectCcipTransferStalenessFiftyNineMinutes() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _ccipSafety(59 minutes);
        _expectBelowMinimum(59 minutes);
        _deployCcip(cfg);
    }

    function testShouldRejectCcipTransferStalenessOneSecond() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _ccipSafety(1);
        _expectBelowMinimum(1);
        _deployCcip(cfg);
    }

    function testShouldRejectCcipTransferStalenessOneSecondBelowFloor() public {
        CcipCrosschainExecutor.SafetyConfig memory cfg = _ccipSafety(FLOOR - 1);
        _expectBelowMinimum(FLOOR - 1);
        _deployCcip(cfg);
    }

    function testShouldAcceptCcipTransferStalenessExactlyFloor() public {
        CcipCrosschainExecutor e = _deployCcip(_ccipSafety(FLOOR));
        assertEq(e.TRANSFER_STALENESS_MAX(), FLOOR, "transfer staleness set");
    }

    function testShouldKeepZeroTransferStalenessOnTheExistingError() public {
        // Zero stays on the pre-existing error of each transport (the floor does not change it).
        CcipCrosschainExecutor.SafetyConfig memory cfg = _ccipSafety(0);
        vm.expectRevert(CcipCrosschainExecutor.InvalidSafetyConfig.selector);
        _deployCcip(cfg);
    }
}
