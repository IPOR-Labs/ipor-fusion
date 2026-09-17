// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "../../lib/forge-std/src/Test.sol";
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
    Contact,
    BountyTerms,
    AgreementDetails,
    ChildContractScope,
    IdentityRequirements
} from "../../contracts/safe-harbor/ext/IAgreement.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {ISafeHarborAgreementFactory} from "./mocks/ISafeHarborAgreementFactory.sol";

/// @title SafeHarborRegistrarForkTest
/// @author IPOR Labs
/// @notice Integrates live Ethereum PlasmaVaults and their existing owners with the deployed SEAL V3 factory.
/// @dev ETHEREUM_PROVIDER_URL is mandatory; no vault, access manager or role membership is created or mocked.
contract SafeHarborRegistrarForkTest is Test {
    // Published at the pinned commit's README.md; deployment code checked at this fixed block.
    address private constant AGREEMENT_FACTORY = 0xcf317fE605397bC3fae6DAD06331aE5154F277fF;
    address private constant CHAIN_VALIDATOR = 0xd01C76ccE414d9B0a294abAFD94feD2e0B88675D;
    // Existing FusionFactoryBusinessClientFeePackagesForkTest fixture, also verified in the IPOR address registry.
    address private constant FUSION_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    uint256 private constant FORK_BLOCK = 25_952_115;
    string private constant OTHER_ACCOUNT = "0x0000000000000000000000000000000000006789";

    address private _multisig;
    address private _vaultOwner;
    address private _secondVaultOwner;
    address private _vault;
    address private _secondVault;
    string private _recovery;
    IAgreement private _agreement;
    SafeHarborRegistrar private _registrar;

    /// @notice Verifies existing vault ownership, then deploys only the Agreement and Registrar on a fixed fork.
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);
        assertEq(block.chainid, 1);
        assertGt(AGREEMENT_FACTORY.code.length, 0, "Real factory must be deployed");
        assertGt(CHAIN_VALIDATOR.code.length, 0, "Real validator must be deployed");

        _multisig = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
        // Existing fixtures: UsdcToRUsdcZapTest and BalanceFusesReaderTest; roles verified at FORK_BLOCK.
        _vault = 0x2D71CC054AA096a1b3739D67303f88C75b1D59dC;
        _vaultOwner = 0x838293B726A34eDf8d4dbDa7C273F59F1482F606;
        _secondVault = 0xe9385eFf3F937FcB0f0085Da9A3F53D6C2B4fB5F;
        _secondVaultOwner = 0xFbA787bB75d6D0F7fad188De9F12650323b35D87;
        _assertLiveVault(_vault, _vaultOwner, 0xCc9A3e8205AB60e613A044eFcEa5d3479187aceE, 0);
        _assertLiveVault(_secondVault, _secondVaultOwner, 0x3dF9d7BE4017e3d72eA39b96eD4C7070c19eAbaE, 0);
        assertGt(FUSION_FACTORY.code.length, 0, "Live FusionFactory missing");
        (bool supportsVaultCheck,) =
            FUSION_FACTORY.staticcall(abi.encodeCall(IFusionFactoryVaultCheck.isFusionVault, (_vault)));
        assertFalse(supportsVaultCheck, "Legacy selector must fail");
        assertGt(_multisig.code.length, 0, "Real DAO Safe must be deployed");
        assertNotEq(_vault, _secondVault);
        assertNotEq(_vaultOwner, _secondVaultOwner);
        _recovery = Strings.toHexString(_multisig);
        AgreementDetails memory initialTerms = _terms(_recovery);
        _agreement = IAgreement(
            ISafeHarborAgreementFactory(AGREEMENT_FACTORY)
                .create(initialTerms, CHAIN_VALIDATOR, _multisig, keccak256("IPOR registrar integration"))
        );
        assertGt(address(_agreement).code.length, 0);
        assertEq(_agreement.owner(), _multisig);
        _assertAgreementDetails(_agreement, initialTerms);

        _registrar = new SafeHarborRegistrar(_multisig, address(_agreement), FUSION_FACTORY, _recovery);
        assertEq(_registrar.getCaip2ChainId(), "eip155:1");
        assertEq(_registrar.getFusionFactory(), FUSION_FACTORY);
        assertFalse(_registrar.isEligibleVault(_vault));
        assertFalse(_registrar.isEligibleVault(_secondVault));
        address[] memory vaults = new address[](2);
        vaults[0] = _vault;
        vaults[1] = _secondVault;
        vm.startPrank(_multisig);
        _agreement.transferOwnership(address(_registrar));
        _registrar.setManualAllowlistBatch(vaults, true);
        vm.stopPrank();
        assertTrue(_registrar.isManualAllowlisted(_vault));
        assertTrue(_registrar.isManualAllowlisted(_secondVault));
    }

    /// @notice AC7: real factory-created Agreement supports add, exact removal, final exit, and reentry.
    function testForkRealAgreementFactoryRoundTrip() public {
        assertFalse(_registrar.isParticipating(_vault));
        assertFalse(_registrar.isParticipating(_secondVault));
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.ParticipationChanged(_vault, true, _vaultOwner);
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, true);
        assertTrue(_registrar.isParticipating(_vault));
        _assertCurrentChain(_agreement, _vault, _recovery);
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.AlreadyParticipating.selector, _vault));
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, true);

        vm.prank(_secondVaultOwner);
        _registrar.setParticipation(_secondVault, true);
        vm.expectEmit(false, false, false, true, address(_registrar));
        emit ISafeHarborRegistrar.ParticipationChanged(_vault, false, _vaultOwner);
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, false);
        assertFalse(_registrar.isParticipating(_vault));
        assertTrue(_registrar.isParticipating(_secondVault));
        _assertCurrentChain(_agreement, _secondVault, _recovery);

        // This must invoke removeChains: real removeAccounts cannot remove the final account.
        vm.prank(_secondVaultOwner);
        _registrar.setParticipation(_secondVault, false);
        assertFalse(_registrar.isParticipating(_secondVault));
        _assertAgreementDetails(_agreement, _terms(_recovery));
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, true);
        _assertCurrentChain(_agreement, _vault, _recovery);
        vm.prank(_multisig);
        _registrar.forceRemove(_vault);
        assertFalse(_registrar.isParticipating(_vault));
        _assertAgreementDetails(_agreement, _terms(_recovery));
    }

    /// @notice Batch revocation preserves a live vault's coverage until authorized forced removal.
    function testForkBatchAllowlistRevocationPreservesCoverage() public {
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, true);
        address[] memory vaults = new address[](2);
        vaults[0] = _vault;
        vaults[1] = _secondVault;
        vm.prank(_multisig);
        _registrar.setManualAllowlistBatch(vaults, false);
        assertFalse(_registrar.isManualAllowlisted(_vault));
        assertFalse(_registrar.isManualAllowlisted(_secondVault));
        assertTrue(_registrar.isParticipating(_vault));
        _assertCurrentChain(_agreement, _vault, _recovery);
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotFusionVault.selector, _vault));
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, false);
        vm.prank(_multisig);
        _registrar.forceRemove(_vault);
        assertFalse(_registrar.isParticipating(_vault));
        _assertAgreementDetails(_agreement, _terms(_recovery));
    }

    /// @notice A live OWNER_ROLE holder still needs provenance approval with the deployed legacy factory.
    function testForkLiveVaultWithoutAllowlistRejected() public {
        vm.prank(_multisig);
        _registrar.setManualAllowlist(_vault, false);
        assertFalse(_registrar.isEligibleVault(_vault));
        bytes memory failure = abi.encodeWithSelector(ISafeHarborRegistrar.NotFusionVault.selector, _vault);
        vm.expectRevert(failure);
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, true);
        vm.expectRevert(failure);
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, false);
        assertFalse(_registrar.isParticipating(_vault));
        _assertAgreementDetails(_agreement, _terms(_recovery));
    }

    /// @notice A caller without live OWNER_ROLE cannot opt the vault in or out.
    function testForkNonOwnerCannotChangeParticipation() public {
        address nonOwner = makeAddr("fork non-owner");
        (bool isOwner,) = IAccessManager(IAccessManaged(_vault).authority()).hasRole(Roles.OWNER_ROLE, nonOwner);
        assertFalse(isOwner, "Non-owner fixture has OWNER_ROLE");
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotVaultOwner.selector, _vault, nonOwner));
        vm.prank(nonOwner);
        _registrar.setParticipation(_vault, true);
        assertFalse(_registrar.isParticipating(_vault));
        _assertAgreementDetails(_agreement, _terms(_recovery));

        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, true);
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotVaultOwner.selector, _vault, nonOwner));
        vm.prank(nonOwner);
        _registrar.setParticipation(_vault, false);
        assertTrue(_registrar.isParticipating(_vault));
        _assertCurrentChain(_agreement, _vault, _recovery);
    }

    /// @notice An existing owner of the first live vault has no participation rights over the second vault.
    function testForkDifferentVaultOwnerCannotChangeParticipation() public {
        (bool isOwner,) =
            IAccessManager(IAccessManaged(_secondVault).authority()).hasRole(Roles.OWNER_ROLE, _vaultOwner);
        assertFalse(isOwner, "Unexpected cross-vault owner");
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotVaultOwner.selector, _secondVault, _vaultOwner));
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_secondVault, true);
        assertFalse(_registrar.isParticipating(_secondVault));

        vm.prank(_secondVaultOwner);
        _registrar.setParticipation(_secondVault, true);
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotVaultOwner.selector, _secondVault, _vaultOwner));
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_secondVault, false);
        assertTrue(_registrar.isParticipating(_secondVault));
        _assertCurrentChain(_agreement, _secondVault, _recovery);
    }

    /// @notice A real OWNER_ROLE holder with an existing execution delay can opt in and out immediately.
    function testForkLiveOwnerWithExecutionDelayCanParticipate() public {
        // Existing fixture: WrappedPlasmaVaultTest; the DAO Safe's live OWNER_ROLE delay is fourteen days.
        address vault = 0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2;
        _assertLiveVault(vault, _multisig, 0x818912488f1023419426d1410D351d7Daa7dF7Aa, 1_209_600);
        vm.prank(_multisig);
        _registrar.setManualAllowlist(vault, true);
        vm.prank(_multisig);
        _registrar.setParticipation(vault, true);
        assertTrue(_registrar.isParticipating(vault));
        _assertCurrentChain(_agreement, vault, _recovery);
        vm.prank(_multisig);
        _registrar.setParticipation(vault, false);
        assertFalse(_registrar.isParticipating(vault));
        _assertAgreementDetails(_agreement, _terms(_recovery));
    }

    /// @notice A live owner cannot opt out before participation, and the real Agreement remains unchanged.
    function testForkNotParticipatingLiveVault() public {
        assertFalse(_registrar.isParticipating(_vault));
        vm.expectRevert(abi.encodeWithSelector(ISafeHarborRegistrar.NotParticipating.selector, _vault));
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, false);
        _assertAgreementDetails(_agreement, _terms(_recovery));
    }

    /// @notice Real Agreement ownership transfer blocks mutations until its owner hands it back.
    function testForkAgreementNotOwnedRejectsMutations() public {
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, true);
        vm.prank(_multisig);
        _registrar.transferAgreementOwnership(_multisig);
        assertEq(_agreement.owner(), _multisig);
        assertTrue(_registrar.isParticipating(_vault));
        bytes memory failure = abi.encodeWithSelector(
            ISafeHarborRegistrar.AgreementNotOwnedByRegistrar.selector, address(_agreement), _multisig
        );
        vm.expectRevert(failure);
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, false);
        vm.expectRevert(failure);
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, true);
        vm.expectRevert(failure);
        vm.prank(_secondVaultOwner);
        _registrar.setParticipation(_secondVault, true);
        vm.expectRevert(failure);
        vm.prank(_multisig);
        _registrar.forceRemove(_vault);
        _assertCurrentChain(_agreement, _vault, _recovery);

        vm.prank(_multisig);
        _agreement.transferOwnership(address(_registrar));
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, false);
        assertFalse(_registrar.isParticipating(_vault));
        _assertAgreementDetails(_agreement, _terms(_recovery));
    }

    /// @notice Imported mixed-case duplicates are all removed by the real Agreement's exact-string API.
    function testForkImportedDuplicatesRemovedCompletely() public {
        HarborAccount[] memory accounts = new HarborAccount[](4);
        string memory canonical = Strings.toHexString(_vault);
        bytes memory uppercase = bytes(Strings.toHexString(_vault));
        for (uint256 i = 2; i < uppercase.length; ++i) {
            uint8 character = uint8(uppercase[i]);
            if (character > 96 && character < 103) uppercase[i] = bytes1(character - 32);
        }
        accounts[0] = HarborAccount(canonical, ChildContractScope.None);
        accounts[1] = HarborAccount(Strings.toHexString(_secondVault), ChildContractScope.None);
        accounts[2] = HarborAccount(string(uppercase), ChildContractScope.All);
        accounts[3] = HarborAccount(canonical, ChildContractScope.ExistingOnly);
        HarborChain[] memory chains = new HarborChain[](1);
        chains[0] = HarborChain(_recovery, accounts, "eip155:1");
        // Import scope through the real Agreement owner's authorized ownership round trip.
        vm.prank(_multisig);
        _registrar.transferAgreementOwnership(_multisig);
        vm.prank(_multisig);
        _agreement.addChains(chains);
        vm.prank(_multisig);
        _agreement.transferOwnership(address(_registrar));
        assertTrue(_registrar.isParticipating(_vault));
        vm.prank(_vaultOwner);
        _registrar.setParticipation(_vault, false);
        assertFalse(_registrar.isParticipating(_vault));
        _assertCurrentChain(_agreement, _secondVault, _recovery);
        vm.prank(_multisig);
        _registrar.forceRemove(_secondVault);
        _assertAgreementDetails(_agreement, _terms(_recovery));
    }

    function _assertLiveVault(address vault_, address owner_, address manager_, uint32 executionDelay_) private view {
        assertGt(vault_.code.length, 0, "Live vault missing");
        assertEq(IAccessManaged(vault_).authority(), manager_, "Pinned live access manager");
        assertGt(manager_.code.length, 0, "Live access manager missing");
        (bool isOwner, uint32 executionDelay) = IAccessManager(manager_).hasRole(Roles.OWNER_ROLE, owner_);
        assertTrue(isOwner, "Live OWNER_ROLE required");
        assertEq(executionDelay, executionDelay_, "Pinned live role delay");
    }

    function _terms(string memory recovery_) private pure returns (AgreementDetails memory details_) {
        details_.protocolName = "IPOR Fusion test";
        details_.contactDetails = new Contact[](1);
        details_.contactDetails[0] = Contact("Security", "security@example.invalid");
        details_.chains = new HarborChain[](1);
        HarborAccount[] memory accounts = new HarborAccount[](1);
        accounts[0] = HarborAccount(OTHER_ACCOUNT, ChildContractScope.None);
        details_.chains[0] = HarborChain(recovery_, accounts, "eip155:8453");
        details_.bountyTerms = BountyTerms(10, 1_000_000, false, IdentityRequirements.Named, "Test terms", 2_000_000);
        details_.agreementURI = "ipfs://test-agreement";
    }

    function _assertCurrentChain(IAgreement agreement_, address vault_, string memory recovery_) private view {
        AgreementDetails memory expected = _terms(recovery_);
        HarborChain memory otherChain = expected.chains[0];
        expected.chains = new HarborChain[](2);
        expected.chains[0] = otherChain;
        HarborAccount[] memory accounts = new HarborAccount[](1);
        accounts[0] = HarborAccount(Strings.toHexString(vault_), ChildContractScope.None);
        expected.chains[1] = HarborChain(recovery_, accounts, "eip155:1");
        _assertAgreementDetails(agreement_, expected);
    }

    // Compare complete ABI bytes, avoiding both the legacy nested decoder and the registrar's parsing logic.
    function _assertAgreementDetails(IAgreement agreement_, AgreementDetails memory expected_) private view {
        (bool success, bytes memory data) = address(agreement_).staticcall(abi.encodeCall(IAgreement.getDetails, ()));
        assertTrue(success, "Agreement details readable");
        assertEq(keccak256(data), keccak256(abi.encode(expected_)), "Exact Agreement contents");
    }
}
