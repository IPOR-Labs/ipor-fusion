// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {SiloV2SupplyBorrowableCollateralFuse} from "contracts/fuses/silo_v2/SiloV2SupplyBorrowableCollateralFuse.sol";

/// @dev Target contract: contracts/fuses/silo_v2/SiloV2SupplyCollateralFuseAbstract.sol

import {ISilo} from "contracts/fuses/silo_v2/ext/ISilo.sol";
import {SiloV2SupplyCollateralFuseExitData} from "contracts/fuses/silo_v2/SiloV2SupplyCollateralFuseAbstract.sol";
import {SiloIndex} from "contracts/fuses/silo_v2/SiloIndex.sol";
import {SiloV2SupplyCollateralFuseExitData, SiloV2SupplyCollateralFuseEnterData} from "contracts/fuses/silo_v2/SiloV2SupplyCollateralFuseAbstract.sol";
import {ISiloConfig} from "contracts/fuses/silo_v2/ext/ISiloConfig.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {Test} from "forge-std/Test.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";

import {SiloV2SupplyCollateralFuseEnterData} from "contracts/fuses/silo_v2/SiloV2SupplyCollateralFuseAbstract.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
contract SiloV2SupplyCollateralFuseAbstractTest is OlympixUnitTest("SiloV2SupplyCollateralFuseAbstract") {
    SiloV2SupplyBorrowableCollateralFuse public siloV2SupplyBorrowableCollateralFuse;


    function setUp() public override {
        siloV2SupplyBorrowableCollateralFuse = new SiloV2SupplyBorrowableCollateralFuse(1);
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(siloV2SupplyBorrowableCollateralFuse) != address(0), "Contract should be deployed");
    }

    function test_exit_zeroSiloShares_hitsEarlyReturnBranch() public {
            SiloV2SupplyCollateralFuseExitData memory data = SiloV2SupplyCollateralFuseExitData({
                siloConfig: address(0x1234),
                siloIndex: SiloIndex.SILO0,
                siloShares: 0,
                minSiloShares: 0
            });
    
            (
                ISilo.CollateralType returnedCollateralType,
                address returnedSiloConfig,
                address returnedSilo,
                uint256 returnedSiloShares,
                uint256 returnedSiloAssetAmount
            ) = siloV2SupplyBorrowableCollateralFuse.exit(data);
    
            assertEq(uint256(returnedCollateralType), uint256(ISilo.CollateralType.Collateral), "CollateralType should be preserved");
            assertEq(returnedSiloConfig, data.siloConfig, "siloConfig should be passed through");
            assertEq(returnedSilo, address(0), "silo address should be zero on early return");
            assertEq(returnedSiloShares, 0, "siloShares should be zero on early return");
            assertEq(returnedSiloAssetAmount, 0, "siloAssetAmount should be zero on early return");
        }

    function test_exit_WhenNonZeroShares_TakesElseBranchAndCallsSilo() public {
            // arrange
            address siloConfig = address(0x1001);
            address silo0 = address(0x2001);
            address silo1 = address(0x2002);

            // Use PlasmaVaultMock so delegatecall shares storage context with the fuse
            PlasmaVaultMock vault = new PlasmaVaultMock(address(siloV2SupplyBorrowableCollateralFuse), address(0));

            // Grant siloConfig as substrate for MARKET_ID = 1
            address[] memory assets = new address[](1);
            assets[0] = siloConfig;
            vault.grantAssetsToMarket(1, assets);

            // mock ISiloConfig.getSilos
            vm.mockCall(
                siloConfig,
                abi.encodeWithSelector(ISiloConfig.getSilos.selector),
                abi.encode(silo0, silo1)
            );

            ISilo.CollateralType collateralType = ISilo.CollateralType.Collateral;

            // mock ISilo.maxRedeem (address(this) = address(vault) in delegatecall context)
            vm.mockCall(
                silo0,
                abi.encodeWithSelector(ISilo.maxRedeem.selector, address(vault), collateralType),
                abi.encode(uint256(50))
            );

            // mock ISilo.redeem to return asset amount 100
            vm.mockCall(
                silo0,
                abi.encodeWithSelector(
                    ISilo.redeem.selector,
                    uint256(50),
                    address(vault),
                    address(vault),
                    collateralType
                ),
                abi.encode(uint256(100))
            );

            SiloV2SupplyCollateralFuseExitData memory data = SiloV2SupplyCollateralFuseExitData({
                siloConfig: siloConfig,
                siloIndex: SiloIndex.SILO0,
                siloShares: 50,
                minSiloShares: 10
            });

            // act - call exit via delegatecall through the vault mock (fallback)
            (
                ISilo.CollateralType rtCollateralType,
                address rtSiloConfig,
                address rtSilo,
                uint256 rtSiloShares,
                uint256 rtSiloAssetAmount
            ) = SiloV2SupplyBorrowableCollateralFuse(address(vault)).exit(data);

            // assert
            assertEq(uint256(rtCollateralType), uint256(collateralType), "collateralType");
            assertEq(rtSiloConfig, siloConfig, "siloConfig");
            assertEq(rtSilo, silo0, "silo address picked via SiloIndex.SILO0");
            assertEq(rtSiloShares, 50, "siloShares from maxRedeem/min");
            assertEq(rtSiloAssetAmount, 100, "redeemed asset amount from mock");
        }

    function test_enter_zeroSiloAssetAmount_hitsEarlyReturnBranch_True() public {
            SiloV2SupplyCollateralFuseEnterData memory data = SiloV2SupplyCollateralFuseEnterData({
                siloConfig: address(0x1234),
                siloIndex: SiloIndex.SILO0,
                siloAssetAmount: 0,
                minSiloAssetAmount: 0
            });
    
            (
                ISilo.CollateralType returnedCollateralType,
                address returnedSiloConfig,
                address returnedSilo,
                uint256 returnedSiloShares,
                uint256 returnedSiloAssetAmount
            ) = siloV2SupplyBorrowableCollateralFuse.enter(data);
    
            assertEq(uint256(returnedCollateralType), uint256(ISilo.CollateralType.Collateral), "CollateralType should be preserved");
            assertEq(returnedSiloConfig, data.siloConfig, "siloConfig should be passed through");
            assertEq(returnedSilo, address(0), "silo address should be zero on early return");
            assertEq(returnedSiloShares, 0, "siloShares should be zero on early return");
            assertEq(returnedSiloAssetAmount, 0, "siloAssetAmount should be zero on early return");
        }

    function test_enter_NonZeroSiloAssetAmount_TakesElseBranchAndCallsSilo() public {
            // arrange
            SiloV2SupplyBorrowableCollateralFuse fuseImpl = new SiloV2SupplyBorrowableCollateralFuse(1);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuseImpl), address(0));
    
            address siloConfig = address(0x1001);
            address silo0 = address(0x2001);
            address silo1 = address(0x2002);
    
            // Grant siloConfig as substrate for MARKET_ID = 1 so isSubstrateAsAssetGranted returns true
            address[] memory assets = new address[](1);
            assets[0] = siloConfig;
            vault.grantAssetsToMarket(1, assets);
    
            // Mock ISiloConfig.getSilos to return our silo addresses
            vm.mockCall(
                siloConfig,
                abi.encodeWithSelector(ISiloConfig.getSilos.selector),
                abi.encode(silo0, silo1)
            );
    
            // Mock underlying asset address for the chosen silo (silo0 for SILO0)
            address underlyingAsset = address(0x3001);
            vm.mockCall(
                silo0,
                abi.encodeWithSelector(ISilo.asset.selector),
                abi.encode(underlyingAsset)
            );
    
            // Set vault's balance of underlyingAsset so IporMath.min(...) picks data_.siloAssetAmount
            uint256 desiredSupply = 100;
            vm.mockCall(
                underlyingAsset,
                abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(vault)),
                abi.encode(desiredSupply)
            );
    
            // Mock deposit to return shares = supplied assets
            ISilo.CollateralType collateralType = ISilo.CollateralType.Collateral;
            vm.mockCall(
                silo0,
                abi.encodeWithSelector(ISilo.deposit.selector, desiredSupply, address(vault), collateralType),
                abi.encode(desiredSupply)
            );
    
            SiloV2SupplyCollateralFuseEnterData memory data = SiloV2SupplyCollateralFuseEnterData({
                siloConfig: siloConfig,
                siloIndex: SiloIndex.SILO0,
                siloAssetAmount: desiredSupply,
                minSiloAssetAmount: 10
            });
    
            // act - call enter via delegatecall through vault
            (
                ISilo.CollateralType rtCollateralType,
                address rtSiloConfig,
                address rtSilo,
                uint256 rtSiloShares,
                uint256 rtSiloAssetAmount
            ) = SiloV2SupplyBorrowableCollateralFuse(address(vault)).enter(data);
    
            // assert
            assertEq(uint256(rtCollateralType), uint256(collateralType), "collateralType");
            assertEq(rtSiloConfig, siloConfig, "siloConfig");
            assertEq(rtSilo, silo0, "silo selected via SiloIndex.SILO0");
            assertEq(rtSiloAssetAmount, desiredSupply, "supplied asset amount should match desiredSupply");
            assertEq(rtSiloShares, desiredSupply, "minted shares from mocked deposit");
        }

    function test_exit_RevertsWhenUnsupportedSiloConfig_hitsIfTrueBranch() public {
            // arrange
            SiloV2SupplyCollateralFuseExitData memory data = SiloV2SupplyCollateralFuseExitData({
                siloConfig: address(0x9999),
                siloIndex: SiloIndex.SILO0,
                siloShares: 1,
                minSiloShares: 0
            });
    
            // ensure siloConfig is NOT granted as substrate for MARKET_ID = 1 so condition is true
            // (default state from PlasmaVaultConfigLib is no grants, so we don't call grantAssetsToMarket)
    
            // expect custom error from abstract fuse when substrate is not granted
            vm.expectRevert();
            siloV2SupplyBorrowableCollateralFuse.exit(data);
        }

    function test_exit_RevertsWhenSiloSharesBelowMinSiloShares_hitsIfTrueBranch() public {
            // arrange
            SiloV2SupplyBorrowableCollateralFuse fuse = new SiloV2SupplyBorrowableCollateralFuse(1);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));
    
            address siloConfig = address(0xABCD);
            address silo0 = address(0xBEEF);
            address silo1 = address(0xBEE1);
    
            // grant siloConfig as allowed substrate for MARKET_ID = 1 so second `if` in _exit is false branch
            address[] memory assets = new address[](1);
            assets[0] = siloConfig;
            vault.grantAssetsToMarket(1, assets);
    
            // mock getSilos
            vm.mockCall(
                siloConfig,
                abi.encodeWithSelector(ISiloConfig.getSilos.selector),
                abi.encode(silo0, silo1)
            );
    
            ISilo.CollateralType collateralType = ISilo.CollateralType.Collateral;
    
            // maxRedeem returns fewer shares than requested minSiloShares -> trigger `if (siloShares < data_.minSiloShares)`
            vm.mockCall(
                silo0,
                abi.encodeWithSelector(ISilo.maxRedeem.selector, address(vault), collateralType),
                abi.encode(uint256(5))
            );
    
            SiloV2SupplyCollateralFuseExitData memory data = SiloV2SupplyCollateralFuseExitData({
                siloConfig: siloConfig,
                siloIndex: SiloIndex.SILO0,
                siloShares: 10,
                minSiloShares: 6
            });
    
            // act & assert - call via delegatecall through PlasmaVaultMock so `address(this)` in fuse is vault
            vm.expectRevert();
            SiloV2SupplyBorrowableCollateralFuse(address(vault)).exit(data);
        }
}