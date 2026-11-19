// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {ExchangeRateValidatorPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorPreHook.sol";
import {UpdateBalancesIgnoreDustPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesIgnoreDustPreHook.sol";
import {EIP7702DelegateValidationPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/EIP7702DelegateValidationPreHook.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {
    ExchangeRateValidatorConfigLib,
    ExchangeRateValidatorConfig,
    HookType,
    Hook
} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";
import {PlasmaVaultMockMarketsTestBase} from "../vaults/PlasmaVaultMockMarketsTestBase.sol";

/// @title NestedPreHookSubstratesTest
/// @notice IL-9651 (L20): executable form of the documented rule that pre-hook substrates belong to a registered
///         implementation and selector (`PreHooksLib.setPreHookImplementations` stores them under
///         keccak256(implementation, selector)). A hook nested in `ExchangeRateValidatorPreHook` is not registered on
///         the selector, so it never receives substrates of its own.
/// @dev Pinned invariants, to be carried as a requirement into Hooks V2 (IL-9490), whichever way that design passes
///      configuration to nested hooks:
///      (1) a nested hook that needs its own substrates must fail closed (revert) or be refused at configuration
///          time; it must never run with an empty list that silently weakens it into "allow everything";
///          `UpdateBalancesIgnoreDustPreHook` nested reverts `InvalidSubstratesLength` while a balance-fuse market is
///          active;
///      (2) `EIP7702DelegateValidationPreHook` nested sees an empty whitelist and rejects every delegated sender
///          (closed, never open);
///      (3) hooks without substrates (`UpdateBalancesPreHook`) work nested;
///      (4) the same hooks registered directly on the selector work as documented.
///      Passes on the base commit (pinning test); the code fix (substrates keyed independently of the top-level
///      implementation) was left out because it would change PlasmaVault bytecode (EIP-170).
contract NestedPreHookSubstratesTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant DEPOSIT = 1_000e6;
    address internal constant DELEGATE = address(0xDE1E6A7E);

    ExchangeRateValidatorPreHook internal validator;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        validator = new ExchangeRateValidatorPreHook(IporFusionMarkets.EXCHANGE_RATE_VALIDATOR);
    }

    // ------------------------------------------------------------------ dust hook

    /// @notice Nested under the validator the dust hook has no threshold substrate and fails closed.
    function testNestedIgnoreDustPreHookRevertsInvalidSubstratesLength() public {
        UpdateBalancesIgnoreDustPreHook dust = new UpdateBalancesIgnoreDustPreHook();
        _registerValidatorWithNestedHook(address(dust));

        vm.expectRevert(UpdateBalancesIgnoreDustPreHook.InvalidSubstratesLength.selector);
        _deposit(user, DEPOSIT);

        assertEq(plasmaVault.balanceOf(user), 0, "the hooked call did not go through");
    }

    /// @notice Registered directly with its threshold substrate the same hook works.
    function testDirectIgnoreDustPreHookWorks() public {
        UpdateBalancesIgnoreDustPreHook dust = new UpdateBalancesIgnoreDustPreHook();
        _registerDirect(address(dust), bytes32(uint256(1)));

        _deposit(user, DEPOSIT);

        assertGt(plasmaVault.balanceOf(user), 0, "deposit succeeded through the directly registered hook");
    }

    // ------------------------------------------------------------------ EIP-7702 hook

    /// @notice Nested under the validator the whitelist is empty: a delegated user is rejected, even for a delegate
    ///         that a direct registration would whitelist.
    function testNestedEip7702HookRejectsDelegatedUser() public {
        EIP7702DelegateValidationPreHook eip7702 = new EIP7702DelegateValidationPreHook();
        _registerValidatorWithNestedHook(address(eip7702));
        _delegate(user);

        vm.expectRevert(
            abi.encodeWithSelector(EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector, user, DELEGATE)
        );
        _deposit(user, DEPOSIT);
    }

    /// @notice Nested, a plain EOA (no delegation) still passes: the hook only restricts delegated senders.
    function testNestedEip7702HookAllowsPlainEoa() public {
        EIP7702DelegateValidationPreHook eip7702 = new EIP7702DelegateValidationPreHook();
        _registerValidatorWithNestedHook(address(eip7702));

        _deposit(user, DEPOSIT);

        assertGt(plasmaVault.balanceOf(user), 0, "plain EOA deposit succeeded");
    }

    /// @notice Registered directly the whitelist substrate is honoured: a whitelisted delegate passes, another is rejected.
    function testDirectEip7702HookHonoursWhitelist() public {
        EIP7702DelegateValidationPreHook eip7702 = new EIP7702DelegateValidationPreHook();
        _registerDirect(address(eip7702), bytes32(uint256(uint160(DELEGATE))));

        _delegate(user);
        _deposit(user, DEPOSIT);
        assertGt(plasmaVault.balanceOf(user), 0, "whitelisted delegate passes");

        address stranger = address(0x57A9);
        vm.etch(other, abi.encodePacked(hex"ef0100", stranger));
        vm.expectRevert(
            abi.encodeWithSelector(EIP7702DelegateValidationPreHook.InvalidDelegateTarget.selector, other, stranger)
        );
        _deposit(other, DEPOSIT);
    }

    // ------------------------------------------------------------------ hooks without substrates

    /// @notice A hook that needs no substrates (UpdateBalancesPreHook) works nested: it refreshes the market cache.
    function testNestedUpdateBalancesPreHookWorks() public {
        _deposit(user, DEPOSIT);
        _allocate(address(marketA), DEPOSIT / 2);
        uint256 cachedBefore = plasmaVault.totalAssetsInMarket(MARKET_A);
        _accrue(address(marketA), 1_000);

        _registerValidatorWithNestedHook(address(new UpdateBalancesPreHook()));
        _deposit(user, DEPOSIT);

        assertGt(plasmaVault.totalAssetsInMarket(MARKET_A), cachedBefore, "the nested hook refreshed market A");
    }

    // ------------------------------------------------------------------ helpers

    function _depositSelector() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;
    }

    /// @dev Registers the validator on `deposit` and lists `nestedHook_` as its pre-hook (market substrate entry).
    function _registerValidatorWithNestedHook(address nestedHook_) private {
        address[] memory hooks = new address[](1);
        hooks[0] = address(validator);
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(_depositSelector(), hooks, substrates);

        bytes32[] memory market = new bytes32[](1);
        market[0] = ExchangeRateValidatorConfigLib.exchangeRateValidatorConfigToBytes32(
            ExchangeRateValidatorConfig({
                typ: HookType.PREHOOKS,
                data: ExchangeRateValidatorConfigLib.hookToBytes31(Hook({hookAddress: nestedHook_, index: 0}))
            })
        );
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.EXCHANGE_RATE_VALIDATOR,
            market
        );
    }

    /// @dev Registers `hook_` directly on `deposit` with one substrate.
    function _registerDirect(address hook_, bytes32 substrate_) private {
        address[] memory hooks = new address[](1);
        hooks[0] = hook_;
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = substrate_;
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(_depositSelector(), hooks, substrates);
    }

    /// @dev Gives `account_` an EIP-7702 delegation designator pointing to DELEGATE.
    function _delegate(address account_) private {
        vm.etch(account_, abi.encodePacked(hex"ef0100", DELEGATE));
    }
}
