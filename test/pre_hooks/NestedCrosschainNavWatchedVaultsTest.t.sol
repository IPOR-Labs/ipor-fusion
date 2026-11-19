// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainNavValidationPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";
import {ExchangeRateValidatorPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorPreHook.sol";
import {UpdateBalancesIgnoreDustPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesIgnoreDustPreHook.sol";
import {
    ExchangeRateValidatorConfigLib,
    ExchangeRateValidatorConfig,
    HookType,
    Hook
} from "../../contracts/handlers/pre_hooks/pre_hooks/ExchangeRateValidatorConfigLib.sol";
import {PlasmaVaultMockMarketsTestBase} from "../vaults/PlasmaVaultMockMarketsTestBase.sol";
import {MockExecutor} from "../crosschain/mocks/MockExecutor.sol";
import {CrosschainWatchedVaultHarness} from "../crosschain/mocks/CrosschainWatchedVaultHarness.sol";

/// @title NestedCrosschainNavWatchedVaultsTest
/// @notice IL-9720 (part 3) on a REAL `PlasmaVault`: the two limits of the current pre-hook system that the watched-vault
///         list cannot get around, pinned as executable rules (the same rules the README states):
///         (1) a `CrosschainNavValidationPreHook` nested in `ExchangeRateValidatorPreHook` reads the substrates of the
///         REGISTERED implementation, not its own, so its list is empty and a fail-closed watched vault does not stop the
///         deposit;
///         (2) registered directly it replaces whatever the selector had: a rate validator with its nested hooks stops
///         running, and with it every control it performed.
///         Both pass on the code of this commit; Hooks V2 (IL-9490) lifts them.
contract NestedCrosschainNavWatchedVaultsTest is PlasmaVaultMockMarketsTestBase {
    uint256 internal constant DEPOSIT = 1_000e6;
    uint256 internal constant CROSSCHAIN_MARKET = IporFusionMarkets.CROSSCHAIN;

    ExchangeRateValidatorPreHook internal validator;
    CrosschainNavValidationPreHook internal navHook;
    CrosschainWatchedVaultHarness internal watched;
    MockExecutor internal watchedExecutor;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        validator = new ExchangeRateValidatorPreHook(IporFusionMarkets.EXCHANGE_RATE_VALIDATOR);
        navHook = new CrosschainNavValidationPreHook(CROSSCHAIN_MARKET);
        watched = new CrosschainWatchedVaultHarness(address(0xA55E7));
        watchedExecutor = new MockExecutor(address(watched), address(0xA55E7));
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(watchedExecutor));
        watched.grantSubstrates(CROSSCHAIN_MARKET, subs);
    }

    function _depositSelector() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.deposit.selector;
    }

    function _watchedList() private view returns (bytes32[][] memory substrates) {
        substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](1);
        substrates[0][0] = PlasmaVaultConfigLib.addressToBytes32(address(watched));
    }

    function _register(address hook_, bytes32[][] memory substrates_) private {
        address[] memory hooks = new address[](1);
        hooks[0] = hook_;
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(_depositSelector(), hooks, substrates_);
    }

    /// @dev Lists `nestedHook_` as a PREHOOKS entry of the rate validator (market substrate of the validator market).
    function _nest(address nestedHook_) private {
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

    /// @notice Control: registered directly with the list, the hook closes the holder's deposit while the watched vault is
    ///         fail-closed, and opens it again when the watched vault recovers.
    function testDirectRegistrationClosesDepositWhileTheWatchedVaultIsFailClosed() public {
        _register(address(navHook), _watchedList());

        watchedExecutor.setBalanceReverts(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainNavValidationPreHook.CrosschainNavValidationPreHookWatchedVaultUnhealthy.selector,
                address(watched)
            )
        );
        _deposit(user, DEPOSIT);

        watchedExecutor.setBalanceReverts(false);
        _deposit(user, DEPOSIT);
        assertGt(plasmaVault.balanceOf(user), 0, "deposit succeeded once the watched vault recovered");
    }

    /// @notice Limit 2 of the README: nested in the rate validator the hook reads the substrates of the validator, so its list
    ///         is empty and the fail-closed watched vault does not stop the deposit.
    function testNestedHookSeesNoListAndTheWatchedVaultDoesNotStopTheDeposit() public {
        // the list is stored under (validator, deposit): the nested hook looks under (navHook, deposit) and finds nothing
        _register(address(validator), _watchedList());
        _nest(address(navHook));

        watchedExecutor.setBalanceReverts(true);
        _deposit(user, DEPOSIT);
        assertGt(plasmaVault.balanceOf(user), 0, "known opening: the nested hook never sees the list");
    }

    /// @notice Limit 1 of the README: registering the hook directly replaces the rate validator with its nested hooks, so a
    ///         control the validator performed (here a nested hook that reverts) stops running.
    function testDirectRegistrationReplacesTheRateValidatorAndItsNestedHooks() public {
        UpdateBalancesIgnoreDustPreHook dust = new UpdateBalancesIgnoreDustPreHook();
        bytes32[][] memory none = new bytes32[][](1);
        none[0] = new bytes32[](0);
        _register(address(validator), none);
        _nest(address(dust)); // nested, the dust hook has no threshold substrate and fails closed

        vm.expectRevert(UpdateBalancesIgnoreDustPreHook.InvalidSubstratesLength.selector);
        _deposit(user, DEPOSIT);

        _register(address(navHook), none); // the hook NAV takes over the selector: the validator and its nested hook are gone
        _deposit(user, DEPOSIT);
        assertGt(plasmaVault.balanceOf(user), 0, "the control the validator performed is lost (README limit 1)");
    }
}
