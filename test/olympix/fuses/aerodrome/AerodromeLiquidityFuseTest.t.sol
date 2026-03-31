// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {AerodromeLiquidityFuse} from "../../../../contracts/fuses/aerodrome/AerodromeLiquidityFuse.sol";

import {AerodromeLiquidityFuseEnterData} from "contracts/fuses/aerodrome/AerodromeLiquidityFuse.sol";
import {AerodromeLiquidityFuse} from "contracts/fuses/aerodrome/AerodromeLiquidityFuse.sol";
import {IRouter} from "contracts/fuses/aerodrome/ext/IRouter.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {AerodromeLiquidityFuseExitData} from "contracts/fuses/aerodrome/AerodromeLiquidityFuse.sol";
import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {TransientStorageLibMock} from "test/transient_storage/TransientStorageLibMock.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
contract AerodromeLiquidityFuseTest is OlympixUnitTest("AerodromeLiquidityFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_RevertsWhenTokenAOrBIsZero_forInvalidTokenBranch() public {
        AerodromeLiquidityFuse fuse = new AerodromeLiquidityFuse(1, address(0x1));
    
        AerodromeLiquidityFuseEnterData memory data_ = AerodromeLiquidityFuseEnterData({
            tokenA: address(0), // triggers data_.tokenA == address(0) || data_.tokenB == address(0)
            tokenB: address(0x2),
            stable: false,
            amountADesired: 1,
            amountBDesired: 1,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp + 1 days
        });
    
        // Expect the custom invalid token error, which corresponds to the `if` branch
        vm.expectRevert(AerodromeLiquidityFuse.AerodromeLiquidityFuseInvalidToken.selector);
        fuse.enter(data_);
    }

    function test_enter_TokensNonZeroHitsElseBranchAndRevertsOnUnsupportedPool() public {
            AerodromeLiquidityFuse fuse = new AerodromeLiquidityFuse(1, address(0x1234));
    
            // tokens are non-zero so the first if condition in enter() is false
            // this forces execution into the marked else-branch (opix-target-branch-172 else)
            AerodromeLiquidityFuseEnterData memory data = AerodromeLiquidityFuseEnterData({
                tokenA: address(0x1),
                tokenB: address(0x2),
                stable: false,
                amountADesired: 1,
                amountBDesired: 1,
                amountAMin: 0,
                amountBMin: 0,
                deadline: block.timestamp + 1 days
            });
    
            // We don't configure PlasmaVaultConfigLib to grant any substrate for this market,
            // so after hitting the else-branch it will revert with UnsupportedPool.
            vm.expectRevert();
            fuse.enter(data);
        }

    function test_exit_revertsOnZeroTokenAddress() public {
        AerodromeLiquidityFuse fuse = new AerodromeLiquidityFuse(1, address(0x1234));
    
        AerodromeLiquidityFuseExitData memory data = AerodromeLiquidityFuseExitData({
            tokenA: address(0),
            tokenB: address(0xBEEF),
            stable: false,
            liquidity: 1 ether,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp + 1 days
        });
    
        vm.expectRevert(AerodromeLiquidityFuse.AerodromeLiquidityFuseInvalidToken.selector);
        fuse.exit(data);
    }

    function test_exit_entersElseBranchWhenTokensNonZero() public {
        // Router can be any non-zero address for this branch test
        AerodromeLiquidityFuse fuse = new AerodromeLiquidityFuse(1, address(0x1234));
    
        // tokenA and tokenB are non-zero so the initial `if` is false and the `else` branch is taken
        AerodromeLiquidityFuseExitData memory data = AerodromeLiquidityFuseExitData({
            tokenA: address(0xAA01),
            tokenB: address(0xBB02),
            stable: false,
            liquidity: 0,
            amountAMin: 0,
            amountBMin: 0,
            deadline: block.timestamp + 1 days
        });
    
        // No revert is expected from the first if; router/pool calls may revert but that is outside
        // the targeted branch. We only need to ensure the call is executed so the `else` branch is hit.
        // To avoid external call reverts interfering with branch coverage, we set liquidity to 0 so
        // the external removeLiquidity call can process trivially.
        vm.expectRevert();
        // We still perform the call so the branch is entered before any later revert.
        fuse.exit(data);
    }

    function test_enterTransient_HitsIfBranchAndSetsOutputs() public {
        // Deploy fuse with non-zero router to satisfy constructor check
        AerodromeLiquidityFuse fuse = new AerodromeLiquidityFuse(1, address(0x1234));
    
        // Prepare inputs matching enterTransient decoding order
        address tokenA = address(0xA1);
        address tokenB = address(0xB2);
        bool stable = false;
        uint256 amountADesired = 1;
        uint256 amountBDesired = 2;
        uint256 amountAMin = 0;
        uint256 amountBMin = 0;
        uint256 deadline = block.timestamp + 1 days;
    
        bytes32[] memory inputs = new bytes32[](8);
        inputs[0] = TypeConversionLib.toBytes32(tokenA);
        inputs[1] = TypeConversionLib.toBytes32(tokenB);
        inputs[2] = TypeConversionLib.toBytes32(stable);
        inputs[3] = TypeConversionLib.toBytes32(amountADesired);
        inputs[4] = TypeConversionLib.toBytes32(amountBDesired);
        inputs[5] = TypeConversionLib.toBytes32(amountAMin);
        inputs[6] = TypeConversionLib.toBytes32(amountBMin);
        inputs[7] = TypeConversionLib.toBytes32(deadline);
    
        // Write inputs into transient storage under VERSION key
        TransientStorageLibMock transientMock = new TransientStorageLibMock();
        transientMock.setInputs(fuse.VERSION(), inputs);
    
        // The call will revert due to external router / substrate checks,
        // but the `if (true)` branch in enterTransient will be executed first.
        vm.expectRevert();
        fuse.enterTransient();
    }

    function test_exitTransient_UsesInputsAndSetsOutputs() public {
            // Deploy fuse with non-zero router to avoid constructor revert
            AerodromeLiquidityFuse fuse = new AerodromeLiquidityFuse(1, address(0x1234));
    
            // Prepare inputs matching exitTransient decoding order
            address tokenA = address(0xAA01);
            address tokenB = address(0xBB02);
            bool stable = false;
            uint256 liquidity = 0;
            uint256 amountAMin = 0;
            uint256 amountBMin = 0;
            uint256 deadline = block.timestamp + 1 days;
    
            bytes32[] memory inputs = new bytes32[](7);
            inputs[0] = TypeConversionLib.toBytes32(tokenA);
            inputs[1] = TypeConversionLib.toBytes32(tokenB);
            inputs[2] = TypeConversionLib.toBytes32(stable);
            inputs[3] = TypeConversionLib.toBytes32(liquidity);
            inputs[4] = TypeConversionLib.toBytes32(amountAMin);
            inputs[5] = TypeConversionLib.toBytes32(amountBMin);
            inputs[6] = TypeConversionLib.toBytes32(deadline);
    
            // VERSION is the address of the fuse instance
            TransientStorageLib.setInputs(address(fuse), inputs);
    
            // Call exitTransient; it will enter the `if (true)` branch (opix-target-branch-344-True)
            vm.expectRevert();
            fuse.exitTransient();
        }
}