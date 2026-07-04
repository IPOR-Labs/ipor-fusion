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

import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {MockERC4626WithFee} from "test/test_helpers/MockERC4626WithFee.sol";
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

    function test_enter_unsupportedVault_reverts_and_hitsBranch92True() public {
        // Arrange: deploy underlying token and ERC4626 vault
        MockERC20 underlying = new MockERC20("Token", "TKN", 18);
        MockERC4626 vault = new MockERC4626(underlying, "Vault", "vTKN");
    
        // Prepare enter data with non‑zero amount so the first early‑return is skipped
        Erc4626SupplyFuseEnterData memory data_ = Erc4626SupplyFuseEnterData({
            vault: address(vault),
            vaultAssetAmount: 1e18,
            minSharesOut: 0
        });
    
        // Act & Assert: since the vault was NOT granted as a substrate for MARKET_ID=1,
        // PlasmaVaultConfigLib.isSubstrateAsAssetGranted(1, vault) returns false and
        // the opix‑target‑branch‑92‑True path is taken, reverting with the custom error
        vm.expectRevert();
        erc4626SupplyFuse.enter(data_);
    }

    function test_enterTransient_UsesInputsAndSetsOutputs_opixBranch122True() public {
        // Arrange: underlying token and ERC4626 vault
        MockERC20 underlying = new MockERC20("Token", "TKN", 18);
        MockERC4626 vault = new MockERC4626(underlying, "Vault", "vTKN");
    
        // PlasmaVaultMock so fuse runs via delegatecall in same storage context
        PlasmaVaultMock pvMock = new PlasmaVaultMock(address(erc4626SupplyFuse), address(0));
    
        // Grant vault as supported substrate for MARKET_ID = 1 so the unsupported‑vault revert path is NOT taken
        address[] memory assets = new address[](1);
        assets[0] = address(vault);
        pvMock.grantAssetsToMarket(1, assets);
    
        // Mint underlying to PlasmaVaultMock and approve to the vault
        underlying.mint(address(pvMock), 1e18);
        vm.prank(address(pvMock));
        underlying.approve(address(vault), 1e18);
    
        // Prepare transient inputs for VERSION key stored in the fuse
        bytes32[] memory inputs = new bytes32[](3);
        inputs[0] = TypeConversionLib.toBytes32(address(vault));
        inputs[1] = TypeConversionLib.toBytes32(uint256(5e17)); // amount = 0.5 tokens
        inputs[2] = TypeConversionLib.toBytes32(uint256(0));    // minSharesOut = 0
    
        // Set inputs in transient storage under VERSION (erc4626SupplyFuse.VERSION()) via pvMock,
        // so that inputs and the delegatecalled fuse share the same transient storage context
        pvMock.setInputs(address(erc4626SupplyFuse), inputs);

        // Act: call enterTransient via delegatecall through PlasmaVaultMock
        pvMock.enterErc4626SupplyTransient();

        // Assert: outputs stored under VERSION should contain supplied amount > 0
        bytes32[] memory outputs = pvMock.getOutputs(address(erc4626SupplyFuse));
        assertEq(outputs.length, 1, "enterTransient should set exactly one output");
        uint256 suppliedAmount = TypeConversionLib.toUint256(outputs[0]);
        assertGt(suppliedAmount, 0, "suppliedAmount from enterTransient should be greater than zero");
    }

    function test_exitTransient_hitsBranch144True_andReturnsShares() public {
            // Arrange: deploy underlying token and ERC4626 vault
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            MockERC4626 vault = new MockERC4626(underlying, "Vault", "vTKN");
    
            // Use PlasmaVaultMock so that storage context (including VERSION‑keyed transient storage)
            // and fuse execution are shared via delegatecall
            PlasmaVaultMock pvMock = new PlasmaVaultMock(address(erc4626SupplyFuse), address(0));
    
            // Grant the vault as a supported substrate in pvMock's storage for MARKET_ID = 1
            address[] memory assets = new address[](1);
            assets[0] = address(vault);
            pvMock.grantAssetsToMarket(1, assets);
    
            // Mint underlying to pvMock and deposit into the vault so that a later withdraw is possible
            underlying.mint(address(pvMock), 1e18);
            vm.prank(address(pvMock));
            underlying.approve(address(vault), 1e18);
            vm.prank(address(pvMock));
            vault.deposit(1e18, address(pvMock));
    
            // Prepare transient storage inputs for exitTransient:
            // inputs[0] = vault address, inputs[1] = amount, inputs[2] = maxSharesBurned
            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = bytes32(uint256(uint160(address(vault))));
            inputs[1] = bytes32(uint256(5e17)); // withdraw 0.5 tokens
            inputs[2] = bytes32(uint256(0));   // no maxSharesBurned limit
    
            // Set inputs under key VERSION (erc4626SupplyFuse address) in transient storage via pvMock
            pvMock.setInputs(address(erc4626SupplyFuse), inputs);
    
            // Act: call exitTransient via pvMock (delegatecall into fuse)
            pvMock.exitErc4626SupplyTransient();
    
            // Read outputs back for the same VERSION key; outputs[0] holds burned shares
            bytes32[] memory outputs = pvMock.getOutputs(address(erc4626SupplyFuse));
            uint256 burnedShares = uint256(outputs[0]);
    
            // Assert: some shares must have been burned and underlying withdrawn back to pvMock
            assertGt(burnedShares, 0, "exitTransient should burn some shares");
            uint256 underlyingBalance = underlying.balanceOf(address(pvMock));
            assertGt(underlyingBalance, 0, "exitTransient should result in underlying balance on vault mock");
        }

    function test_exit_unsupportedVault_reverts_and_hitsBranch178True() public {
            // Arrange: deploy underlying token and an ERC4626 vault
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            MockERC4626WithFee vault = new MockERC4626WithFee(underlying, "Vault", "vTKN", 0);
    
            // Note: we DO NOT grant the vault as a substrate for MARKET_ID = 1 here,
            // so PlasmaVaultConfigLib.isSubstrateAsAssetGranted(1, vault) will return false.
    
            // Prepare exit data with non‑zero amount so the initial early‑return is skipped
            Erc4626SupplyFuseExitData memory data_ = Erc4626SupplyFuseExitData({
                vault: address(vault),
                vaultAssetAmount: 1e18,
                maxSharesBurned: 0
            });
    
            // Act & Assert: calling exit should revert due to unsupported vault,
            // taking the opix-target-branch-178-True path in _exit
            vm.expectRevert();
            erc4626SupplyFuse.exit(data_);
        }
}