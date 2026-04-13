// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/moonwell/MoonwellEnableMarketFuse.sol

import {MoonwellEnableMarketFuse} from "contracts/fuses/moonwell/MoonwellEnableMarketFuse.sol";
import {MComptroller} from "contracts/fuses/moonwell/ext/MComptroller.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {MoonwellEnableMarketFuse, MoonwellEnableMarketFuseEnterData} from "contracts/fuses/moonwell/MoonwellEnableMarketFuse.sol";
import {MoonwellEnableMarketFuse, MoonwellEnableMarketFuseExitData} from "contracts/fuses/moonwell/MoonwellEnableMarketFuse.sol";
import {TransientStorageLibMock} from "test/transient_storage/TransientStorageLibMock.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
contract MoonwellEnableMarketFuseTest is OlympixUnitTest("MoonwellEnableMarketFuse") {


    function test_enter_RevertOnEmptyMTokenArray_branch73True() public {
            // Arrange: create fuse with arbitrary marketId and comptroller
            uint256 marketId = 1;
            address comptroller = address(0x1234);
            MoonwellEnableMarketFuse fuse = new MoonwellEnableMarketFuse(marketId, comptroller);
    
            // Prepare empty mTokens array to trigger len == 0 branch in enter()
            address[] memory mTokens = new address[](0);
            MoonwellEnableMarketFuseEnterData memory data_ = MoonwellEnableMarketFuseEnterData({mTokens: mTokens});
    
            // Expect custom error on empty array
            vm.expectRevert(MoonwellEnableMarketFuse.MoonwellEnableMarketFuseEmptyArray.selector);
    
            // Act: call enter with empty array to hit opix-target-branch-73-True
            fuse.enter(data_);
        }

    function test_enter_NonEmptyArrayHitsElseBranch() public {
        // arrange
        uint256 marketId = 1;
        address comptroller = address(0x1234);
        MoonwellEnableMarketFuse fuse = new MoonwellEnableMarketFuse(marketId, comptroller);

        // Use PlasmaVaultMock so storage context is shared
        PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

        // Provide a non-empty array
        address mToken = address(0xABCD);
        address[] memory mTokens = new address[](1);
        mTokens[0] = mToken;

        // Grant the mToken as substrate in vault's storage
        address[] memory assets = new address[](1);
        assets[0] = mToken;
        vault.grantAssetsToMarket(marketId, assets);

        // Mock comptroller.enterMarkets to return [0] (success)
        uint256[] memory errors = new uint256[](1);
        errors[0] = 0;
        vm.mockCall(comptroller, abi.encodeWithSelector(MComptroller.enterMarkets.selector), abi.encode(errors));

        MoonwellEnableMarketFuseEnterData memory data_ = MoonwellEnableMarketFuseEnterData({mTokens: mTokens});

        // act via vault - this should NOT revert with EmptyArray and will enter the else branch
        vault.execute(address(fuse), abi.encodeWithSelector(MoonwellEnableMarketFuse.enter.selector, data_));
    }

    function test_exit_RevertsOnEmptyArray_branch119True() public {
            // deploy a dummy comptroller (address needed but not used because we revert before calling it)
            MComptroller comptroller = MComptroller(address(0x1));
    
            // create fuse with arbitrary marketId
            MoonwellEnableMarketFuse fuse = new MoonwellEnableMarketFuse(1, address(comptroller));
    
            // prepare empty mTokens array to trigger len == 0 branch
            address[] memory mTokens = new address[](0);
            MoonwellEnableMarketFuseExitData memory data_ = MoonwellEnableMarketFuseExitData({mTokens: mTokens});
    
            // expect custom error on empty array
            vm.expectRevert(MoonwellEnableMarketFuse.MoonwellEnableMarketFuseEmptyArray.selector);
            fuse.exit(data_);
        }

    function test_exit_NonEmptyArray_hitsBranch121Else() public {
            // Use dummy comptroller address
            MComptroller comptroller = MComptroller(address(0x1));

            // Create fuse with arbitrary MARKET_ID
            MoonwellEnableMarketFuse fuse = new MoonwellEnableMarketFuse(1, address(comptroller));

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare a non-empty mTokens array
            address mToken = address(0x10);
            address[] memory mTokens = new address[](1);
            mTokens[0] = mToken;
            MoonwellEnableMarketFuseExitData memory data_ = MoonwellEnableMarketFuseExitData({mTokens: mTokens});

            // We only care about hitting the len != 0 path; the subsequent unsupported-token
            // revert is acceptable and expected (no substrates granted, so it reverts)
            vm.expectRevert(
                abi.encodeWithSelector(MoonwellEnableMarketFuse.MoonwellEnableMarketFuseUnsupportedMToken.selector, mToken)
            );
            vault.execute(address(fuse), abi.encodeWithSelector(MoonwellEnableMarketFuse.exit.selector, data_));
        }

    function test_enterTransient_branch175True_usesInputsAndSetsOutputs() public {
        // Arrange
        uint256 marketId = 1;
        address comptroller = address(0x1);
        MoonwellEnableMarketFuse fuse = new MoonwellEnableMarketFuse(marketId, comptroller);

        // Use PlasmaVaultMock for delegatecall so transient + regular storage context is shared
        PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

        address mToken1 = address(0x101);
        address mToken2 = address(0x202);

        // Grant mTokens as substrates in vault's storage
        address[] memory assets = new address[](2);
        assets[0] = mToken1;
        assets[1] = mToken2;
        vault.grantAssetsToMarket(marketId, assets);

        // Mock comptroller.enterMarkets to return [0, 0] (success)
        uint256[] memory errors = new uint256[](2);
        errors[0] = 0;
        errors[1] = 0;
        vm.mockCall(comptroller, abi.encodeWithSelector(MComptroller.enterMarkets.selector), abi.encode(errors));

        // Prepare inputs for enterTransient:
        // inputs[0] = length (2), inputs[1] = mToken1, inputs[2] = mToken2
        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(uint256(2));
        inputs[1] = TypeConversionLib.toBytes32(mToken1);
        inputs[2] = TypeConversionLib.toBytes32(mToken2);

        vault.setInputs(fuse.VERSION(), inputs);

        // Act: call enterTransient via vault's delegatecall
        vault.execute(address(fuse), abi.encodeWithSignature("enterTransient()"));

        // Assert: outputs are written back
        bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
        assertEq(outputs.length, 3, "outputs length");
        assertEq(TypeConversionLib.toUint256(outputs[0]), 2, "outputs[0] length");
        assertEq(TypeConversionLib.toAddress(outputs[1]), mToken1, "outputs[1] mToken1");
        assertEq(TypeConversionLib.toAddress(outputs[2]), mToken2, "outputs[2] mToken2");
    }
}