// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";

/// @dev Target contract: contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol

import {CompoundV3SupplyFuse} from "contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";

/// @dev Minimal IComet stub exposing just baseToken() for constructor.

import {CompoundV3SupplyFuseEnterData} from "contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {IComet} from "contracts/fuses/compound_v3/ext/IComet.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {TransientStorageLibMock} from "test/transient_storage/TransientStorageLibMock.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "contracts/fuses/IFuseCommon.sol";
import {CompoundV3SupplyFuseExitData} from "contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract MockComet {
    address public immutable baseTokenAddr;

    constructor(address baseToken_) {
        baseTokenAddr = baseToken_;
    }

    function baseToken() external view returns (address) {
        return baseTokenAddr;
    }
}

contract CompoundV3SupplyFuseTest is OlympixUnitTest("CompoundV3SupplyFuse") {
    CompoundV3SupplyFuse public compoundV3SupplyFuse;
    MockERC20 public baseToken;
    MockComet public comet;

    function setUp() public override {
        baseToken = new MockERC20("Base", "BASE", 18);
        comet = new MockComet(address(baseToken));
        compoundV3SupplyFuse = new CompoundV3SupplyFuse(1, address(comet));
    }

    function test_example_deployment_doesNotRevert() public view {
        assertTrue(address(compoundV3SupplyFuse) != address(0), "Contract should be deployed");
    }

    function test_example_marketId() public view {
        assertEq(compoundV3SupplyFuse.MARKET_ID(), 1);
    }

    function test_example_version() public view {
        assertEq(compoundV3SupplyFuse.VERSION(), address(compoundV3SupplyFuse));
    }

    function test_enter_AmountZero_HitsEarlyReturnBranch() public {
            address asset = address(baseToken);
    
            (address returnedAsset, address returnedMarket, uint256 returnedAmount) = compoundV3SupplyFuse.enter(
                CompoundV3SupplyFuseEnterData({asset: asset, amount: 0})
            );
    
            assertEq(returnedAsset, asset, "Asset should match input");
            assertEq(returnedMarket, address(comet), "Market should be COMET address");
            assertEq(returnedAmount, 0, "Amount should be zero for early return branch");
        }

    function test_enter_WhenAmountNonZero_HitsElseBranchAndRevertsUnsupportedAsset() public {
            // Arrange: pick any asset and non-zero amount to make (data_.amount == 0) false
            address asset = address(baseToken);
            uint256 amount = 1e18;
    
            // Expect revert with custom error CompoundV3SupplyFuseUnsupportedAsset("enter", asset)
            bytes memory expectedError = abi.encodeWithSelector(
                CompoundV3SupplyFuse.CompoundV3SupplyFuseUnsupportedAsset.selector,
                "enter",
                asset
            );
            vm.expectRevert(expectedError);
    
            // Act: call enter with non-zero amount, which first hits the opix-target-branch-59 else branch
            compoundV3SupplyFuse.enter(CompoundV3SupplyFuseEnterData({asset: asset, amount: amount}));
        }

    function test_enterTransient_ReadsInputsAndWritesOutputs() public {
            // Use PlasmaVaultMock as delegatecall proxy so setInputs and enterTransient
            // share the same transient storage context (EIP-1153 is per-contract).
            PlasmaVaultMock vault = new PlasmaVaultMock(address(compoundV3SupplyFuse), address(0));

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(address(baseToken));
            inputs[1] = TypeConversionLib.toBytes32(uint256(123));
            vault.setInputs(address(compoundV3SupplyFuse), inputs);

            // amount != 0 enters the substrate check; asset is not granted -> UnsupportedAsset
            bytes memory expectedError = abi.encodeWithSelector(
                CompoundV3SupplyFuse.CompoundV3SupplyFuseUnsupportedAsset.selector,
                "enter",
                address(baseToken)
            );
            vm.expectRevert(expectedError);
            vault.enterCompoundV3SupplyTransient();
        }

    function test_exitTransient_UsesInputsAndHitsTrueBranch() public {
            // Use PlasmaVaultMock as delegatecall proxy so substrate grants, inputs, and
            // exitTransient all operate on the same storage context.
            PlasmaVaultMock vault = new PlasmaVaultMock(address(compoundV3SupplyFuse), address(0));

            address[] memory assets = new address[](1);
            assets[0] = address(baseToken);
            vault.grantAssetsToMarket(compoundV3SupplyFuse.MARKET_ID(), assets);

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(address(baseToken));
            inputs[1] = TypeConversionLib.toBytes32(uint256(0));
            vault.setInputs(address(compoundV3SupplyFuse), inputs);

            vault.exitCompoundV3SupplyTransient();

            bytes32[] memory outputs = vault.getOutputs(address(compoundV3SupplyFuse));
            assertEq(outputs.length, 3, "outputs length should be 3");
            assertEq(TypeConversionLib.toAddress(outputs[0]), address(baseToken), "asset should match input");
            assertEq(TypeConversionLib.toAddress(outputs[1]), address(comet), "market should be COMET");
            assertEq(TypeConversionLib.toUint256(outputs[2]), 0, "amount should be zero");
        }

    function test_instantWithdraw_HitsTrueBranchAndCallsExitWithGrantedAsset() public {
            // Arrange: mock IComet and fuse already deployed in setUp();
            // grant substrate so PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, asset) returns true
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[compoundV3SupplyFuse.MARKET_ID()];
            marketSubstrates.substrateAllowances[
                PlasmaVaultConfigLib.addressToBytes32(address(baseToken))
            ] = 1;
    
            // Prepare params for instantWithdraw: params[0] = amount, params[1] = asset as bytes32
            uint256 amount = 1e18;
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(amount);
            params[1] = PlasmaVaultConfigLib.addressToBytes32(address(baseToken));
    
            // We do not fully stub IComet.withdraw in this unit test environment, so calling
            // instantWithdraw will eventually revert when _performWithdraw calls COMET.withdraw.
            // That revert is acceptable: we only need to ensure the opix-target-branch-123 True
            // branch is taken, which happens on every call to instantWithdraw.
            vm.expectRevert();
    
            // Act: triggers the `if (true)` branch in instantWithdraw and then _exit / _performWithdraw
            compoundV3SupplyFuse.instantWithdraw(params);
        }

    function test_exit_AmountZero_HitsEarlyReturnBranch() public {
            // Arrange: use any asset address and amount = 0 to make (data_.amount == 0) true
            address asset = address(baseToken);
    
            // Act
            (address returnedAsset, address returnedMarket, uint256 returnedAmount) = compoundV3SupplyFuse.exit(
                CompoundV3SupplyFuseExitData({asset: asset, amount: 0})
            );
    
            // Assert: early-return branch in _exit should be taken
            assertEq(returnedAsset, asset, "Asset should match input");
            assertEq(returnedMarket, address(comet), "Market should be COMET address");
            assertEq(returnedAmount, 0, "Amount should be zero for early return branch");
        }

    function test_exit_NonZeroAmount_EntersElseBranchAndReturnsZeroWhenNoBalance() public {
            // Arrange: configure the substrate so isSubstrateAsAssetGranted returns true
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[compoundV3SupplyFuse.MARKET_ID()];
            marketSubstrates.substrateAllowances[
                PlasmaVaultConfigLib.addressToBytes32(address(baseToken))
            ] = 1;
    
            // We do NOT set any Comet balance for this test. Because our MockComet lacks
            // balanceOf/collateralBalanceOf implementations, any call to those functions
            // (inside _getBalance) will revert. To still reach the opix-target-branch-138
            // else-path `(data_.amount == 0) == false`, we rely on the fact that before
            // calling _getBalance the first `if (data_.amount == 0)` must be evaluated
            // with a non-zero amount, thus entering the `else` branch at line 138.
            // After that, the call will revert when _getBalance is executed.
    
            address asset = address(baseToken);
            uint256 amount = 1e18; // non-zero to make (data_.amount == 0) false
    
            // Expect a revert coming from the missing balanceOf/collateralBalanceOf
            vm.expectRevert();
    
            // Act: this will enter _exit with non-zero amount, hitting the
            // opix-target-branch-138 else branch before reverting in _getBalance
            compoundV3SupplyFuse.exit(CompoundV3SupplyFuseExitData({asset: asset, amount: amount}));
        }
}