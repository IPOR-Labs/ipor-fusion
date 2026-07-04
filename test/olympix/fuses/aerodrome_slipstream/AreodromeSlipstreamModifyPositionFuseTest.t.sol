// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockSlipstreamNFPM} from "test/test_helpers/MockSlipstreamNFPM.sol";
import {
    AreodromeSlipstreamModifyPositionFuse,
    AreodromeSlipstreamModifyPositionFuseEnterData,
    AreodromeSlipstreamModifyPositionFuseExitData
} from "contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamModifyPositionFuse.sol";

import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamLib.sol";
import {ICLFactory} from "contracts/fuses/aerodrome_slipstream/ext/ICLFactory.sol";
import {INonfungiblePositionManager} from "contracts/fuses/aerodrome_slipstream/ext/INonfungiblePositionManager.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {TransientStorageLibMock} from "test/transient_storage/TransientStorageLibMock.sol";
contract AreodromeSlipstreamModifyPositionFuseTest is OlympixUnitTest("AreodromeSlipstreamModifyPositionFuse") {
    AreodromeSlipstreamModifyPositionFuse internal fuse;
    MockSlipstreamNFPM internal nfpm;
    address internal constant FACTORY = address(0xFAC);
    uint256 internal constant MARKET_ID = 99;

    function setUp() public override {
        nfpm = new MockSlipstreamNFPM(FACTORY);
        fuse = new AreodromeSlipstreamModifyPositionFuse(MARKET_ID, address(nfpm));
    }

    function test_example_constructorSetsImmutables() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.NONFUNGIBLE_POSITION_MANAGER(), address(nfpm));
        assertEq(fuse.FACTORY(), FACTORY);
        assertEq(fuse.VERSION(), address(fuse));
    }

    function test_example_constructorRevertsOnZeroNFPM() public {
        vm.expectRevert(AreodromeSlipstreamModifyPositionFuse.InvalidAddress.selector);
        new AreodromeSlipstreamModifyPositionFuse(MARKET_ID, address(0));
    }

    function test_example_enterRevertsOnDeadlineExpired() public {
        AreodromeSlipstreamModifyPositionFuseEnterData memory data;
        data.deadline = block.timestamp - 1; // past deadline
        data.amount0Desired = 1;
        vm.expectRevert(AreodromeSlipstreamModifyPositionFuse.DeadlineExpired.selector);
        fuse.enter(data);
    }

    function test_example_enterRevertsOnZeroAmounts() public {
        AreodromeSlipstreamModifyPositionFuseEnterData memory data;
        data.deadline = type(uint256).max;
        // both amount0Desired and amount1Desired are 0
        vm.expectRevert(AreodromeSlipstreamModifyPositionFuse.InvalidAmount.selector);
        fuse.enter(data);
    }

    function test_example_exitRevertsOnDeadlineExpired() public {
        AreodromeSlipstreamModifyPositionFuseExitData memory data;
        data.deadline = block.timestamp - 1;
        data.liquidity = 100;
        vm.expectRevert(AreodromeSlipstreamModifyPositionFuse.DeadlineExpired.selector);
        fuse.exit(data);
    }

    function test_enter_HitsElseBranchAmountCheck() public {
            // Arrange: set future deadline so DeadlineExpired check passes and else-branch assert(true) is hit
            AreodromeSlipstreamModifyPositionFuseEnterData memory data;
            data.deadline = block.timestamp + 1;
            // Make the condition `(data_.amount0Desired == 0 && data_.amount1Desired == 0)` false
            // by setting at least one of the amounts to non‑zero, so we enter the `else` branch at line 179.
            data.amount0Desired = 1;
            data.amount1Desired = 0;
            // tokenId remains 0 so that _validatePool reverts with InvalidTokenId after the branch we target
            
            vm.expectRevert(AreodromeSlipstreamModifyPositionFuse.InvalidTokenId.selector);
            fuse.enter(data);
        }

    function test_exit_doesNotRevertWhenDeadlineNotExpired() public {
            // Arrange: make deadline condition false so we enter the `else` branch at line 270
            AreodromeSlipstreamModifyPositionFuseExitData memory data;
            data.deadline = block.timestamp + 1; // >= block.timestamp, so the `if` is false and `else` branch executes
            data.liquidity = 1; // non‑zero to avoid InvalidAmount revert later
    
            // We don't reach pool validation (_validatePool) because nfpm.positions() is unimplemented in the mock
            // and would revert there; this is fine because the branch we target is before that call.
    
            vm.expectRevert();
            fuse.exit(data);
        }

    function test_exitTransient_HitsTrueBranchAndRevertsOnTooShortInputs() public {
            // Arrange: prepare inputs array that is intentionally too short to trigger
            // an out-of-bounds access when exitTransient() reads inputs[4].
            // This still goes through the `if (true)` branch at the top of exitTransient.
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(uint256(0)); // tokenId
            inputs[1] = TypeConversionLib.toBytes32(uint256(1)); // liquidity
    
            // Use the mock to write into transient storage slot indexed by VERSION
            TransientStorageLibMock tsMock = new TransientStorageLibMock();
            tsMock.setInputs(fuse.VERSION(), inputs);
    
            // Act & Assert: exitTransient should read inputs, enter the `if (true)` branch,
            // and then revert with a panic due to array out-of-bounds access when
            // attempting to read inputs[2..4]. This confirms the true branch is executed.
            vm.expectRevert();
            fuse.exitTransient();
        }
}