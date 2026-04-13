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
}