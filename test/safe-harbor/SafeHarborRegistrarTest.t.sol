// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "../../lib/forge-std/src/Test.sol";
import {Vm} from "../../lib/forge-std/src/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {SafeHarborRegistrar} from "../../contracts/safe-harbor/SafeHarborRegistrar.sol";
import {ISafeHarborRegistrar} from "../../contracts/safe-harbor/ISafeHarborRegistrar.sol";
import {IFusionFactoryVaultCheck} from "../../contracts/safe-harbor/IFusionFactoryVaultCheck.sol";
import {
    IAgreement,
    Account as HarborAccount,
    Chain as HarborChain,
    AgreementDetails,
    ChildContractScope
} from "../../contracts/safe-harbor/ext/IAgreement.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";
import {MockAgreement} from "./mocks/MockAgreement.sol";
import {MockSafeHarborVault} from "./mocks/MockSafeHarborVault.sol";
import {MockFusionFactory} from "./mocks/MockFusionFactory.sol";
import {LegacyFactoryWithoutVaultCheck} from "./mocks/LegacyFactoryWithoutVaultCheck.sol";

/// @title SafeHarborRegistrarTest
/// @author IPOR Labs
/// @notice Exercises registrar access control and real Agreement mutation semantics.
contract SafeHarborRegistrarTest is Test {
    string private constant CHAIN_ID = "eip155:1";
    string private constant RECOVERY = "0x0000000000000000000000000000000000001234";
    string private constant OTHER_ACCOUNT = "0x0000000000000000000000000000000000009876";
    SafeHarborRegistrar private _registrar;
    MockAgreement private _agreement;
    MockFusionFactory private _factory;
    IporFusionAccessManager private _manager;
    address private _vault;
    address private _multisig;
    address private _owner;
    address private _atomist;
    address private _alpha;
    address private _stranger;

    /// @notice Deploys a real Fusion access manager with distinct actors and an empty Agreement.
    function setUp() public {
        vm.chainId(1);
        _multisig = makeAddr("multisig");
        _owner = makeAddr("vault owner");
        _atomist = makeAddr("atomist");
        _alpha = makeAddr("alpha");
        _stranger = makeAddr("stranger");
        _manager = new IporFusionAccessManager(address(this), 0);
        _manager.grantRole(Roles.OWNER_ROLE, _owner, 0);
        _manager.grantRole(Roles.ATOMIST_ROLE, _atomist, 0);
        _manager.grantRole(Roles.ALPHA_ROLE, _alpha, 0);
        _vault = address(new MockSafeHarborVault(address(_manager)));
        _factory = new MockFusionFactory();
        _agreement = new MockAgreement(address(this));
        _registrar = new SafeHarborRegistrar(_multisig, address(_agreement), address(_factory), RECOVERY);
        _agreement.transferOwnership(address(_registrar));
        _allowlist(_vault, true);
    }

    /// @notice AC1: opt-in covers exactly the vault on this chain, without child contracts.
    function testOwnerOptInAddsOnlyVaultWithNoneScopeAndEmits() public {
        assertFalse(_registrar.isParticipating(_vault));
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.ParticipationChanged(_vault, true, _owner);
        _participate(true);
        assertTrue(_registrar.isParticipating(_vault));
        AgreementDetails memory details = _details(_agreement);
        assertEq(details.chains.length, 1);
        assertEq(details.chains[0].caip2ChainId, CHAIN_ID);
        assertEq(details.chains[0].assetRecoveryAddress, RECOVERY);
        assertEq(details.chains[0].accounts.length, 1);
        assertEq(details.chains[0].accounts[0].accountAddress, Strings.toHexString(_vault));
        assertEq(uint256(details.chains[0].accounts[0].childContractScope), uint256(ChildContractScope.None));
    }

    /// @notice AC2: removing one vault preserves every unrelated account and chain.
    function testOwnerOptOutPreservesOtherAccountsAndChains() public {
        _seed(_agreement, CHAIN_ID, _single(OTHER_ACCOUNT, ChildContractScope.All), "existing recovery");
        _seed(
            _agreement,
            "eip155:8453",
            _single(Strings.toHexString(_vault), ChildContractScope.FutureOnly),
            "base recovery"
        );
        _participate(true);
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.ParticipationChanged(_vault, false, _owner);
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
        AgreementDetails memory details = _details(_agreement);
        assertEq(details.chains.length, 2);
        assertEq(details.chains[0].assetRecoveryAddress, "existing recovery");
        assertEq(details.chains[0].accounts.length, 1);
        assertEq(details.chains[0].accounts[0].accountAddress, OTHER_ACCOUNT);
        assertEq(uint256(details.chains[0].accounts[0].childContractScope), uint256(ChildContractScope.All));
        assertEq(details.chains[1].caip2ChainId, "eip155:8453");
        assertEq(details.chains[1].assetRecoveryAddress, "base recovery");
        assertEq(details.chains[1].accounts[0].accountAddress, Strings.toHexString(_vault));
        assertEq(uint256(details.chains[1].accounts[0].childContractScope), uint256(ChildContractScope.FutureOnly));
    }

    /// @notice AC2: the final vault can leave and rejoin without introducing a placeholder account.
    function testLastAccountOptOutAndRejoin() public {
        HarborAccount[] memory accounts = _single(Strings.toHexString(_vault), ChildContractScope.None);
        _seed(_agreement, CHAIN_ID, accounts, "preserved recovery");
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.AssetRecoveryAddressUpdated("preserved recovery");
        _participate(false);
        assertEq(_agreement.getChainIds().length, 0);
        assertFalse(_registrar.isParticipating(_vault));
        assertEq(_registrar.getAssetRecoveryAddress(), "preserved recovery");
        _participate(true);
        assertEq(_details(_agreement).chains[0].assetRecoveryAddress, "preserved recovery");
    }

    /// @notice AC3: atomist privileges do not confer the owner's participation decision.
    function testAtomistCannotParticipate() public {
        _assertNotOwner(_atomist);
    }

    /// @notice AC3: alpha privileges do not confer the owner's participation decision.
    function testAlphaCannotParticipate() public {
        _assertNotOwner(_alpha);
    }

    /// @notice AC3: an account without roles cannot change participation.
    function testNoRoleCannotParticipate() public {
        _assertNotOwner(_stranger);
    }

    /// @notice AC3: registrar ownership alone cannot opt a vault in.
    function testRegistrarOwnerCannotBypassVaultRole() public {
        _assertNotOwner(_multisig);
    }

    /// @notice Membership is checked afresh after a role is revoked.
    function testRevokedOwnerCannotParticipate() public {
        _participate(true);
        _manager.revokeRole(Roles.OWNER_ROLE, _owner);
        _assertNotOwner(_owner);
        assertTrue(_registrar.isParticipating(_vault));
    }

    /// @notice Every current OWNER_ROLE holder can decide, including one with an execution delay.
    function testOwnerWithExecutionDelayCanParticipate() public {
        _manager.grantRole(Roles.OWNER_ROLE, _stranger, 1 days);
        (bool member, uint32 delay) = _manager.hasRole(Roles.OWNER_ROLE, _stranger);
        assertTrue(member);
        assertEq(delay, 1 days);
        _participate(true);
        vm.prank(_stranger);
        _registrar.setParticipation(_vault, false);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice AC4: a compatible authority and OWNER_ROLE do not establish Fusion provenance.
    function testCompatibleContractWithoutProvenanceRejected() public {
        address compatible = address(new MockSafeHarborVault(address(_manager)));
        _assertNotFusionVault(compatible);
        assertFalse(_registrar.isParticipating(compatible));
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice AC4: the in-contract allowlist permits a vault that the factory does not recognize.
    function testAllowlistedVaultWithFactoryFalse() public {
        assertFalse(_factory.isFusionVault(_vault));
        assertTrue(_registrar.isManualAllowlisted(_vault));
        assertTrue(_registrar.isEligibleVault(_vault));
        _participate(true);
        assertTrue(_registrar.isParticipating(_vault));
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice AC4: future factory-recognized vaults do not require manual approval.
    function testFactoryTrueVaultWithoutAllowlist() public {
        _allowlist(_vault, false);
        _factory.setFusionVault(_vault, true);
        assertFalse(_registrar.isManualAllowlisted(_vault));
        assertTrue(_registrar.isEligibleVault(_vault));
        _participate(true);
        assertTrue(_registrar.isParticipating(_vault));
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice AC4: neither factory recognition nor allowlist approval means rejection in both directions.
    function testNeitherEligibilityPathRejectsVault() public {
        _allowlist(_vault, false);
        assertFalse(_factory.isFusionVault(_vault));
        _assertNotFusionVault(_vault);
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice AC4: allowlisted lookups and mutations make zero calls to even a reverting factory.
    function testAllowlistedVaultShortCircuitsRevertingFactory() public {
        _factory.setRevertLookup(true);
        vm.expectCall(address(_factory), abi.encodeCall(IFusionFactoryVaultCheck.isFusionVault, (_vault)), 0);
        assertTrue(_registrar.isEligibleVault(_vault));
        _participate(true);
        assertTrue(_registrar.isParticipating(_vault));
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice Factory failure is false, not eligibility and not a bubbled factory error.
    function testRevertingFactoryWithoutAllowlistRejected() public {
        _allowlist(_vault, false);
        _factory.setRevertLookup(true);
        _assertNotFusionVault(_vault);
    }

    /// @notice A zero factory is valid deployment configuration and enables manual-only operation.
    function testZeroFactoryFallsBackToAllowlist() public {
        _assertUnavailableFactory(address(0));
    }

    /// @notice A nonzero address without deployed code is treated as an unavailable factory.
    function testUndeployedFactoryFallsBackToAllowlist() public {
        assertEq(_stranger.code.length, 0);
        _assertUnavailableFactory(_stranger);
    }

    /// @notice A deployed legacy factory without the future selector cannot block manual approval.
    function testMissingFactorySelectorFallsBackToAllowlist() public {
        address legacy = address(new LegacyFactoryWithoutVaultCheck());
        assertGt(legacy.code.length, 0);
        _assertUnavailableFactory(legacy);
    }

    /// @notice Empty, short, oversized and noncanonical boolean returns fail closed without decode panics.
    function testMalformedFactoryResponseFallsBackToAllowlist() public {
        bytes[6] memory responses = [
            bytes(""),
            hex"01",
            new bytes(31),
            abi.encode(uint256(2)),
            abi.encode(type(uint256).max),
            abi.encode(uint256(1), uint256(0))
        ];
        for (uint256 i; i < responses.length; ++i) {
            _allowlist(_vault, false);
            vm.mockCall(
                address(_factory), abi.encodeCall(IFusionFactoryVaultCheck.isFusionVault, (_vault)), responses[i]
            );
            _assertNotFusionVault(_vault);
            _allowlist(_vault, true);
            assertTrue(_registrar.isEligibleVault(_vault));
            _participate(true);
            _participate(false);
            assertFalse(_registrar.isParticipating(_vault));
        }
    }

    /// @notice Factory recognition is checked for the requested vault and never cached across calls.
    function testFactoryRecognitionRevocationPreservesCoverage() public {
        _allowlist(_vault, false);
        _factory.setFusionVault(_vault, true);
        assertFalse(_registrar.isEligibleVault(_stranger));
        _participate(true);
        _factory.setFusionVault(_vault, false);
        _assertNotFusionVault(_vault);
        assertTrue(_registrar.isParticipating(_vault));
        _factory.setFusionVault(_vault, true);
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice AC5: allowlist changes are owner-only, idempotent, emitted, and do not mutate Agreement state.
    function testManualAllowlistEventsAndIdempotence() public {
        bytes memory originalAgreement = _agreementData();
        bool[4] memory choices = [true, true, false, false];
        for (uint256 i; i < choices.length; ++i) {
            vm.expectEmit(false, false, false, true, address(_registrar));
            emit ISafeHarborRegistrar.ManualAllowlistUpdated(_vault, choices[i]);
            _allowlist(_vault, choices[i]);
            assertEq(_registrar.isManualAllowlisted(_vault), choices[i]);
            assertEq(_registrar.isEligibleVault(_vault), choices[i]);
            assertFalse(_registrar.isManualAllowlisted(_stranger));
            assertEq(_agreementData(), originalAgreement);
        }
    }

    /// @notice Batch updates share the single-entry mapping and emit exactly one event for every input.
    function testManualAllowlistBatchEnableAndDisable() public {
        address[] memory vaults = _batchAddresses();
        _allowlist(_vault, false);
        bytes memory originalAgreement = _agreementData();
        bool[2] memory choices = [true, false];
        for (uint256 i; i < choices.length; ++i) {
            vm.recordLogs();
            vm.prank(_multisig);
            _registrar.setManualAllowlistBatch(vaults, choices[i]);
            _assertAllowlistEvents(vaults, choices[i]);
            for (uint256 j; j < vaults.length; ++j) {
                assertEq(_registrar.isManualAllowlisted(vaults[j]), choices[i]);
                assertEq(_registrar.isEligibleVault(vaults[j]), choices[i]);
            }
            assertEq(_agreementData(), originalAgreement);
        }
        _allowlist(_stranger, true);
        assertTrue(_registrar.isManualAllowlisted(_stranger));
        assertFalse(_registrar.isManualAllowlisted(_vault));
    }

    /// @notice Empty batches revert with WrongValue for either flag and cannot change existing entries.
    function testManualAllowlistBatchEmptyRejected() public {
        address[] memory empty = new address[](0);
        vm.startPrank(_multisig);
        vm.expectRevert(Errors.WrongValue.selector);
        _registrar.setManualAllowlistBatch(empty, true);
        vm.expectRevert(Errors.WrongValue.selector);
        _registrar.setManualAllowlistBatch(empty, false);
        vm.stopPrank();
        assertTrue(_registrar.isManualAllowlisted(_vault));
        assertFalse(_registrar.isManualAllowlisted(_stranger));
    }

    /// @notice A zero at any batch position leaves every entry unchanged for both enable and disable operations.
    function testManualAllowlistBatchZeroAddressIsAtomic() public {
        bytes memory originalAgreement = _agreementData();
        bool[2] memory choices = [true, false];
        for (uint256 i; i < choices.length; ++i) {
            address[] memory valid = _batchAddresses();
            for (uint256 j; j < valid.length; ++j) {
                _allowlist(valid[j], !choices[i]);
            }
            for (uint256 zeroIndex; zeroIndex < valid.length; ++zeroIndex) {
                address[] memory invalid = _batchAddresses();
                invalid[zeroIndex] = address(0);
                vm.expectRevert(Errors.WrongAddress.selector);
                vm.prank(_multisig);
                _registrar.setManualAllowlistBatch(invalid, choices[i]);
                for (uint256 j; j < valid.length; ++j) {
                    assertEq(_registrar.isManualAllowlisted(valid[j]), !choices[i]);
                }
                assertFalse(_registrar.isManualAllowlisted(address(0)));
                assertEq(_agreementData(), originalAgreement);
            }
        }
    }

    /// @notice Duplicate batch inputs are idempotent but still emit once per input, including repeated calls.
    function testManualAllowlistBatchDuplicatesAndEvents() public {
        address[] memory vaults = _batchAddresses();
        vaults[2] = _vault;
        bool[4] memory choices = [true, true, false, false];
        for (uint256 i; i < choices.length; ++i) {
            vm.recordLogs();
            vm.prank(_multisig);
            _registrar.setManualAllowlistBatch(vaults, choices[i]);
            _assertAllowlistEvents(vaults, choices[i]);
            assertEq(_registrar.isManualAllowlisted(_vault), choices[i]);
            assertEq(_registrar.isManualAllowlisted(_stranger), choices[i]);
            assertFalse(_registrar.isManualAllowlisted(_atomist));
        }
    }

    /// @notice Batch revocation preserves legal coverage and cannot prevent the multisig's forced removal.
    function testManualAllowlistBatchRevocationPreservesCoverage() public {
        _participate(true);
        bytes memory originalAgreement = _agreementData();
        vm.prank(_multisig);
        _registrar.setManualAllowlistBatch(_batchAddresses(), false);
        _assertNotFusionVault(_vault);
        assertTrue(_registrar.isParticipating(_vault));
        assertEq(_agreementData(), originalAgreement);
        vm.prank(_multisig);
        _registrar.forceRemove(_vault);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice Batch setters reject non-owners before validating either nonempty or empty input.
    function testManualAllowlistBatchRejectsNonOwner() public {
        address[] memory vaults = _batchAddresses();
        address[] memory empty = new address[](0);
        address[3] memory callers = [_owner, _stranger, _atomist];
        for (uint256 i; i < callers.length; ++i) {
            bytes memory failure = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(failure);
            _registrar.setManualAllowlistBatch(vaults, true);
            vm.expectRevert(failure);
            _registrar.setManualAllowlistBatch(vaults, false);
            vm.expectRevert(failure);
            _registrar.setManualAllowlistBatch(empty, true);
            vm.stopPrank();
        }
        assertTrue(_registrar.isManualAllowlisted(_vault));
        assertFalse(_registrar.isManualAllowlisted(_stranger));
        assertFalse(_registrar.isManualAllowlisted(_atomist));
    }

    /// @notice Revoking allowlist eligibility preserves legal coverage until owner-only forced removal.
    function testForceRemoveAfterAllowlistRevocation() public {
        _participate(true);
        _allowlist(_vault, false);
        _assertNotFusionVault(_vault);
        assertTrue(_registrar.isParticipating(_vault));
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.ParticipationChanged(_vault, false, _multisig);
        vm.prank(_multisig);
        _registrar.forceRemove(_vault);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice Eligibility precedes authority, vault-role and Agreement-ownership checks.
    function testEligibilityCheckPrecedesOtherChecks() public {
        _allowlist(_vault, false);
        vm.prank(_multisig);
        _registrar.transferAgreementOwnership(_stranger);
        _assertNotFusionVault(_vault);
        _assertNotFusionVault(_stranger);
        _assertNotFusionVault(address(0));
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotFusionVault.selector, _vault));
        vm.prank(_atomist);
        _registrar.setParticipation(_vault, true);
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice An authority getter returning zero yields the explicit NoAccessManager error.
    function testZeroAuthorityRejected() public {
        address noManager = address(new MockSafeHarborVault(address(0)));
        _allowlist(noManager, true);
        bytes memory failure = abi.encodeWithSelector(ISafeHarborRegistrar.NoAccessManager.selector, noManager);
        vm.expectRevert(failure);
        vm.prank(_owner);
        _registrar.setParticipation(noManager, true);
        vm.expectRevert(failure);
        vm.prank(_owner);
        _registrar.setParticipation(noManager, false);
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice Addresses without an authority getter cannot reach participation updates.
    function testMissingAuthoritySelectorAndEoaRevert() public {
        address[2] memory invalid = [address(_agreement), _stranger];
        for (uint256 i; i < invalid.length; ++i) {
            _allowlist(invalid[i], true);
            vm.expectRevert();
            vm.prank(_owner);
            _registrar.setParticipation(invalid[i], true);
            vm.expectRevert();
            vm.prank(_owner);
            _registrar.setParticipation(invalid[i], false);
        }
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice A nonzero authority without a compatible hasRole API bubbles its raw revert.
    function testMalformedAccessManagerReverts() public {
        address malformed = address(new MockSafeHarborVault(address(_agreement)));
        _allowlist(malformed, true);
        vm.expectRevert();
        vm.prank(_owner);
        _registrar.setParticipation(malformed, true);
        vm.expectRevert();
        vm.prank(_owner);
        _registrar.setParticipation(malformed, false);
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice An authority getter's original custom error is preserved in both participation directions.
    function testAuthorityReadFailureBubbles() public {
        bytes memory failure = abi.encodeWithSelector(MockAgreement.WriteRejected.selector);
        vm.mockCallRevert(_vault, abi.encodeCall(IAccessManaged.authority, ()), failure);
        vm.expectRevert(failure);
        _participate(true);
        vm.expectRevert(failure);
        _participate(false);
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice A hasRole failure preserves its original custom error and cannot mutate existing coverage.
    function testRoleReadFailureBubbles() public {
        _participate(true);
        bytes memory failure = abi.encodeWithSelector(MockAgreement.WriteRejected.selector);
        vm.mockCallRevert(
            address(_manager), abi.encodeCall(IAccessManager.hasRole, (Roles.OWNER_ROLE, _owner)), failure
        );
        vm.expectRevert(failure);
        _participate(true);
        vm.expectRevert(failure);
        _participate(false);
        assertTrue(_registrar.isParticipating(_vault));
        assertEq(_agreement.getAccountCount(CHAIN_ID), 1);
    }

    /// @notice OWNER_ROLE membership on one vault does not authorize participation for a different manager.
    function testOwnerOfAnotherVaultCannotParticipate() public {
        IporFusionAccessManager otherManager = new IporFusionAccessManager(address(this), 0);
        otherManager.grantRole(Roles.OWNER_ROLE, _stranger, 0);
        address otherVault = address(new MockSafeHarborVault(address(otherManager)));
        _allowlist(otherVault, true);
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotVaultOwner.selector, otherVault, _owner));
        vm.prank(_owner);
        _registrar.setParticipation(otherVault, true);
        vm.prank(_stranger);
        _registrar.setParticipation(otherVault, true);
        assertTrue(_registrar.isParticipating(otherVault));
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice The multisig can remove imported coverage even if the account has no access-manager getter.
    function testForceRemoveWithoutAccessManager() public {
        _seed(_agreement, CHAIN_ID, _single(Strings.toHexString(_stranger), ChildContractScope.None), RECOVERY);
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.ParticipationChanged(_stranger, false, _multisig);
        vm.prank(_multisig);
        _registrar.forceRemove(_stranger);
        assertFalse(_registrar.isParticipating(_stranger));
    }

    /// @notice AC5: each administration entry point rejects non-owners, including vault owners.
    function testAdminOperationsRejectNonOwner() public {
        _participate(true);
        address[2] memory callers = [_owner, _stranger];
        for (uint256 i; i < callers.length; ++i) {
            bytes memory failure = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, callers[i]);
            vm.startPrank(callers[i]);
            vm.expectRevert(failure);
            _registrar.forceRemove(_vault);
            vm.expectRevert(failure);
            _registrar.setManualAllowlist(_vault, false);
            vm.expectRevert(failure);
            _registrar.setManualAllowlist(_stranger, true);
            vm.expectRevert(failure);
            _registrar.setAgreement(address(_agreement));
            vm.expectRevert(failure);
            _registrar.transferAgreementOwnership(callers[i]);
            vm.expectRevert(failure);
            _registrar.setAssetRecoveryAddress("new recovery");
            vm.expectRevert(failure);
            _registrar.transferOwnership(callers[i]);
            vm.stopPrank();
        }
        assertTrue(_registrar.isParticipating(_vault));
    }

    /// @notice AC5: multisig removal emits its own caller even without vault ownership.
    function testForceRemove() public {
        _participate(true);
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.ParticipationChanged(_vault, false, _multisig);
        vm.prank(_multisig);
        _registrar.forceRemove(_vault);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice Forced removal also rejects an absent account.
    function testForceRemoveNonParticipantReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotParticipating.selector, _vault));
        vm.prank(_multisig);
        _registrar.forceRemove(_vault);
    }

    /// @notice AC6: a second opt-in fails without creating duplicate coverage.
    function testAlreadyParticipating() public {
        _participate(true);
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.AlreadyParticipating.selector, _vault));
        _participate(true);
        assertEq(_details(_agreement).chains[0].accounts.length, 1);
    }

    /// @notice AC6: opting out without participation fails with the explicit error.
    function testNotParticipating() public {
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotParticipating.selector, _vault));
        _participate(false);
        _seed(_agreement, CHAIN_ID, _single(OTHER_ACCOUNT, ChildContractScope.None), RECOVERY);
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotParticipating.selector, _vault));
        _participate(false);
    }

    /// @notice Existing mixed-case addresses count as participating and are removed by exact string.
    function testImportedMixedCaseAddress() public {
        _seed(_agreement, CHAIN_ID, _single(_upperHex(Strings.toHexString(_vault)), ChildContractScope.All), RECOVERY);
        assertTrue(_registrar.isParticipating(_vault));
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.AlreadyParticipating.selector, _vault));
        _participate(true);
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice Imported uppercase 0X prefixes match the vault and are removed using the original string.
    function testImportedUppercasePrefix() public {
        bytes memory imported = bytes(_upperHex(Strings.toHexString(_vault)));
        imported[1] = "X";
        HarborAccount[] memory accounts = new HarborAccount[](2);
        accounts[0] = HarborAccount(string(imported), ChildContractScope.All);
        accounts[1] = HarborAccount(OTHER_ACCOUNT, ChildContractScope.None);
        _seed(_agreement, CHAIN_ID, accounts, RECOVERY);
        assertTrue(_registrar.isParticipating(_vault));
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.AlreadyParticipating.selector, _vault));
        _participate(true);
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
        assertEq(_agreement.getAccountCount(CHAIN_ID), 1);
        (string memory remaining,) = _agreement.getAccount(CHAIN_ID, 0);
        assertEq(remaining, OTHER_ACCOUNT);
    }

    /// @notice AC2/6: opt-out removes every imported duplicate and retains unrelated scope.
    function testImportedDuplicateRemoval() public {
        HarborAccount[] memory accounts = new HarborAccount[](4);
        accounts[0] = HarborAccount(Strings.toHexString(_vault), ChildContractScope.None);
        accounts[1] = HarborAccount(OTHER_ACCOUNT, ChildContractScope.All);
        accounts[2] = HarborAccount(_upperHex(Strings.toHexString(_vault)), ChildContractScope.ExistingOnly);
        accounts[3] = accounts[0];
        _seed(_agreement, CHAIN_ID, accounts, RECOVERY);
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
        HarborAccount[] memory remaining = _details(_agreement).chains[0].accounts;
        assertEq(remaining.length, 1);
        assertEq(remaining[0].accountAddress, OTHER_ACCOUNT);
        assertEq(uint256(remaining[0].childContractScope), uint256(ChildContractScope.All));
    }

    /// @notice A chain containing only duplicate vault entries can be removed completely.
    function testImportedDuplicatesOnlyRemoveChain() public {
        HarborAccount[] memory accounts = new HarborAccount[](2);
        accounts[0] = HarborAccount(Strings.toHexString(_vault), ChildContractScope.None);
        accounts[1] = HarborAccount(_upperHex(Strings.toHexString(_vault)), ChildContractScope.All);
        _seed(_agreement, CHAIN_ID, accounts, "duplicate recovery");
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
        assertEq(_agreement.getChainIds().length, 0);
        _participate(true);
        assertEq(_details(_agreement).chains[0].accounts.length, 1);
        assertEq(_details(_agreement).chains[0].assetRecoveryAddress, "duplicate recovery");
    }

    /// @notice A vault covered only on another chain remains eligible to opt in here.
    function testOtherChainCoverageDoesNotCountAsParticipation() public {
        _seed(_agreement, "eip155:8453", _single(Strings.toHexString(_vault), ChildContractScope.All), RECOVERY);
        assertFalse(_registrar.isParticipating(_vault));
        _participate(true);
        assertEq(_agreement.getChainIds().length, 2);
        _participate(false);
        assertEq(_agreement.getChainIds().length, 1);
        assertEq(_agreement.getChainIds()[0], "eip155:8453");
    }

    /// @notice Replacement reads new Agreement state and does not migrate existing participation.
    function testSetAgreementDoesNotMigrate() public {
        _participate(true);
        MockAgreement replacement = new MockAgreement(address(this));
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.AgreementUpdated(address(_agreement), address(replacement));
        vm.prank(_multisig);
        _registrar.setAgreement(address(replacement));
        assertEq(_registrar.getAgreement(), address(replacement));
        assertFalse(_registrar.isParticipating(_vault));
        assertEq(_details(_agreement).chains[0].accounts.length, 1);
        replacement.transferOwnership(address(_registrar));
        _participate(true);
        assertEq(_details(replacement).chains[0].accounts.length, 1);
        assertEq(_details(_agreement).chains[0].accounts.length, 1);
    }

    /// @notice Replacement can import existing coverage without requiring a new opt-in.
    function testSetAgreementReadsImportedParticipation() public {
        MockAgreement replacement = new MockAgreement(address(this));
        _seed(replacement, CHAIN_ID, _single(Strings.toHexString(_vault), ChildContractScope.None), RECOVERY);
        vm.prank(_multisig);
        _registrar.setAgreement(address(replacement));
        assertTrue(_registrar.isParticipating(_vault));
    }

    /// @notice Immediate Agreement ownership transfer freezes mutations while reads remain truthful.
    function testTransferAgreementOwnership() public {
        _participate(true);
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.AgreementOwnershipTransferred(address(_agreement), _stranger);
        vm.prank(_multisig);
        _registrar.transferAgreementOwnership(_stranger);
        assertEq(_agreement.owner(), _stranger);
        assertTrue(_registrar.isParticipating(_vault));
        bytes memory failure = abi.encodeWithSelector(
            ISafeHarborRegistrar.AgreementNotOwnedByRegistrar.selector, address(_agreement), _stranger
        );
        vm.expectRevert(failure);
        _participate(false);
        vm.expectRevert(failure);
        _participate(true);
        vm.expectRevert(failure);
        vm.prank(_multisig);
        _registrar.forceRemove(_vault);
        vm.prank(_stranger);
        _agreement.transferOwnership(address(_registrar));
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
    }

    /// @notice Constructor permits ownership bootstrap, but opt-in waits for the actual handover.
    function testAgreementNotYetOwnedRejectsOptIn() public {
        MockAgreement pending = new MockAgreement(_multisig);
        vm.prank(_multisig);
        _registrar.setAgreement(address(pending));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISafeHarborRegistrar.AgreementNotOwnedByRegistrar.selector, address(pending), _multisig
            )
        );
        _participate(true);
    }

    /// @notice Registrar ownership changes only after the pending owner accepts.
    function testRegistrarOwnershipTwoStep() public {
        vm.prank(_multisig);
        _registrar.transferOwnership(_stranger);
        assertEq(_registrar.owner(), _multisig);
        assertEq(_registrar.pendingOwner(), _stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _owner));
        vm.prank(_owner);
        _registrar.acceptOwnership();
        vm.prank(_stranger);
        _registrar.acceptOwnership();
        assertEq(_registrar.owner(), _stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _multisig));
        vm.prank(_multisig);
        _registrar.setManualAllowlist(_vault, false);
        vm.prank(_stranger);
        _registrar.setManualAllowlist(_vault, false);
        assertFalse(_registrar.isManualAllowlisted(_vault));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _multisig));
        vm.prank(_multisig);
        _registrar.setAssetRecoveryAddress("new recovery");
        vm.prank(_stranger);
        _registrar.setAssetRecoveryAddress("new recovery");
        assertEq(_registrar.getAssetRecoveryAddress(), "new recovery");
    }

    /// @notice Registrar ownership cannot be abandoned while it administers the Agreement.
    function testRenounceOwnershipDisabled() public {
        vm.expectRevert(ISafeHarborRegistrar.RenounceOwnershipDisabled.selector);
        vm.prank(_multisig);
        _registrar.renounceOwnership();
        assertEq(_registrar.owner(), _multisig);
    }

    /// @notice Getter values expose deployment configuration and freeze the deployment chain id.
    function testConfigurationGettersAndDeploymentChainId() public {
        assertEq(_registrar.owner(), _multisig);
        assertEq(_registrar.getAgreement(), address(_agreement));
        assertEq(_registrar.getFusionFactory(), address(_factory));
        assertEq(_registrar.getAssetRecoveryAddress(), RECOVERY);
        assertEq(_registrar.getCaip2ChainId(), CHAIN_ID);
        vm.chainId(8453);
        assertEq(_registrar.getCaip2ChainId(), CHAIN_ID);
        SafeHarborRegistrar base = new SafeHarborRegistrar(_multisig, address(_agreement), address(_factory), RECOVERY);
        assertEq(base.getCaip2ChainId(), "eip155:8453");
    }

    /// @notice Recovery configuration only affects new chains, leaving an existing chain unchanged.
    function testSetAssetRecoveryAddress() public {
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.AssetRecoveryAddressUpdated("configured recovery");
        vm.prank(_multisig);
        _registrar.setAssetRecoveryAddress("configured recovery");
        _participate(true);
        assertEq(_details(_agreement).chains[0].assetRecoveryAddress, "configured recovery");
        vm.prank(_multisig);
        _registrar.setAssetRecoveryAddress("future recovery");
        assertEq(_registrar.getAssetRecoveryAddress(), "future recovery");
        assertEq(_details(_agreement).chains[0].assetRecoveryAddress, "configured recovery");
    }

    /// @notice Last opt-out preserves authoritative recovery; a setter while empty changes the next entry.
    function testAssetRecoveryAddressPrecedence() public {
        _seed(_agreement, CHAIN_ID, _single(Strings.toHexString(_vault), ChildContractScope.None), "preserved");
        vm.prank(_multisig);
        _registrar.setAssetRecoveryAddress("future");
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.AssetRecoveryAddressUpdated("preserved");
        _participate(false);
        assertEq(_registrar.getAssetRecoveryAddress(), "preserved");
        _participate(true);
        assertEq(_agreement.getRecovery(CHAIN_ID), "preserved");
        _participate(false);
        vm.prank(_multisig);
        _registrar.setAssetRecoveryAddress("future");
        _participate(true);
        assertEq(_agreement.getRecovery(CHAIN_ID), "future");
    }

    /// @notice Invalid constructor addresses and empty recovery metadata are rejected explicitly.
    function testConstructorRejectsInvalidConfiguration() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SafeHarborRegistrar(address(0), address(_agreement), address(_factory), RECOVERY);
        vm.expectRevert(Errors.WrongAddress.selector);
        new SafeHarborRegistrar(_multisig, address(0), address(_factory), RECOVERY);
        vm.expectRevert(ISafeHarborRegistrar.EmptyAssetRecoveryAddress.selector);
        new SafeHarborRegistrar(_multisig, address(_agreement), address(_factory), "");
    }

    /// @notice Administrative setters reject zero addresses and empty recovery metadata.
    function testAdminRejectsInvalidConfiguration() public {
        vm.startPrank(_multisig);
        vm.expectRevert(Errors.WrongAddress.selector);
        _registrar.setManualAllowlist(address(0), true);
        vm.expectRevert(Errors.WrongAddress.selector);
        _registrar.setManualAllowlist(address(0), false);
        vm.expectRevert(Errors.WrongAddress.selector);
        _registrar.setAgreement(address(0));
        vm.expectRevert(Errors.WrongAddress.selector);
        _registrar.transferAgreementOwnership(address(0));
        vm.expectRevert(ISafeHarborRegistrar.EmptyAssetRecoveryAddress.selector);
        _registrar.setAssetRecoveryAddress("");
        vm.stopPrank();
    }

    /// @notice Failed Agreement writes roll back both external coverage and cached recovery metadata.
    function testAgreementWriteFailureIsAtomic() public {
        _agreement.setRejectWrites(true);
        vm.expectRevert(MockAgreement.WriteRejected.selector);
        _participate(true);
        assertFalse(_registrar.isParticipating(_vault));
        assertEq(_agreement.getChainIds().length, 0);
        _agreement.setRejectWrites(false);
        _seed(_agreement, CHAIN_ID, _single(Strings.toHexString(_vault), ChildContractScope.None), "uncached recovery");
        _agreement.setRejectWrites(true);
        vm.expectRevert(MockAgreement.WriteRejected.selector);
        _participate(false);
        assertTrue(_registrar.isParticipating(_vault));
        assertEq(_registrar.getAssetRecoveryAddress(), RECOVERY);
        assertEq(_details(_agreement).chains[0].assetRecoveryAddress, "uncached recovery");
    }

    /// @notice Failed existing-chain appends and partial removals leave every Agreement byte unchanged.
    function testExistingChainWriteFailuresAreAtomic() public {
        _seed(_agreement, CHAIN_ID, _single(OTHER_ACCOUNT, ChildContractScope.All), "authoritative recovery");
        bytes memory beforeAdd = _agreementData();
        _agreement.setRejectWrites(true);
        vm.expectRevert(MockAgreement.WriteRejected.selector);
        _participate(true);
        assertEq(_agreementData(), beforeAdd);
        assertFalse(_registrar.isParticipating(_vault));
        assertEq(_registrar.getAssetRecoveryAddress(), RECOVERY);

        _agreement.setRejectWrites(false);
        _participate(true);
        bytes memory beforeRemove = _agreementData();
        _agreement.setRejectWrites(true);
        vm.expectRevert(MockAgreement.WriteRejected.selector);
        _participate(false);
        assertEq(_agreementData(), beforeRemove);
        assertTrue(_registrar.isParticipating(_vault));
        assertEq(_agreement.getAccountCount(CHAIN_ID), 2);
        assertEq(_registrar.getAssetRecoveryAddress(), RECOVERY);
    }

    /// @notice Fuzzed allowlisted contract addresses survive a complete round trip without duplicates.
    /// @param vault_ Arbitrary address with deployed vault-stub code.
    function testFuzzRoundTrip(address vault_) public {
        vm.assume(vault_ != address(0));
        vm.assume(vault_.code.length == 0);
        vm.assume(uint160(vault_) > 0xffff);
        // The stub's access-manager address is immutable and therefore embedded in the copied runtime code.
        vm.etch(vault_, _vault.code);
        _allowlist(vault_, true);
        vm.prank(_owner);
        _registrar.setParticipation(vault_, true);
        assertTrue(_registrar.isParticipating(vault_));
        assertEq(_details(_agreement).chains[0].accounts[0].accountAddress, Strings.toHexString(vault_));
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.AlreadyParticipating.selector, vault_));
        vm.prank(_owner);
        _registrar.setParticipation(vault_, true);
        vm.prank(_owner);
        _registrar.setParticipation(vault_, false);
        assertFalse(_registrar.isParticipating(vault_));
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice The custom reader handles variable ABI offsets and removes every matching imported entry.
    /// @param recoveryLength_ Variable dynamic string length, including multiple ABI words.
    /// @param duplicateCount_ Number of imported matching entries.
    /// @param seed_ Bytes used as an unrelated non-address account string.
    function testFuzzImportedAgreementLayout(uint16 recoveryLength_, uint8 duplicateCount_, bytes32 seed_) public {
        uint256 count = bound(duplicateCount_, 1, 6);
        string memory recovery = string(new bytes(bound(recoveryLength_, 1, 160)));
        _seed(_agreement, "eip155:8453", _single(OTHER_ACCOUNT, ChildContractScope.All), "other recovery");
        HarborAccount[] memory accounts = new HarborAccount[](count + 1);
        accounts[0] = HarborAccount(string(abi.encodePacked(seed_)), ChildContractScope.FutureOnly);
        for (uint256 i; i < count; ++i) {
            accounts[i + 1] = HarborAccount(
                i % 2 == 0 ? Strings.toHexString(_vault) : _upperHex(Strings.toHexString(_vault)),
                ChildContractScope.None
            );
        }
        _seed(_agreement, CHAIN_ID, accounts, recovery);
        assertTrue(_registrar.isParticipating(_vault));
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
        assertEq(_agreement.getAccountCount(CHAIN_ID), 1);
        (string memory remaining, uint256 scope) = _agreement.getAccount(CHAIN_ID, 0);
        assertEq(bytes(remaining), abi.encodePacked(seed_));
        assertEq(scope, uint256(ChildContractScope.FutureOnly));
        assertEq(_agreement.getRecovery(CHAIN_ID), recovery);
        assertEq(_agreement.getAccountCount("eip155:8453"), 1);
    }

    /// @notice Missing or out-of-bounds Agreement return data yields the reader's explicit error.
    function testMalformedAgreementDataRejected() public {
        bytes memory callData = abi.encodeCall(IAgreement.getDetails, ());
        vm.mockCall(address(_agreement), callData, hex"00");
        vm.expectRevert(ISafeHarborRegistrar.MalformedAgreementData.selector);
        _registrar.isParticipating(_vault);
        vm.mockCall(address(_agreement), callData, abi.encode(uint256(0x100)));
        vm.expectRevert(ISafeHarborRegistrar.MalformedAgreementData.selector);
        _participate(true);
        assertEq(_agreement.getChainIds().length, 0);
    }

    /// @notice Every traversed ABI offset, length and array count rejects maximal values before allocation or copy.
    function testMalformedAgreementNestedWordsRejected() public {
        _participate(true);
        bytes memory original = _agreementData();
        uint256[13] memory positions = _layoutWordPositions(original);
        for (uint256 i; i < positions.length; ++i) {
            bytes memory corrupted = bytes.concat(original);
            _writeWord(corrupted, positions[i], type(uint256).max);
            vm.mockCall(address(_agreement), abi.encodeCall(IAgreement.getDetails, ()), corrupted);
            vm.expectRevert(ISafeHarborRegistrar.MalformedAgreementData.selector);
            _registrar.isParticipating(_vault);
            vm.expectRevert(ISafeHarborRegistrar.MalformedAgreementData.selector);
            _participate(false);
            vm.expectRevert(ISafeHarborRegistrar.MalformedAgreementData.selector);
            vm.prank(_multisig);
            _registrar.forceRemove(_vault);
        }
        vm.clearMockedCalls();
        assertEq(_agreementData(), original);
        assertEq(_registrar.getAssetRecoveryAddress(), RECOVERY);
    }

    /// @notice A truncated trailing account string is rejected before copying its bytes.
    function testMalformedAgreementAccountTailRejected() public {
        _participate(true);
        bytes memory original = _agreementData();
        uint256[13] memory positions = _layoutWordPositions(original);
        bytes memory accountAddress = bytes(Strings.toHexString(_vault));
        bytes memory shortTail = new bytes(accountAddress.length - 1);
        for (uint256 i; i < shortTail.length; ++i) {
            shortTail[i] = accountAddress[i];
        }
        // Keep chain-id and recovery reads valid; only the account's relocated string lacks its final byte.
        bytes memory truncated = bytes.concat(original, abi.encode(accountAddress.length), shortTail);
        _writeWord(truncated, positions[11], original.length - positions[11]);
        vm.mockCall(address(_agreement), abi.encodeCall(IAgreement.getDetails, ()), truncated);
        vm.expectRevert(ISafeHarborRegistrar.MalformedAgreementData.selector);
        _registrar.isParticipating(_vault);
        vm.expectRevert(ISafeHarborRegistrar.MalformedAgreementData.selector);
        _participate(false);
        vm.clearMockedCalls();
        assertEq(_agreementData(), original);
    }

    /// @notice A failed Agreement read bubbles its original revert instead of reporting nonparticipation.
    function testAgreementReadFailureBubbles() public {
        vm.mockCallRevert(
            address(_agreement),
            abi.encodeCall(IAgreement.getDetails, ()),
            abi.encodeWithSelector(MockAgreement.WriteRejected.selector)
        );
        vm.expectRevert(MockAgreement.WriteRejected.selector);
        _registrar.isParticipating(_vault);
        vm.expectRevert(MockAgreement.WriteRejected.selector);
        _participate(true);
    }

    function _batchAddresses() private view returns (address[] memory vaults_) {
        vaults_ = new address[](3);
        vaults_[0] = _vault;
        vaults_[1] = _stranger;
        vaults_[2] = _atomist;
    }

    function _assertAllowlistEvents(address[] memory vaults_, bool allowed_) private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, vaults_.length);
        for (uint256 i; i < vaults_.length; ++i) {
            assertEq(logs[i].emitter, address(_registrar));
            assertEq(logs[i].topics.length, 1);
            assertEq(logs[i].topics[0], ISafeHarborRegistrar.ManualAllowlistUpdated.selector);
            assertEq(logs[i].data, abi.encode(vaults_[i], allowed_));
        }
    }

    function _allowlist(address vault_, bool allowed_) private {
        vm.prank(_multisig);
        _registrar.setManualAllowlist(vault_, allowed_);
    }

    function _assertNotFusionVault(address vault_) private {
        assertFalse(_registrar.isEligibleVault(vault_));
        bytes memory failure = abi.encodeWithSelector(ISafeHarborRegistrar.NotFusionVault.selector, vault_);
        vm.expectRevert(failure);
        vm.prank(_owner);
        _registrar.setParticipation(vault_, true);
        vm.expectRevert(failure);
        vm.prank(_owner);
        _registrar.setParticipation(vault_, false);
    }

    function _assertUnavailableFactory(address factory_) private {
        _agreement = new MockAgreement(address(this));
        _registrar = new SafeHarborRegistrar(_multisig, address(_agreement), factory_, RECOVERY);
        _agreement.transferOwnership(address(_registrar));
        assertEq(_registrar.getFusionFactory(), factory_);
        _assertNotFusionVault(_vault);
        _allowlist(_vault, true);
        assertTrue(_registrar.isEligibleVault(_vault));
        _participate(true);
        assertTrue(_registrar.isParticipating(_vault));
        _participate(false);
        assertFalse(_registrar.isParticipating(_vault));
    }

    function _participate(bool enabled_) private {
        vm.prank(_owner);
        _registrar.setParticipation(_vault, enabled_);
    }

    function _agreementData() private view returns (bytes memory data_) {
        bool success;
        (success, data_) = address(_agreement).staticcall(abi.encodeCall(IAgreement.getDetails, ()));
        assertTrue(success);
    }

    // Locate all offset/length words traversed by the reader in a valid one-chain, one-account fixture.
    function _layoutWordPositions(bytes memory data_) private pure returns (uint256[13] memory positions_) {
        uint256 details = _readWord(data_, 0);
        uint256 chains = details + _readWord(data_, details + 0x40);
        uint256 chain = chains + 0x20 + _readWord(data_, chains + 0x20);
        uint256 accounts = chain + _readWord(data_, chain + 0x20);
        uint256 account = accounts + 0x20 + _readWord(data_, accounts + 0x20);
        positions_ = [
            uint256(0),
            details + 0x40,
            chains,
            chains + 0x20,
            chain,
            chain + 0x20,
            chain + 0x40,
            chain + _readWord(data_, chain + 0x40),
            chain + _readWord(data_, chain),
            accounts,
            accounts + 0x20,
            account,
            account + _readWord(data_, account)
        ];
    }

    function _readWord(bytes memory data_, uint256 offset_) private pure returns (uint256 word_) {
        assembly ("memory-safe") {
            word_ := mload(add(add(data_, 0x20), offset_))
        }
    }

    function _writeWord(bytes memory data_, uint256 offset_, uint256 value_) private pure {
        assembly ("memory-safe") {
            mstore(add(add(data_, 0x20), offset_), value_)
        }
    }

    // Flat external getters avoid solc's legacy-codegen stack limit for decoding AgreementDetails.
    function _details(MockAgreement agreement_) private view returns (AgreementDetails memory details_) {
        string[] memory ids = agreement_.getChainIds();
        details_.chains = new HarborChain[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            HarborAccount[] memory accounts = new HarborAccount[](agreement_.getAccountCount(ids[i]));
            for (uint256 j; j < accounts.length; ++j) {
                (string memory accountAddress, uint256 scope) = agreement_.getAccount(ids[i], j);
                accounts[j] = HarborAccount(accountAddress, ChildContractScope(scope));
            }
            details_.chains[i] = HarborChain(agreement_.getRecovery(ids[i]), accounts, ids[i]);
        }
    }

    function _assertNotOwner(address caller_) private {
        bytes memory failure = abi.encodeWithSelector(ISafeHarborRegistrar.NotVaultOwner.selector, _vault, caller_);
        vm.expectRevert(failure);
        vm.prank(caller_);
        _registrar.setParticipation(_vault, true);
        vm.expectRevert(failure);
        vm.prank(caller_);
        _registrar.setParticipation(_vault, false);
    }

    function _single(string memory address_, ChildContractScope scope_)
        private
        pure
        returns (HarborAccount[] memory accounts_)
    {
        accounts_ = new HarborAccount[](1);
        accounts_[0] = HarborAccount(address_, scope_);
    }

    function _seed(
        MockAgreement agreement_,
        string memory id_,
        HarborAccount[] memory accounts_,
        string memory recovery_
    ) private {
        HarborChain[] memory chains = new HarborChain[](1);
        chains[0] = HarborChain(recovery_, accounts_, id_);
        address agreementOwner = agreement_.owner();
        vm.prank(agreementOwner);
        agreement_.addChains(chains);
    }

    function _upperHex(string memory value_) private pure returns (string memory) {
        bytes memory result = bytes(value_);
        for (uint256 i = 2; i < result.length; ++i) {
            uint8 character = uint8(result[i]);
            if (character > 96 && character < 103) result[i] = bytes1(character - 32);
        }
        return string(result);
    }
}
