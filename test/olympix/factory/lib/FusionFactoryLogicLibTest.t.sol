// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {FusionFactoryLogicLibCaller} from "test/test_helpers/lib_callers/FusionFactoryLogicLibCaller.sol";

/// @dev Target: FusionFactoryLogicLibCaller (library FusionFactoryLogicLib wrapped for Olympix targeting).

import {FusionFactoryLogicLib} from "contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLibCaller} from "test/test_helpers/lib_callers/FusionFactoryStorageLibCaller.sol";
import {IPlasmaVaultGovernance} from "contracts/interfaces/IPlasmaVaultGovernance.sol";
import {IRewardsClaimManager} from "contracts/interfaces/IRewardsClaimManager.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {ContextManagerFactory} from "contracts/factory/ContextManagerFactory.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManager} from "contracts/managers/fee/FeeManager.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
contract FusionFactoryLogicLibTest is OlympixUnitTest("FusionFactoryLogicLibCaller") {
    FusionFactoryLogicLibCaller internal caller;

    function setUp() public override {
        caller = new FusionFactoryLogicLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_doClone_TargetsBranch16True_DaoFeeArrayEmptyReverts() public {
            // Arrange: minimal FusionInstance input
            FusionFactoryLogicLib.FusionInstance memory inst;
            inst.index = 0;
    
            string memory name_ = "TestVault";
            string memory symbol_ = "TVLT";
            address asset_ = address(0x7);
            uint256 daoFeePkg_ = 0; // any index, array is empty
            address admin_ = address(this);
            bool publicVault_ = true;
            uint256 cap_ = 1_000_000 ether;
    
            // Sanity: ensure DAO fee packages length is zero so library will revert with DaoFeePackagesArrayEmpty
            FusionFactoryStorageLibCaller storageCaller = new FusionFactoryStorageLibCaller();
            uint256 len = storageCaller.getDaoFeePackagesLength();
            assertEq(len, 0, "precondition: dao fee packages length should be zero");
    
            // Act + Assert: expect DaoFeePackagesArrayEmpty() from FusionFactoryLogicLib
            vm.expectRevert(FusionFactoryLogicLib.DaoFeePackagesArrayEmpty.selector);
            caller.doClone(inst, name_, symbol_, asset_, daoFeePkg_, admin_, publicVault_, cap_);
        }

    function test_setupFinalConfiguration_MinimalInstance() public {
            // Prepare a minimal FusionInstance with every externally-called dependency mocked.
            // setupFinalConfiguration performs external calls on plasmaVault, feeAccount,
            // rewardsManager, withdrawManager, feeManager, accessManager and the
            // ContextManagerFactory, so all of them need code + mocked returns.
            FusionFactoryLogicLib.FusionInstance memory inst;
            inst.plasmaVault = makeAddr("plasmaVault");
            inst.accessManager = makeAddr("accessManager");
            inst.rewardsManager = makeAddr("rewardsManager");
            inst.withdrawManager = makeAddr("withdrawManager");
            inst.priceManager = makeAddr("priceManager");

            address feeAccount = makeAddr("feeAccount");
            address feeManager = makeAddr("feeManager");
            address contextManagerFactory = makeAddr("contextManagerFactory");
            address contextManager = makeAddr("contextManager");

            // give the mocked addresses code so Solidity's extcodesize checks on calls
            // that return no data do not revert (never etch precompiles / tiny literals)
            vm.etch(inst.plasmaVault, hex"00");
            vm.etch(inst.accessManager, hex"00");
            vm.etch(inst.rewardsManager, hex"00");
            vm.etch(inst.withdrawManager, hex"00");
            vm.etch(feeAccount, hex"00");
            vm.etch(feeManager, hex"00");
            vm.etch(contextManagerFactory, hex"00");

            // plasmaVault.getPerformanceFeeData() -> feeAccount used to resolve FEE_MANAGER()
            vm.mockCall(
                inst.plasmaVault,
                abi.encodeWithSelector(IPlasmaVaultGovernance.getPerformanceFeeData.selector),
                abi.encode(PlasmaVaultStorageLib.PerformanceFeeData({feeAccount: feeAccount, feeInPercentage: 0}))
            );
            vm.mockCall(feeAccount, abi.encodeWithSignature("FEE_MANAGER()"), abi.encode(feeManager));

            // the library reads FusionFactoryStorageLib from the caller's storage (delegatecall
            // context) — store the ContextManagerFactory address in the caller at the ERC-7201 slot
            // keccak256(abi.encode(uint256(keccak256("io.ipor.fusion.factory.ContextManagerFactoryAddress")) - 1)) & ~bytes32(uint256(0xff))
            bytes32 contextManagerFactorySlot = keccak256(
                abi.encode(uint256(keccak256("io.ipor.fusion.factory.ContextManagerFactoryAddress")) - 1)
            ) & ~bytes32(uint256(0xff));
            vm.store(address(caller), contextManagerFactorySlot, bytes32(uint256(uint160(contextManagerFactory))));

            // isCreate_ == true branch -> ContextManagerFactory.create(...)
            vm.mockCall(
                contextManagerFactory,
                abi.encodeWithSelector(ContextManagerFactory.create.selector),
                abi.encode(contextManager)
            );

            // remaining wiring calls performed by setupFinalConfiguration
            vm.mockCall(
                inst.rewardsManager,
                abi.encodeWithSelector(IRewardsClaimManager.setupVestingTime.selector),
                abi.encode()
            );
            vm.mockCall(
                inst.plasmaVault,
                abi.encodeWithSelector(IPlasmaVaultGovernance.setRewardsClaimManagerAddress.selector),
                abi.encode()
            );
            vm.mockCall(
                inst.withdrawManager,
                abi.encodeWithSelector(WithdrawManager.updateWithdrawWindow.selector),
                abi.encode()
            );
            vm.mockCall(
                inst.withdrawManager,
                abi.encodeWithSelector(WithdrawManager.updatePlasmaVaultAddress.selector),
                abi.encode()
            );
            vm.mockCall(inst.plasmaVault, abi.encodeWithSelector(IPlasmaVaultGovernance.addFuses.selector), abi.encode());
            vm.mockCall(
                inst.plasmaVault,
                abi.encodeWithSelector(IPlasmaVaultGovernance.addBalanceFuse.selector),
                abi.encode()
            );
            vm.mockCall(feeManager, abi.encodeWithSelector(FeeManager.initialize.selector), abi.encode());
            vm.mockCall(
                inst.accessManager,
                abi.encodeWithSelector(IporFusionAccessManager.initialize.selector),
                abi.encode()
            );

            address admin = address(0xABCD);
            address newOwner = address(0xBEEF);
            bool publicVault = true;
            bool acceptOwnership = true;

            // Call through the wrapper to hit the opix-target-branch in setupFinalConfiguration
            FusionFactoryLogicLib.FusionInstance memory result =
                caller.setupFinalConfiguration(inst, admin, publicVault, newOwner, acceptOwnership);

            // Sanity check: function returns a struct (not reverted) and keeps index unchanged
            assertEq(result.index, inst.index, "index should remain unchanged");
            assertEq(result.feeManager, feeManager, "feeManager should be resolved from FeeAccount.FEE_MANAGER()");
            assertEq(result.contextManager, contextManager, "contextManager should come from ContextManagerFactory.create");
        }
    
}