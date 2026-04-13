// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/ramses/RamsesV2NewPositionFuse.sol

import {RamsesV2NewPositionFuse} from "contracts/fuses/ramses/RamsesV2NewPositionFuse.sol";
import {INonfungiblePositionManagerRamses} from "contracts/fuses/ramses/ext/INonfungiblePositionManagerRamses.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {RamsesV2NewPositionFuse, RamsesV2NewPositionFuseEnterData} from "contracts/fuses/ramses/RamsesV2NewPositionFuse.sol";
import {FuseStorageLib} from "contracts/libraries/FuseStorageLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
contract RamsesV2NewPositionFuseTest is OlympixUnitTest("RamsesV2NewPositionFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_revertsWhenTokensNotGranted_opixBranch128True() public {
            RamsesV2NewPositionFuse fuse = new RamsesV2NewPositionFuse(1, address(0x1234));
    
            RamsesV2NewPositionFuseEnterData memory data_ = RamsesV2NewPositionFuseEnterData({
                token0: address(0xAAA1),
                token1: address(0xAAA2),
                fee: uint24(3000),
                tickLower: int24(-600),
                tickUpper: int24(600),
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1,
                veRamTokenId: 0
            });
    
            vm.expectRevert(
                abi.encodeWithSelector(
                    RamsesV2NewPositionFuse.RamsesV2NewPositionFuseUnsupportedToken.selector,
                    data_.token0,
                    data_.token1
                )
            );
    
            fuse.enter(data_);
        }

    function test_enterTransient_and_exitTransient_opixBranch222True() public {
            uint256 marketId = 1;
            address positionManager = address(0x1234);
            RamsesV2NewPositionFuse fuse = new RamsesV2NewPositionFuse(marketId, positionManager);
    
            // prepare transient storage inputs for enterTransient to hit the `if (true)` branch
            bytes32[] memory inputs = new bytes32[](11);
            inputs[0] = TypeConversionLib.toBytes32(address(0xAAA1));
            inputs[1] = TypeConversionLib.toBytes32(address(0xAAA2));
            inputs[2] = TypeConversionLib.toBytes32(uint256(uint24(3000)));
            inputs[3] = TypeConversionLib.toBytes32(int256(-600));
            inputs[4] = TypeConversionLib.toBytes32(int256(600));
            inputs[5] = TypeConversionLib.toBytes32(uint256(1e18));
            inputs[6] = TypeConversionLib.toBytes32(uint256(2e18));
            inputs[7] = TypeConversionLib.toBytes32(uint256(0));
            inputs[8] = TypeConversionLib.toBytes32(uint256(0));
            inputs[9] = TypeConversionLib.toBytes32(block.timestamp + 1 hours);
            inputs[10] = TypeConversionLib.toBytes32(uint256(0));
    
            TransientStorageLib.setInputs(fuse.VERSION(), inputs);
    
            // We only need to reach the transient branch; the call is expected to revert later
            vm.expectRevert();
            fuse.enterTransient();
    
            // Now hit the `else { assert(true); }` branch in exitTransient by using len > 0
            bytes32[] memory exitInputs = new bytes32[](2);
            exitInputs[0] = TypeConversionLib.toBytes32(uint256(1));
            exitInputs[1] = TypeConversionLib.toBytes32(uint256(123));
            TransientStorageLib.setInputs(fuse.VERSION(), exitInputs);
    
            vm.expectRevert();
            fuse.exitTransient();
        }
}