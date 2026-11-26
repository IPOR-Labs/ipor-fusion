// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {FeeManager} from "../../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {RecipientFee} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {ContextManager} from "../../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {UniversalReader} from "../../../contracts/universal_reader/UniversalReader.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {
    ReserveVaultSupplyFuse,
    ReserveVaultSupplyFuseEnterData,
    ReserveVaultSupplyFuseExitData
} from "../../../contracts/fuses/reserve_vault/ReserveVaultSupplyFuse.sol";
import {ReserveVaultBalanceFuse} from "../../../contracts/fuses/reserve_vault/ReserveVaultBalanceFuse.sol";
import {ReserveVaultBoostBalanceFuse} from "../../../contracts/fuses/reserve_vault/ReserveVaultBoostBalanceFuse.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    InitializationData,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MutableValuePriceFeed} from "../../managers/MutableValuePriceFeed.sol";

/// @dev Reusable harness of the reserve vault fuse family. No fork, no mocks of vaults: three real PlasmaVault clones.
///      - C is the reserve vault (market 61: `ReserveVaultSupplyFuse` + `ReserveVaultBalanceFuse`, substrates A and B).
///      - A and B are member vaults (market 62: one `ReserveVaultBoostBalanceFuse` instance, substrate C; and the
///        standard ERC4626 market `ERC4626_0001` with substrate C, so a member vault can deposit into C).
///      Each vault has its own `IporFusionAccessManager` (one-day redemption delay), `WithdrawManager`, `FeeManager`
///      (zero fees), `PriceOracleMiddleware` and a `MutableValuePriceFeed` for USDC (1 USD, 18 decimals).
///      A and B are non-public (whitelist: users and C); C is non-public (whitelist: A, B and one investor, so that C
///      has real shares and its own exchange rate can be observed). C has `UPDATE_MARKETS_BALANCES_ROLE` on A and B and
///      is exempt from their redemption delay; no vault has a withdraw request flow.
///      Subclasses change the setup with the virtual knobs `_configureFeesA` and `_cExemptFromRedemptionDelay`, and add a
///      pre-hook, a market, a fuse or a fee with `_setPreHook`, `_addMarket`, `_addFuse` and `_setPerformanceFee`
///      without editing this file.
abstract contract ReserveVaultTestBase is Test {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    /// @dev Redemption delay of every vault's access manager
    uint256 internal constant DELAY = 1 days;

    /// @dev Scenario constants (USDC, 6 decimals)
    uint256 internal constant USERS_DEPOSIT = 1_011_111_111;
    uint256 internal constant PRINCIPAL = 100_000_000;
    uint256 internal constant LOSS = 111_111_111;
    uint256 internal constant GAIN = 111_111_111;

    uint256 internal constant RESERVE_MARKET = IporFusionMarkets.RESERVE_VAULT;
    uint256 internal constant BOOST_MARKET = IporFusionMarkets.RESERVE_VAULT_BOOST;
    uint256 internal constant ERC4626_MARKET = IporFusionMarkets.ERC4626_0001;

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant OWNER = TestAddresses.OWNER;
    address internal constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address internal constant USER = TestAddresses.USER;
    address internal constant USER_2 = address(0x05E2);
    address internal constant C_INVESTOR = address(0xC1);
    address internal constant OUTSIDER = address(0x0B51DE);
    address internal constant SINK = address(0x5111C);
    address internal constant FEE_RECIPIENT = TestAddresses.FEE_RECIPIENT_ADDRESS;

    MockERC20 internal usdc;

    PlasmaVault internal vaultA;
    PlasmaVault internal vaultB;
    PlasmaVault internal vaultC;

    IporFusionAccessManager internal accessManagerA;
    IporFusionAccessManager internal accessManagerB;
    IporFusionAccessManager internal accessManagerC;

    WithdrawManager internal withdrawManagerA;
    WithdrawManager internal withdrawManagerB;
    WithdrawManager internal withdrawManagerC;

    /// @dev USDC price feeds (18 decimals, 1e18 = 1 USD); change a price with `feedX.setPrice`
    MutableValuePriceFeed internal feedA;
    MutableValuePriceFeed internal feedB;
    MutableValuePriceFeed internal feedC;

    ReserveVaultSupplyFuse internal supplyFuse;
    ReserveVaultBalanceFuse internal balanceFuse;
    ReserveVaultBoostBalanceFuse internal boostFuse;
    Erc4626SupplyFuse internal erc4626SupplyFuse;
    Erc4626BalanceFuse internal erc4626BalanceFuse;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        address plasmaVaultImpl = vm.deployCode("PlasmaVault.sol:PlasmaVault");
        vaultA = PlasmaVaultCloneLib.clone(plasmaVaultImpl);
        vaultB = PlasmaVaultCloneLib.clone(plasmaVaultImpl);
        vaultC = PlasmaVaultCloneLib.clone(plasmaVaultImpl);
        vm.label(address(vaultA), "vaultA");
        vm.label(address(vaultB), "vaultB");
        vm.label(address(vaultC), "vaultC");

        address[] memory whitelistAB = new address[](3);
        whitelistAB[0] = USER;
        whitelistAB[1] = USER_2;
        whitelistAB[2] = address(vaultC);
        address[] memory whitelistC = new address[](3);
        whitelistC[0] = address(vaultA);
        whitelistC[1] = address(vaultB);
        whitelistC[2] = C_INVESTOR;

        address[] memory updatersAB = new address[](2);
        updatersAB[0] = ATOMIST;
        updatersAB[1] = address(vaultC);
        address[] memory updatersC = new address[](1);
        updatersC[0] = ATOMIST;

        (accessManagerA, withdrawManagerA, feedA) = _deployVault(vaultA, "Member A", whitelistAB, updatersAB);
        (accessManagerB, withdrawManagerB, feedB) = _deployVault(vaultB, "Member B", whitelistAB, updatersAB);
        (accessManagerC, withdrawManagerC, feedC) = _deployVault(vaultC, "Reserve C", whitelistC, updatersC);

        supplyFuse = new ReserveVaultSupplyFuse(RESERVE_MARKET, BOOST_MARKET);
        balanceFuse = new ReserveVaultBalanceFuse(RESERVE_MARKET);
        boostFuse = new ReserveVaultBoostBalanceFuse(BOOST_MARKET);
        erc4626SupplyFuse = new Erc4626SupplyFuse(ERC4626_MARKET);
        erc4626BalanceFuse = new Erc4626BalanceFuse(ERC4626_MARKET);

        // C: market 61 with A and B as substrates
        address[] memory membersAB = new address[](2);
        membersAB[0] = address(vaultA);
        membersAB[1] = address(vaultB);
        _addFuse(vaultC, address(supplyFuse));
        _addMarket(vaultC, RESERVE_MARKET, address(balanceFuse), _toSubstrates(membersAB));

        // A and B: market 62 (boost, substrate C) and the standard ERC4626 market (substrate C)
        address[] memory reserveC = new address[](1);
        reserveC[0] = address(vaultC);
        _addFuse(vaultA, address(erc4626SupplyFuse));
        _addFuse(vaultB, address(erc4626SupplyFuse));
        _addMarket(vaultA, BOOST_MARKET, address(boostFuse), _toSubstrates(reserveC));
        _addMarket(vaultB, BOOST_MARKET, address(boostFuse), _toSubstrates(reserveC));
        _addMarket(vaultA, ERC4626_MARKET, address(erc4626BalanceFuse), _toSubstrates(reserveC));
        _addMarket(vaultB, ERC4626_MARKET, address(erc4626BalanceFuse), _toSubstrates(reserveC));

        // C is allowed to pull its principal out of A and B in the same block it deposited
        if (_cExemptFromRedemptionDelay()) {
            address[] memory exempt = new address[](1);
            exempt[0] = address(vaultC);
            vm.startPrank(OWNER);
            PlasmaVaultGovernance(address(vaultA)).setRedemptionDelayExemption(exempt, true);
            PlasmaVaultGovernance(address(vaultB)).setRedemptionDelayExemption(exempt, true);
            vm.stopPrank();
        }

        _configureFeesA();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Virtual knobs
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Called at the end of `setUp`; the default leaves A with zero fees. Override and call `_setPerformanceFee`.
    function _configureFeesA() internal virtual {}

    /// @dev Whether C is exempt from the redemption delay of A and B (default true)
    function _cExemptFromRedemptionDelay() internal pure virtual returns (bool) {
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `who_` deposits `assets_` of USDC into `vault_` (the receiver is `who_`)
    function _deposit(PlasmaVault vault_, address who_, uint256 assets_) internal returns (uint256 shares) {
        usdc.mint(who_, assets_);
        vm.startPrank(who_);
        usdc.approve(address(vault_), assets_);
        shares = vault_.deposit(assets_, who_);
        vm.stopPrank();
    }

    /// @dev USER deposits into A
    function _userDeposit(uint256 assets_) internal returns (uint256) {
        return _deposit(vaultA, USER, assets_);
    }

    /// @dev USER deposits into B
    function _userDepositB(uint256 assets_) internal returns (uint256) {
        return _deposit(vaultB, USER, assets_);
    }

    /// @dev The investor deposits into C, which gives C real shares (C is non-public, the investor is whitelisted)
    function _fundC(uint256 assets_) internal returns (uint256) {
        return _deposit(vaultC, C_INVESTOR, assets_);
    }

    /// @dev C's Alpha runs one fuse action on `vault_`
    function _execute(PlasmaVault vault_, address fuse_, bytes memory data_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse_, data_);
        vm.prank(ALPHA);
        vault_.execute(actions);
    }

    /// @dev `ReserveVaultSupplyFuse.enter` through `C.execute`
    function _reserveEnter(PlasmaVault member_, uint256 amount_) internal {
        _execute(
            vaultC,
            address(supplyFuse),
            abi.encodeCall(ReserveVaultSupplyFuse.enter, (ReserveVaultSupplyFuseEnterData(address(member_), amount_)))
        );
    }

    /// @dev `ReserveVaultSupplyFuse.exit` through `C.execute`
    function _reserveExit(PlasmaVault member_, uint256 amount_) internal {
        _execute(
            vaultC,
            address(supplyFuse),
            abi.encodeCall(ReserveVaultSupplyFuse.exit, (ReserveVaultSupplyFuseExitData(address(member_), amount_)))
        );
    }

    /// @dev A member vault deposits `amount_` into C with the standard `Erc4626SupplyFuse` (market `ERC4626_0001`)
    function _memberDepositToC(PlasmaVault member_, uint256 amount_) internal {
        _execute(
            member_,
            address(erc4626SupplyFuse),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(vaultC), amount_, 0)))
        );
    }

    /// @dev Loss of `vault_`: USDC leaves the vault
    function _loss(PlasmaVault vault_, uint256 amount_) internal {
        vm.prank(address(vault_));
        usdc.transfer(SINK, amount_);
    }

    /// @dev Gain of `vault_`: USDC is minted to the vault
    function _gain(PlasmaVault vault_, uint256 amount_) internal {
        usdc.mint(address(vault_), amount_);
    }

    /// @dev Scenario of the loss case: users deposit into A, C is funded and enters `PRINCIPAL` into A
    function _setUpPrincipalInA() internal {
        _userDeposit(USERS_DEPOSIT);
        _fundC(PRINCIPAL);
        _reserveEnter(vaultA, PRINCIPAL);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Principal that C recorded for `member_`, read through `C.read`
    function _principal(PlasmaVault member_) internal view returns (uint256) {
        return
            abi.decode(
                UniversalReader(address(vaultC))
                    .read(address(supplyFuse), abi.encodeCall(ReserveVaultSupplyFuse.getPrincipal, (address(member_))))
                    .data,
                (uint256)
            );
    }

    /// @dev Transient boost that C holds for `member_`, read through `C.read`
    function _boost(PlasmaVault member_) internal view returns (uint256) {
        return
            abi.decode(
                UniversalReader(address(vaultC))
                    .read(
                        address(boostFuse),
                        abi.encodeCall(ReserveVaultBoostBalanceFuse.readBoost, (address(member_)))
                    )
                    .data,
                (uint256)
            );
    }

    /// @dev Value of 1e8 shares in assets (shares have 8 decimals, USDC 6)
    function _sharePrice(PlasmaVault vault_) internal view returns (uint256) {
        return vault_.convertToAssets(1e8);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Configuration helpers for subclasses
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Sets one pre-hook (ATOMIST holds PRE_HOOKS_MANAGER_ROLE) on one selector with no substrates
    function _setPreHook(PlasmaVault vault_, bytes4 selector_, address hook_) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector_;
        address[] memory implementations = new address[](1);
        implementations[0] = hook_;
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(address(vault_)).setPreHookImplementations(selectors, implementations, substrates);
    }

    /// @dev Adds a fuse to `vault_`
    function _addFuse(PlasmaVault vault_, address fuse_) internal {
        address[] memory fuses = new address[](1);
        fuses[0] = fuse_;
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vault_)).addFuses(fuses);
    }

    /// @dev Adds a balance fuse for `marketId_` to `vault_` and grants the market substrates (skipped when empty)
    function _addMarket(
        PlasmaVault vault_,
        uint256 marketId_,
        address balanceFuse_,
        bytes32[] memory substrates_
    ) internal {
        vm.startPrank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vault_)).addBalanceFuse(marketId_, balanceFuse_);
        if (substrates_.length > 0) {
            PlasmaVaultGovernance(address(vault_)).grantMarketSubstrates(marketId_, substrates_);
        }
        vm.stopPrank();
    }

    /// @dev Sets the performance fee (100 = 1%) of `vault_` through its FeeManager (ATOMIST), one recipient
    function _setPerformanceFee(PlasmaVault vault_, uint256 fee_) internal {
        address feeAccount = PlasmaVaultGovernance(address(vault_)).getPerformanceFeeData().feeAccount;
        RecipientFee[] memory recipients = new RecipientFee[](1);
        recipients[0] = RecipientFee(FEE_RECIPIENT, fee_);
        // Read the fee manager before the prank: `vm.prank` applies to the next call only, and a nested read
        // while the call arguments are evaluated would consume it.
        FeeManager feeManager = FeeManager(FeeAccount(feeAccount).FEE_MANAGER());
        vm.prank(ATOMIST);
        feeManager.updatePerformanceFee(recipients);
    }

    function _toSubstrates(address[] memory addresses_) internal pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](addresses_.length);
        for (uint256 i; i < addresses_.length; ++i) {
            substrates[i] = PlasmaVaultConfigLib.addressToBytes32(addresses_[i]);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Initializes a cloned PlasmaVault with its own access manager (one-day delay), WithdrawManager, FeeManager
    ///      (zero fees) and price oracle; the vault is non-public with the given whitelist and market balance updaters
    function _deployVault(
        PlasmaVault vault_,
        string memory name_,
        address[] memory whitelist_,
        address[] memory updatersOfMarkets_
    )
        private
        returns (IporFusionAccessManager accessManager, WithdrawManager withdrawManager, MutableValuePriceFeed feed)
    {
        accessManager = new IporFusionAccessManager(ATOMIST, DELAY);
        withdrawManager = new WithdrawManager(address(accessManager));

        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(
                    address(new PriceOracleMiddleware(address(0))),
                    abi.encodeWithSignature("initialize(address)", ATOMIST)
                )
            )
        );
        feed = new MutableValuePriceFeed(1e18);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        address[] memory sources = new address[](1);
        sources[0] = address(feed);
        vm.prank(ATOMIST);
        oracle.setAssetsPricesSources(assets, sources);

        address plasmaVaultBase = vm.deployCode("PlasmaVaultBase.sol:PlasmaVaultBase");
        address feeFactory = vm.deployCode("FeeManagerFactory.sol:FeeManagerFactory");

        vm.startPrank(ATOMIST);
        vault_.proxyInitialize(
            PlasmaVaultInitData({
                assetName: name_,
                assetSymbol: "vRV",
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(oracle),
                feeConfig: FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: feeFactory,
                    iporDaoFeeRecipientAddress: TestAddresses.IPOR_DAO_FEE_RECIPIENT_ADDRESS
                }),
                accessManager: address(accessManager),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: address(withdrawManager),
                plasmaVaultVotesPlugin: address(0)
            })
        );
        _initRoles(accessManager, vault_, withdrawManager, whitelist_, updatersOfMarkets_);
        vm.stopPrank();

        vm.prank(ATOMIST);
        withdrawManager.updatePlasmaVaultAddress(address(vault_));
        address feeAccount = PlasmaVaultGovernance(address(vault_)).getPerformanceFeeData().feeAccount;
        FeeManager(FeeAccount(feeAccount).FEE_MANAGER()).initialize();
    }

    /// @dev Same as `IporFusionAccessManagerHelper.setupInitRoles`, but with `isPublic: false`. Runs as ATOMIST.
    function _initRoles(
        IporFusionAccessManager accessManager_,
        PlasmaVault vault_,
        WithdrawManager withdrawManager_,
        address[] memory whitelist_,
        address[] memory updatersOfMarkets_
    ) private {
        IporFusionAccessManagerHelper.RoleAddresses memory roles = IporFusionAccessManagerHelper
            .createDefaultRoleAddresses();
        roles.whitelist = whitelist_;
        roles.updateMarketsBalancesAccounts = updatersOfMarkets_;

        address[] memory approved = new address[](1);
        approved[0] = address(vault_);
        ContextManager contextManager = new ContextManager(address(accessManager_), approved);
        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(address(accessManager_), address(vault_));
        PlasmaVaultGovernance(address(vault_)).setRewardsClaimManagerAddress(address(rewardsClaimManager));

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(
                DataForInitialization({
                    isPublic: false,
                    iporDaos: roles.daos,
                    admins: roles.admins,
                    owners: roles.owners,
                    atomists: roles.atomists,
                    alphas: roles.alphas,
                    whitelist: roles.whitelist,
                    guardians: roles.guardians,
                    fuseManagers: roles.fuseManagers,
                    claimRewards: roles.claimRewards,
                    transferRewardsManagers: roles.transferRewardsManagers,
                    configInstantWithdrawalFusesManagers: roles.configInstantWithdrawalFusesManagers,
                    updateMarketsBalancesAccounts: roles.updateMarketsBalancesAccounts,
                    updateRewardsBalanceAccounts: roles.updateRewardsBalanceAccounts,
                    withdrawManagerRequestFeeManagers: roles.withdrawManagerRequestFeeManagers,
                    withdrawManagerWithdrawFeeManagers: roles.withdrawManagerWithdrawFeeManagers,
                    priceOracleMiddlewareManagers: roles.priceOracleMiddlewareManagers,
                    preHooksManagers: roles.preHooksManagers,
                    plasmaVaultAddress: PlasmaVaultAddress({
                        plasmaVault: address(vault_),
                        accessManager: address(accessManager_),
                        rewardsClaimManager: address(rewardsClaimManager),
                        withdrawManager: address(withdrawManager_),
                        feeManager: FeeAccount(
                            PlasmaVaultGovernance(address(vault_)).getPerformanceFeeData().feeAccount
                        ).FEE_MANAGER(),
                        contextManager: address(contextManager),
                        priceOracleMiddlewareManager: address(0x123)
                    })
                })
            );
        accessManager_.initialize(initializationData);
    }
}
