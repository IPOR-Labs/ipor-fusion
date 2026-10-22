// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";

import {
    IporFusionAccessManagerInitializerLibV1,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";

/// @title RedemptionDelayGasBaselineTest
/// @notice Gas baseline of the normal (non-exempt, unlocked) exit paths, recorded on the implementation that
/// existed BEFORE the IL-7935 redemption-delay exemptions were added.
/// @dev Every BASELINE_* constant is the callee-side gas (`vm.lastCallGas().gasTotalUsed`) of exactly one call,
/// measured after the account deposited and its redemption delay expired (`vm.warp`).
/// Two measurement methods are used. The access-manager constants keep the cold method (`vm.cool` on the access
/// manager before the call); it is stable across forge versions. The vault constants (withdraw, redeem, transfer,
/// transferFrom) use a WARM-STATE method: an identical warm-up call (same caller, receiver, spender and size) runs
/// first and is not measured, then the second identical call is measured, so every account and slot on the path is
/// warm and non-zero before and after (no slot is initialised by the measured call). Reason: cold accounting of
/// multi-contract paths differs between forge versions (`vm.cool` semantics: CI uses foundry `stable`, the VM
/// runs 1.7.1), which made the former cold vault numbers differ by exact multiples of 2_800 gas on CI. The vault
/// numbers therefore mean the cost of a repeated exit with everything warm. The regression-guard semantics are
/// unchanged: any extra SLOAD or branch on the hot path still moves the number. The access-manager tests call `canCallAndUpdate(account, vault, selector)` from the
/// vault address (empty calldata beyond the three arguments); the vault tests call `withdraw`, `redeem`, `transfer`
/// and `transferFrom` on a FusionFactory clone with a one-day redemption delay and a MockERC20 underlying token.
/// The numbers are bound to the compiler settings (`foundry.toml`: solc 0.8.30, optimizer runs 2, bytecode_hash none,
/// evm_version cancun, no via_ir; Release 2026-10, main @ 08ecadf2), to the OpenZeppelin version in `lib/` and to the
/// exact calldata and the warm/cold state above. Any change of those requires re-measuring the baseline on the unchanged implementation.
/// IMPLEMENTERS OF IL-7935 MUST NOT EDIT THE CONSTANTS. The test must pass unchanged after the implementation;
/// a failing equality means the exemption check made withdrawals more expensive and is reported to the
/// supervisor (Pete decides), it is never fixed by re-recording the number.
///
/// The first baseline was recorded on the unchanged implementation (origin/main @ 403807b). The IL-7935 exemption
/// branch in `RedemptionDelayLib.lockChecks` (`unlockTime > block.timestamp && !isRedemptionDelayExempt(account_)`)
/// adds exactly +20 gas per `canCallAndUpdate` check (compiler overhead of the extra branch; no storage read on the
/// unlocked path), i.e. +40 on the vault paths that check two accounts. Pete accepted this delta (IL-7935 decision
/// D-012, 2026-10-15) and the constants were re-recorded once; the equalities stay as the regression guard. The
/// standing rule remains: implementers never re-record constants without a recorded decision.
///
/// Second re-recording: adding the owner entry point `setRedemptionDelayExemption` to `PlasmaVaultGovernance` adds one
/// selector to the dispatcher of `PlasmaVaultBase` (PlasmaVault does not inherit PlasmaVaultGovernance; the call
/// reaches PlasmaVaultBase through the vault's fallback delegatecall), which costs +22 gas per PlasmaVaultBase
/// dispatch: +44 on withdraw and redeem (two dispatches per call), +22 on transfer and transferFrom (withdraw
/// 222_538 -> 222_582, redeem 273_134 -> 273_178, transfer 63_989 -> 64_011, transferFrom 76_347 -> 76_369); the two
/// access manager checks are unchanged. Pete accepted this delta (IL-7935 decision D-013, 2026-10-15). Same rule: no
/// re-recording without a recorded decision.
///
/// Third re-recording (D-015, 2026-10-19): main @ 08ecadf2 (Release 2026-10) changed the compiler settings
/// (optimizer runs 10_000_000 -> 2, bytecode_hash none) and the PlasmaVault code; the IL-7935 code is unchanged. Measured
/// with forge 1.8.5 on main @ 08ecadf2 without IL-7935 -> with IL-7935 (merge): access manager withdraw check
/// 18_857 -> 18_943 (+86), transferFrom check 21_734 -> 21_820 (+86), vault withdraw 99_497 -> 99_779 (+282), redeem
/// 153_283 -> 153_565 (+282), transfer 13_707 -> 13_815 (+108), transferFrom 20_089 -> 20_283 (+194). With runs
/// 10_000_000 on the same code the deltas were +20/+20/+62/+62/+42/+62 (equal to or below D-012/D-013); the larger
/// deltas come from the size-optimised compiler output, not from a storage read. Pete accepted them (IL-7935 decision
/// D-015, 2026-10-19). Same rule: no re-recording without a recorded decision.
///
/// Fourth re-recording (IL-8681 D-070, 2026-10-20): the merge of origin/main fd7ddba4 into the IL-8681 branch brought
/// the IL-8681 fixes into the measured vault paths; the IL-7935 code is unchanged. Vault withdraw 99_779 -> 100_839
/// (+1_060: WithdrawManager.getWithdrawFee is read twice after IL-8751, +1_046, and the PlasmaVaultBase fallback layout
/// changed after size commit e30f51a0, +12), redeem +13, transfer +12, transferFrom +12 (the same layout effect).
contract RedemptionDelayGasBaselineTest is Test {
    uint256 private constant BASELINE_ACCESS_MANAGER_WITHDRAW_CHECK = 18_943; // T00 17_836 on origin/main @ 403807b (runs 10M) -> D-012 17_856 (+20, exemption branch) -> D-013 17_856 (unchanged) -> D-015 18_943 (re-recorded on main 08ecadf2, runs 2 + bytecode_hash none, 2026-10-19: 18_857 without IL-7935, +86; at runs 10M the delta was +20)
    uint256 private constant BASELINE_ACCESS_MANAGER_TRANSFER_FROM_CHECK = 21_820; // T00 20_605 on origin/main @ 403807b (runs 10M) -> D-012 20_625 (+20, exemption branch) -> D-013 20_625 (unchanged) -> D-015 21_820 (re-recorded on main 08ecadf2, runs 2 + bytecode_hash none, 2026-10-19: 21_734 without IL-7935, +86; at runs 10M the delta was +20)
    uint256 private constant BASELINE_VAULT_WITHDRAW = 100_839; // T00 222_498 -> D-012 222_538 (+40, exemption branch) -> D-013 222_582 (+44, dispatcher) -> T10 71_034 (warm-state measurement, CI-stable) -> D-015 99_779 (re-recorded on main 08ecadf2, runs 2 + bytecode_hash none, 2026-10-19: 99_497 without IL-7935, +282; at runs 10M the delta was +62) -> IL-8681 D-070 100_839 (re-recorded on the merge of origin/main fd7ddba4 with the IL-8681 fixes, 2026-10-20: +1_060 = withdraw reads WithdrawManager.getWithdrawFee twice after IL-8751 (+1_046) and PlasmaVaultBase fallback layout after IL-8743/IL-8751 size commit e30f51a0 (+12))
    uint256 private constant BASELINE_VAULT_REDEEM = 153_578; // T00 273_094 -> D-012 273_134 (+40, exemption branch) -> D-013 273_178 (+44, dispatcher) -> T10 121_630 (warm-state measurement, CI-stable) -> D-015 153_565 (re-recorded on main 08ecadf2, runs 2 + bytecode_hash none, 2026-10-19: 153_283 without IL-7935, +282; at runs 10M the delta was +62) -> IL-8681 D-070 153_578 (re-recorded on the merge of origin/main fd7ddba4 with the IL-8681 fixes, 2026-10-20: +13: PlasmaVaultBase fallback layout after e30f51a0)
    uint256 private constant BASELINE_VAULT_TRANSFER = 13_827; // T00 63_969 -> D-012 63_989 (+20, exemption branch) -> D-013 64_011 (+22, dispatcher) -> T10 11_311 (warm-state measurement, CI-stable) -> D-015 13_815 (re-recorded on main 08ecadf2, runs 2 + bytecode_hash none, 2026-10-19: 13_707 without IL-7935, +108; at runs 10M the delta was +42) -> IL-8681 D-070 13_827 (re-recorded on the merge of origin/main fd7ddba4 with the IL-8681 fixes, 2026-10-20: +12: PlasmaVaultBase fallback layout after e30f51a0)
    uint256 private constant BASELINE_VAULT_TRANSFER_FROM = 20_295; // T00 76_307 -> D-012 76_347 (+40, exemption branch) -> D-013 76_369 (+22, dispatcher) -> T10 16_869 (warm-state measurement, CI-stable) -> D-015 20_283 (re-recorded on main 08ecadf2, runs 2 + bytecode_hash none, 2026-10-19: 20_089 without IL-7935, +194; at runs 10M the delta was +62) -> IL-8681 D-070 20_295 (re-recorded on the merge of origin/main fd7ddba4 with the IL-8681 fixes, 2026-10-20: +12: PlasmaVaultBase fallback layout after e30f51a0)

    uint256 private constant INITIAL_REDEMPTION_DELAY = 1 days;
    uint256 private constant DEPOSIT_AMOUNT = 1000 * 1e18;
    uint256 private constant BASE_TIMESTAMP = 1_700_000_000;

    /// @dev Account holding TECH_PLASMA_VAULT_ROLE, simulates the PlasmaVault calling canCallAndUpdate
    address private constant PLASMA_VAULT_STUB = address(0x999);

    address private admin = address(0x1);
    address private atomistStub = address(0x3);
    address private accountStub = address(0x777);

    IporFusionAccessManager private stubAccessManager;

    FusionFactory private fusionFactory;
    FusionFactoryStorageLib.FactoryAddresses private factoryAddresses;
    MockERC20 private underlyingToken;

    address private plasmaVaultBase;
    address private priceOracleMiddleware;
    address private burnRequestFeeFuse;
    address private burnRequestFeeBalanceFuse;

    address private owner;
    address private atomist;
    address private depositor;
    address private spender;
    address private receiver;
    address private daoFeeRecipient;
    address private daoFeeManager;
    address private maintenanceManager;

    IporFusionAccessManager private accessManager;
    PlasmaVault private plasmaVault;

    function setUp() public {
        vm.warp(BASE_TIMESTAMP);

        owner = makeAddr("owner");
        atomist = makeAddr("atomist");
        depositor = makeAddr("depositor");
        spender = makeAddr("spender");
        receiver = makeAddr("receiver");
        daoFeeRecipient = makeAddr("daoFeeRecipient");
        daoFeeManager = makeAddr("daoFeeManager");
        maintenanceManager = makeAddr("maintenanceManager");

        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        plasmaVaultBase = address(new PlasmaVaultBase());
        burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        FusionFactory fusionFactoryImplementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,(address,address,address,address,address,address,address),address,address,address,address)",
            owner,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(fusionFactoryImplementation), initData)));

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        vm.startPrank(daoFeeManager);
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 333,
            performanceFee: 777,
            feeRecipient: daoFeeRecipient
        });
        fusionFactory.setDaoFeePackages(packages);
        vm.stopPrank();

        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = address(1);

        address accessManagerBase = address(new IporFusionAccessManager(owner, 1 seconds));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address contextManagerBase = address(new ContextManager(owner, approvedAddresses));
        address priceManagerBase = address(new PriceOracleMiddlewareManager(owner, priceOracleMiddleware));

        address plasmaVaultCoreBase = address(new PlasmaVault());
        PlasmaVault(plasmaVaultCoreBase).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "fake",
                assetSymbol: "fake",
                underlyingToken: address(underlyingToken),
                priceOracleMiddleware: priceOracleMiddleware,
                feeConfig: FeeConfig({
                    feeFactory: factoryAddresses.feeManagerFactory,
                    iporDaoManagementFee: 111,
                    iporDaoPerformanceFee: 222,
                    iporDaoFeeRecipientAddress: address(this)
                }),
                accessManager: accessManagerBase,
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: withdrawManagerBase,
                plasmaVaultVotesPlugin: address(0)
            })
        );

        address rewardsManagerBase = address(new RewardsClaimManager(owner, plasmaVaultCoreBase));

        vm.startPrank(maintenanceManager);
        fusionFactory.updateBaseAddresses(
            1,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
        vm.stopPrank();

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.clone(
            "Test Vault",
            "TVAULT",
            address(underlyingToken),
            INITIAL_REDEMPTION_DELAY,
            owner,
            0
        );

        accessManager = IporFusionAccessManager(instance.accessManager);
        plasmaVault = PlasmaVault(payable(instance.plasmaVault));

        stubAccessManager = new IporFusionAccessManager(admin, INITIAL_REDEMPTION_DELAY);
        vm.prank(admin);
        stubAccessManager.initialize(_generateInitializationData());
    }

    function testGasAccessManagerWithdrawCheckNonExemptUnlocked() public {
        //given
        _stubDepositAndUnlock();

        //when
        vm.cool(address(stubAccessManager));
        vm.prank(PLASMA_VAULT_STUB);
        stubAccessManager.canCallAndUpdate(accountStub, PLASMA_VAULT_STUB, PlasmaVault.withdraw.selector);
        uint256 measured = vm.lastCallGas().gasTotalUsed;

        //then
        emit log_named_uint("gas", measured);
        assertEq(measured, BASELINE_ACCESS_MANAGER_WITHDRAW_CHECK);
    }

    function testGasAccessManagerTransferFromCheckNonExemptUnlocked() public {
        //given
        _stubDepositAndUnlock();

        //when
        vm.cool(address(stubAccessManager));
        vm.prank(PLASMA_VAULT_STUB);
        stubAccessManager.canCallAndUpdate(accountStub, PLASMA_VAULT_STUB, PlasmaVault.transferFrom.selector);
        uint256 measured = vm.lastCallGas().gasTotalUsed;

        //then
        emit log_named_uint("gas", measured);
        assertEq(measured, BASELINE_ACCESS_MANAGER_TRANSFER_FROM_CHECK);
    }

    function testGasVaultWithdrawNonExemptUnlocked() public {
        //given
        _whitelistDepositAndUnlock();
        uint256 amount = DEPOSIT_AMOUNT / 4;
        vm.prank(depositor);
        plasmaVault.withdraw(amount, depositor, depositor); // warm-up, not measured
        uint256 balanceBefore = underlyingToken.balanceOf(depositor);

        //when
        vm.prank(depositor);
        plasmaVault.withdraw(amount, depositor, depositor);
        uint256 measured = vm.lastCallGas().gasTotalUsed;

        //then
        assertEq(underlyingToken.balanceOf(depositor) - balanceBefore, amount, "withdraw reached payout");
        emit log_named_uint("gas", measured);
        assertEq(measured, BASELINE_VAULT_WITHDRAW);
    }

    function testGasVaultRedeemNonExemptUnlocked() public {
        //given
        _whitelistDepositAndUnlock();
        uint256 shares = plasmaVault.balanceOf(depositor) / 4;
        vm.prank(depositor);
        plasmaVault.redeem(shares, depositor, depositor); // warm-up, not measured
        uint256 balanceBefore = underlyingToken.balanceOf(depositor);

        //when
        vm.prank(depositor);
        plasmaVault.redeem(shares, depositor, depositor);
        uint256 measured = vm.lastCallGas().gasTotalUsed;

        //then
        assertGt(underlyingToken.balanceOf(depositor), balanceBefore, "redeem reached payout");
        emit log_named_uint("gas", measured);
        assertEq(measured, BASELINE_VAULT_REDEEM);
    }

    function testGasVaultTransferNonExemptUnlocked() public {
        //given
        _whitelistDepositAndUnlock();
        vm.prank(owner);
        PlasmaVaultGovernance(address(plasmaVault)).enableTransferShares();
        uint256 shares = plasmaVault.balanceOf(depositor) / 4;
        vm.prank(depositor);
        plasmaVault.transfer(receiver, shares); // warm-up, not measured

        //when
        vm.prank(depositor);
        plasmaVault.transfer(receiver, shares);
        uint256 measured = vm.lastCallGas().gasTotalUsed;

        //then
        assertEq(plasmaVault.balanceOf(receiver), shares * 2, "transfer reached balance update");
        emit log_named_uint("gas", measured);
        assertEq(measured, BASELINE_VAULT_TRANSFER);
    }

    function testGasVaultTransferFromNonExemptUnlocked() public {
        //given
        _whitelistDepositAndUnlock();
        vm.prank(owner);
        PlasmaVaultGovernance(address(plasmaVault)).enableTransferShares();
        uint256 shares = plasmaVault.balanceOf(depositor) / 4;
        vm.prank(depositor);
        plasmaVault.approve(spender, shares * 3);
        vm.prank(spender);
        plasmaVault.transferFrom(depositor, receiver, shares); // warm-up, not measured

        //when
        vm.prank(spender);
        plasmaVault.transferFrom(depositor, receiver, shares);
        uint256 measured = vm.lastCallGas().gasTotalUsed;

        //then
        assertEq(plasmaVault.balanceOf(receiver), shares * 2, "transferFrom reached balance update");
        emit log_named_uint("gas", measured);
        assertEq(measured, BASELINE_VAULT_TRANSFER_FROM);
    }

    function _stubDepositAndUnlock() private {
        vm.prank(PLASMA_VAULT_STUB);
        stubAccessManager.canCallAndUpdate(accountStub, PLASMA_VAULT_STUB, PlasmaVault.deposit.selector);
        vm.warp(block.timestamp + INITIAL_REDEMPTION_DELAY + 1);
    }

    function _whitelistDepositAndUnlock() private {
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);
        accessManager.grantRole(Roles.WHITELIST_ROLE, depositor, 0);
        vm.stopPrank();

        underlyingToken.mint(depositor, DEPOSIT_AMOUNT);

        vm.startPrank(depositor);
        underlyingToken.approve(address(plasmaVault), DEPOSIT_AMOUNT);
        plasmaVault.deposit(DEPOSIT_AMOUNT, depositor);
        vm.stopPrank();

        vm.warp(block.timestamp + INITIAL_REDEMPTION_DELAY + 1);
    }

    function _generateInitializationData() private returns (InitializationData memory) {
        DataForInitialization memory data;

        data.admins = new address[](1);
        data.admins[0] = admin;
        data.owners = new address[](1);
        data.owners[0] = owner;
        data.atomists = new address[](1);
        data.atomists[0] = atomistStub;
        data.iporDaos = new address[](0);
        data.alphas = new address[](0);
        data.whitelist = new address[](0);
        data.guardians = new address[](0);
        data.fuseManagers = new address[](0);
        data.claimRewards = new address[](0);
        data.transferRewardsManagers = new address[](0);
        data.configInstantWithdrawalFusesManagers = new address[](0);
        data.updateMarketsBalancesAccounts = new address[](0);
        data.updateRewardsBalanceAccounts = new address[](0);
        data.withdrawManagerRequestFeeManagers = new address[](0);
        data.withdrawManagerWithdrawFeeManagers = new address[](0);
        data.priceOracleMiddlewareManagers = new address[](0);
        data.preHooksManagers = new address[](0);

        /// @dev Dummy non-zero addresses, the initializer requires every manager address to be set
        address dummyManager = address(0x123);
        data.plasmaVaultAddress = PlasmaVaultAddress({
            plasmaVault: PLASMA_VAULT_STUB,
            accessManager: address(stubAccessManager),
            rewardsClaimManager: dummyManager,
            withdrawManager: dummyManager,
            feeManager: dummyManager,
            contextManager: dummyManager,
            priceOracleMiddlewareManager: dummyManager
        });

        return IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(data);
    }
}
