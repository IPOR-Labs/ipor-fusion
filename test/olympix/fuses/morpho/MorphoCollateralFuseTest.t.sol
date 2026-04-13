// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/morpho/MorphoCollateralFuse.sol

import {MorphoCollateralFuse} from "contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {MorphoCollateralFuseEnterData} from "contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {DustBalanceFuseMock} from "test/connectorsLib/DustBalanceFuseMock.sol";
import {MorphoCollateralFuseExitData} from "contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MorphoCollateralFuse, MorphoCollateralFuseExitData} from "contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract MorphoCollateralFuseTest is OlympixUnitTest("MorphoCollateralFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_zeroCollateral_hitsEarlyReturnBranch() public {
        // Arrange: create a dummy Morpho market so the call does not revert on idToMarketParams
        // We deploy a DustBalanceFuseMock only to have a contract address we can use as a fake collateral token
        DustBalanceFuseMock dummyToken = new DustBalanceFuseMock(1, 18);
    
        // Configure a fake Morpho interface via address casting; we won't reach any Morpho call
        IMorpho fakeMorpho = IMorpho(address(0x1234));
    
        // Deploy fuse with any MARKET_ID and fake Morpho
        MorphoCollateralFuse fuse = new MorphoCollateralFuse(1, address(fakeMorpho));
    
        // Grant the substrate so the unsupported‑market branch is not taken
        bytes32 fakeMarketId = bytes32(uint256(0x1));
        PlasmaVaultStorageLib.MarketSubstratesStruct storage ms = PlasmaVaultStorageLib.getMarketSubstrates().value[1];
        ms.substrateAllowances[fakeMarketId] = 1;
    
        // Act: call enter with collateralAmount == 0 to hit opix-target-branch-87-True
        MorphoCollateralFuseEnterData memory data_ = MorphoCollateralFuseEnterData({
            morphoMarketId: fakeMarketId,
            collateralAmount: 0
        });
    
        (address asset, bytes32 market, uint256 amount) = fuse.enter(data_);
    
        // Assert: early-return path was taken
        assertEq(asset, address(0));
        assertEq(market, bytes32(0));
        assertEq(amount, 0);
    }

    function test_enter_and_exit_revertOnUnsupportedMarket_hitsTrueBranch() public {
            // Arrange: deploy fuse with arbitrary marketId and Morpho address
            uint256 marketId = 1;
            MorphoCollateralFuse fuse = new MorphoCollateralFuse(marketId, address(0x1234));
    
            // Choose a morphoMarketId that is NOT granted in PlasmaVaultConfigLib
            bytes32 unsupportedMarketId = bytes32(uint256(0xDEAD));
    
            // Act + Assert: enter() should revert via MorphoCollateralUnsupportedMarket when collateralAmount > 0
            MorphoCollateralFuseEnterData memory enterData = MorphoCollateralFuseEnterData({
                morphoMarketId: unsupportedMarketId,
                collateralAmount: 1 ether
            });
    
            vm.expectRevert();
            fuse.enter(enterData);
    
            // Also cover exit() unsupported‑market true branch
            MorphoCollateralFuseExitData memory exitData = MorphoCollateralFuseExitData({
                morphoMarketId: unsupportedMarketId,
                collateralAmount: 1 ether
            });
    
            vm.expectRevert();
            fuse.exit(exitData);
        }

    function test_exit_ElseBranchAndRevertOnUnsupportedMarket() public {
        // Arrange: use a fresh fuse instance with a dummy Morpho address
        IMorpho dummyMorpho = IMorpho(address(0x1234));
        uint256 marketId = 1;
        MorphoCollateralFuse fuse = new MorphoCollateralFuse(marketId, address(dummyMorpho));
    
        // Choose a morphoMarketId that is NOT granted in PlasmaVaultConfigLib storage
        bytes32 unsupportedMarketId = bytes32(uint256(123));
    
        // Ensure the substrate is not granted for this market
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
            PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
        marketSubstrates.substrateAllowances[unsupportedMarketId] = 0;
    
        // Prepare exit data with non‑zero collateralAmount to enter the `else` branch
        MorphoCollateralFuseExitData memory data_ = MorphoCollateralFuseExitData({
            morphoMarketId: unsupportedMarketId,
            collateralAmount: 1 ether
        });
    
        // Expect revert from unsupported market check inside the `else` branch
        vm.expectRevert(
            abi.encodeWithSelector(
                MorphoCollateralFuse.MorphoCollateralUnsupportedMarket.selector,
                "exit",
                unsupportedMarketId
            )
        );
    
        // Act: call exit, which should hit the non‑zero `else` branch and then revert
        fuse.exit(data_);
    }

    function test_enterTransient_branchTrue_readsInputsAndCallsEnter() public {
            // Arrange
            IMorpho dummyMorpho = IMorpho(address(0x1234));
            uint256 marketId = 1;
            MorphoCollateralFuse fuse = new MorphoCollateralFuse(marketId, address(dummyMorpho));
    
            // Prepare inputs in transient storage for key VERSION (address of fuse)
            bytes32 morphoMarketId = bytes32(uint256(0xABCD));
            uint256 collateralAmount = 123;
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = morphoMarketId;
            inputs[1] = TypeConversionLib.toBytes32(collateralAmount);
            TransientStorageLib.setInputs(address(fuse), inputs);
    
            // Also grant the substrate so the unsupported‑market check passes and we hit Morpho call path
            PlasmaVaultStorageLib.MarketSubstratesStruct storage ms = PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            ms.substrateAllowances[morphoMarketId] = 1;
    
            // Act & Assert: without a real Morpho implementation, the internal enter() will eventually revert.
            // The goal is to execute the `if (true)` branch and the TransientStorageLib.getInputs(VERSION) path.
            vm.expectRevert();
            fuse.enterTransient();
        }
}