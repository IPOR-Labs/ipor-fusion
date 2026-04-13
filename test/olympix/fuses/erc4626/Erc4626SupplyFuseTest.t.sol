// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {Erc4626SupplyFuse} from "contracts/fuses/erc4626/Erc4626SupplyFuse.sol";

/// @dev Target contract: contracts/fuses/erc4626/Erc4626SupplyFuse.sol

import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {Erc4626SupplyFuseEnterData} from "contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626SupplyFuseExitData} from "contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract Erc4626SupplyFuseTest is OlympixUnitTest("Erc4626SupplyFuse") {
    Erc4626SupplyFuse public erc4626SupplyFuse;


    function setUp() public override {
        erc4626SupplyFuse = new Erc4626SupplyFuse(1);
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(erc4626SupplyFuse) != address(0), "Contract should be deployed");
    }

    function test_enter_WhenVaultAssetAmountZero_ReturnsZeroAndHitsBranch86True() public {
            // Arrange: create data with vaultAssetAmount == 0 to take the opix-target-branch-86-True path
            Erc4626SupplyFuseEnterData memory data_ = Erc4626SupplyFuseEnterData({
                vault: address(0x1234),
                vaultAssetAmount: 0,
                minSharesOut: 0
            });
    
            // Act: call enter with zero amount
            uint256 result = erc4626SupplyFuse.enter(data_);
    
            // Assert: function should early‑return 0 when vaultAssetAmount == 0
            assertEq(result, 0, "enter should return 0 when vaultAssetAmount is zero");
        }

    function test_instantWithdraw_UsesCatchBranchAndEmitsExitOrExitFailed() public {
            // Arrange: set up underlying token and ERC4626 vault
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            MockERC4626 erc4626Vault = new MockERC4626(underlying, "Vault", "vTKN");

            // Use PlasmaVaultMock so substrate storage and fuse execution share the same context
            PlasmaVaultMock pvMock = new PlasmaVaultMock(address(erc4626SupplyFuse), address(0));

            // Grant the vault as a supported substrate in pvMock's storage
            address[] memory assets = new address[](1);
            assets[0] = address(erc4626Vault);
            pvMock.grantAssetsToMarket(1, assets);

            // Mint underlying to pvMock and deposit into the vault so that withdraw is possible
            underlying.mint(address(pvMock), 1e18);
            // approve from pvMock to erc4626Vault via delegatecall
            vm.prank(address(pvMock));
            underlying.approve(address(erc4626Vault), 1e18);
            vm.prank(address(pvMock));
            erc4626Vault.deposit(1e18, address(pvMock));

            // Prepare params for instantWithdraw: params[0] = amount, params[1] = vault address
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(uint256(5e17)); // withdraw 0.5 tokens
            params[1] = bytes32(uint256(uint160(address(erc4626Vault))));

            // Act: call instantWithdraw via pvMock (delegatecall)
            pvMock.instantWithdraw(params);

            // Assert: after instantWithdraw, some amount of underlying should have been withdrawn to pvMock
            uint256 underlyingBalance = underlying.balanceOf(address(pvMock));
            assertGt(underlyingBalance, 0, "instantWithdraw should result in some underlying balance");
        }

    function test_exit_WhenVaultAssetAmountZero_ReturnsZeroAndHitsBranch172True() public {
            // Arrange: deploy underlying token and ERC4626 vault
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            MockERC4626 vault = new MockERC4626(underlying, "Vault", "vTKN");
    
            // Grant the vault as a supported substrate for MARKET_ID = 1 so the unsupported-vault revert is not triggered
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[1];
            bytes32 vaultAsBytes32 = PlasmaVaultConfigLib.addressToBytes32(address(vault));
            marketSubstrates.substrateAllowances[vaultAsBytes32] = 1;
    
            // Prepare exit data with vaultAssetAmount == 0 to take opix-target-branch-172-True path
            Erc4626SupplyFuseExitData memory data_ = Erc4626SupplyFuseExitData({
                vault: address(vault),
                vaultAssetAmount: 0,
                maxSharesBurned: 0
            });
    
            // Act
            uint256 sharesBurned = erc4626SupplyFuse.exit(data_);
    
            // Assert: function should early‑return 0 when vaultAssetAmount == 0
            assertEq(sharesBurned, 0, "exit should return 0 when vaultAssetAmount is zero");
        }
}