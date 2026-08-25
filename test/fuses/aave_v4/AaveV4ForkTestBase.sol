// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {
    TransientStorageSetInputsFuse,
    TransientStorageSetInputsFuseEnterData
} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {
    AaveV4SupplyFuse,
    AaveV4SupplyFuseEnterData,
    AaveV4SupplyFuseExitData
} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {
    AaveV4BorrowFuse,
    AaveV4BorrowFuseEnterData,
    AaveV4BorrowFuseExitData
} from "../../../contracts/fuses/aave_v4/AaveV4BorrowFuse.sol";
import {
    AaveV4CollateralFuse,
    AaveV4CollateralFuseEnterData,
    AaveV4CollateralFuseExitData
} from "../../../contracts/fuses/aave_v4/AaveV4CollateralFuse.sol";
import {AaveV4BalanceFuse} from "../../../contracts/fuses/aave_v4/AaveV4BalanceFuse.sol";
import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";

/// @title AaveV4ForkTestBase
/// @notice Shared Ethereum-mainnet fork setup for the Aave V4 fuse tests: a USDC PlasmaVault with the four
///         Aave V4 fuses, the real Bluechip / Main spokes and the Fusion mainnet PriceOracleMiddleware.
/// @dev Fork block 25 800 000 (2026-08-17). Reserve ids and risk parameters were verified on-chain at that block,
///      see docs/superpowers/specs/2026-08-24-il-8054-aave-v4-improvements-design.md (section 2).
abstract contract AaveV4ForkTestBase is Test {
    uint256 internal constant FORK_BLOCK = 25_800_000;

    address internal constant BLUECHIP_SPOKE = 0x973a023A77420ba610f06b3858aD991Df6d85A08;
    address internal constant MAIN_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    address internal constant PRIME_HUB = 0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931;
    address internal constant CORE_HUB = 0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9;

    /// @dev Bluechip spoke reserves: WETH and wstETH are collateral (CF 86% / 85.5%) via the Prime hub,
    ///      USDC is listed twice - reserve 4 (Prime hub) and reserve 7 (Core hub, addCap 0 on this spoke).
    uint256 internal constant BLUECHIP_WETH = 0;
    uint256 internal constant BLUECHIP_WSTETH = 3;
    uint256 internal constant BLUECHIP_USDC_PRIME = 4;
    uint256 internal constant BLUECHIP_USDC_CORE = 7;

    /// @dev Main spoke reserves (Core hub)
    uint256 internal constant MAIN_WETH = 0;
    uint256 internal constant MAIN_USDC = 7;

    /// @dev Fusion mainnet PriceOracleMiddleware (USDC / WETH / wstETH / WBTC / USDT feeds)
    address internal constant PRICE_ORACLE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    uint256 internal constant USER_USDC_DEPOSIT = 100_000e6;
    uint256 internal constant VAULT_WETH_FUNDING = 50e18;

    /// @dev 0.01% relative tolerance for NAV comparisons (oracle rounding)
    uint256 internal constant NAV_TOLERANCE = 1e14;

    address internal atomist = address(0x777);
    address internal alpha = address(0x555);
    address internal user = address(0x333);

    PlasmaVault internal plasmaVault;
    IporFusionAccessManager internal accessManager;
    address internal withdrawManager;

    address internal supplyFuse;
    address internal borrowFuse;
    address internal collateralFuse;
    address internal balanceFuse;
    address internal erc20BalanceFuse;
    address internal setInputsFuse;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        _deployVault();
        _configureVault();
        _fundVault();
    }

    // ============ Setup ============

    function _deployVault() internal {
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: USDC,
            underlyingTokenName: "USDC",
            priceOracleMiddleware: PRICE_ORACLE_MIDDLEWARE,
            atomist: atomist
        });

        vm.startPrank(atomist);
        (plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);
        accessManager = IporFusionAccessManager(plasmaVault.authority());

        IporFusionAccessManagerHelper.RoleAddresses memory roles = IporFusionAccessManagerHelper.RoleAddresses({
            daos: new address[](1),
            admins: new address[](1),
            owners: new address[](1),
            atomists: new address[](1),
            alphas: new address[](1),
            guardians: new address[](1),
            fuseManagers: new address[](1),
            claimRewards: new address[](1),
            transferRewardsManagers: new address[](1),
            configInstantWithdrawalFusesManagers: new address[](1),
            updateMarketsBalancesAccounts: new address[](1),
            updateRewardsBalanceAccounts: new address[](1),
            withdrawManagerRequestFeeManagers: new address[](1),
            withdrawManagerWithdrawFeeManagers: new address[](1),
            priceOracleMiddlewareManagers: new address[](1),
            whitelist: new address[](1),
            preHooksManagers: new address[](1)
        });

        roles.daos[0] = atomist;
        roles.admins[0] = atomist;
        roles.owners[0] = atomist;
        roles.atomists[0] = atomist;
        roles.alphas[0] = alpha;
        roles.guardians[0] = atomist;
        roles.fuseManagers[0] = atomist;
        roles.claimRewards[0] = alpha;
        roles.transferRewardsManagers[0] = alpha;
        roles.configInstantWithdrawalFusesManagers[0] = atomist;
        roles.updateMarketsBalancesAccounts[0] = atomist;
        roles.updateRewardsBalanceAccounts[0] = alpha;
        roles.withdrawManagerRequestFeeManagers[0] = atomist;
        roles.withdrawManagerWithdrawFeeManagers[0] = atomist;
        roles.priceOracleMiddlewareManagers[0] = atomist;
        roles.whitelist[0] = user;
        roles.preHooksManagers[0] = atomist;

        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            plasmaVault,
            roles,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );
        vm.stopPrank();
    }

    function _configureVault() internal {
        supplyFuse = address(new AaveV4SupplyFuse(IporFusionMarkets.AAVE_V4));
        borrowFuse = address(new AaveV4BorrowFuse(IporFusionMarkets.AAVE_V4));
        collateralFuse = address(new AaveV4CollateralFuse(IporFusionMarkets.AAVE_V4));
        balanceFuse = address(new AaveV4BalanceFuse(IporFusionMarkets.AAVE_V4));
        erc20BalanceFuse = address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE));
        setInputsFuse = address(new TransientStorageSetInputsFuse());

        address[] memory fuses = new address[](4);
        fuses[0] = supplyFuse;
        fuses[1] = borrowFuse;
        fuses[2] = collateralFuse;
        fuses[3] = setInputsFuse;

        bytes32[] memory erc20Substrates = new bytes32[](2);
        erc20Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(WETH);
        erc20Substrates[1] = PlasmaVaultConfigLib.addressToBytes32(WSTETH);

        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        vm.startPrank(atomist);
        PlasmaVaultHelper.addFusesToVault(plasmaVault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(plasmaVault, IporFusionMarkets.AAVE_V4, balanceFuse);
        PlasmaVaultHelper.addBalanceFusesToVault(plasmaVault, IporFusionMarkets.ERC20_VAULT_BALANCE, erc20BalanceFuse);
        PlasmaVaultHelper.addSubstratesToMarket(plasmaVault, IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Substrates);
        PlasmaVaultHelper.addSubstratesToMarket(plasmaVault, IporFusionMarkets.AAVE_V4, _defaultGrants());
        PlasmaVaultHelper.addDependencyBalanceGraphs(plasmaVault, IporFusionMarkets.AAVE_V4, dependencies);
        vm.stopPrank();

        vm.label(address(plasmaVault), "PlasmaVault");
        vm.label(BLUECHIP_SPOKE, "AaveV4BluechipSpoke");
        vm.label(MAIN_SPOKE, "AaveV4MainSpoke");
        vm.label(supplyFuse, "AaveV4SupplyFuse");
        vm.label(borrowFuse, "AaveV4BorrowFuse");
        vm.label(collateralFuse, "AaveV4CollateralFuse");
        vm.label(balanceFuse, "AaveV4BalanceFuse");
    }

    /// @dev User deposits USDC; the vault additionally receives WETH (test shortcut for a swapped position).
    function _fundVault() internal {
        deal(USDC, user, 1_000_000e6);

        vm.startPrank(user);
        IERC20(USDC).approve(address(plasmaVault), USER_USDC_DEPOSIT);
        plasmaVault.deposit(USER_USDC_DEPOSIT, user);
        vm.stopPrank();

        deal(WETH, address(plasmaVault), VAULT_WETH_FUNDING);

        _updateBalances();
    }

    /// @dev Default grants: Bluechip WETH + wstETH as collateral, Bluechip USDC (Prime hub) as borrowable
    function _defaultGrants() internal pure virtual returns (bytes32[] memory grants) {
        grants = new bytes32[](3);
        grants[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WETH, true, false);
        grants[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_WSTETH, true, false);
        grants[2] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, BLUECHIP_USDC_PRIME, false, true);
    }

    // ============ Governance helpers ============

    function _grantReserves(bytes32[] memory grants_) internal {
        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(IporFusionMarkets.AAVE_V4, grants_);
    }

    function _updateBalances() internal {
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.AAVE_V4;
        marketIds[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        vm.prank(atomist);
        plasmaVault.updateMarketsBalances(marketIds);
    }

    function _configureInstantWithdraw(address spoke_, address asset_, uint256 reserveId_) internal {
        bytes32[] memory params = new bytes32[](5);
        params[0] = bytes32(0); // amount, set by the vault
        params[1] = PlasmaVaultConfigLib.addressToBytes32(asset_);
        params[2] = PlasmaVaultConfigLib.addressToBytes32(spoke_);
        params[3] = bytes32(reserveId_);
        params[4] = bytes32(0); // minAmount

        InstantWithdrawalFusesParamsStruct[] memory fuses = new InstantWithdrawalFusesParamsStruct[](1);
        fuses[0] = InstantWithdrawalFusesParamsStruct({fuse: supplyFuse, params: params});

        vm.prank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(fuses);
    }

    // ============ Execution helpers ============

    function _execute(FuseAction[] memory actions_) internal {
        vm.prank(alpha);
        plasmaVault.execute(actions_);
    }

    function _executeOne(FuseAction memory action_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = action_;
        _execute(actions);
    }

    function _supplyAction(
        address spoke_,
        address asset_,
        uint256 reserveId_,
        uint256 amount_,
        uint256 minShares_
    ) internal view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: supplyFuse,
                data: abi.encodeWithSignature(
                    "enter((address,address,uint256,uint256,uint256))",
                    AaveV4SupplyFuseEnterData({
                        spoke: spoke_,
                        asset: asset_,
                        reserveId: reserveId_,
                        amount: amount_,
                        minShares: minShares_
                    })
                )
            });
    }

    function _withdrawAction(
        address spoke_,
        address asset_,
        uint256 reserveId_,
        uint256 amount_,
        uint256 minAmount_
    ) internal view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: supplyFuse,
                data: abi.encodeWithSignature(
                    "exit((address,address,uint256,uint256,uint256))",
                    AaveV4SupplyFuseExitData({
                        spoke: spoke_,
                        asset: asset_,
                        reserveId: reserveId_,
                        amount: amount_,
                        minAmount: minAmount_
                    })
                )
            });
    }

    function _borrowAction(
        address spoke_,
        address asset_,
        uint256 reserveId_,
        uint256 amount_,
        uint256 minShares_
    ) internal view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: borrowFuse,
                data: abi.encodeWithSignature(
                    "enter((address,address,uint256,uint256,uint256))",
                    AaveV4BorrowFuseEnterData({
                        spoke: spoke_,
                        asset: asset_,
                        reserveId: reserveId_,
                        amount: amount_,
                        minShares: minShares_
                    })
                )
            });
    }

    function _repayAction(
        address spoke_,
        address asset_,
        uint256 reserveId_,
        uint256 amount_,
        uint256 minSharesRepaid_
    ) internal view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: borrowFuse,
                data: abi.encodeWithSignature(
                    "exit((address,address,uint256,uint256,uint256))",
                    AaveV4BorrowFuseExitData({
                        spoke: spoke_,
                        asset: asset_,
                        reserveId: reserveId_,
                        amount: amount_,
                        minSharesRepaid: minSharesRepaid_
                    })
                )
            });
    }

    function _enableCollateralAction(address spoke_, uint256 reserveId_) internal view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: collateralFuse,
                data: abi.encodeWithSignature(
                    "enter((address,uint256))",
                    AaveV4CollateralFuseEnterData({spoke: spoke_, reserveId: reserveId_})
                )
            });
    }

    function _disableCollateralAction(address spoke_, uint256 reserveId_) internal view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: collateralFuse,
                data: abi.encodeWithSignature(
                    "exit((address,uint256))",
                    AaveV4CollateralFuseExitData({spoke: spoke_, reserveId: reserveId_})
                )
            });
    }

    function _setInputsAction(
        address[] memory fuses_,
        bytes32[][] memory inputsByFuse_
    ) internal view returns (FuseAction memory) {
        return
            FuseAction({
                fuse: setInputsFuse,
                data: abi.encodeWithSignature(
                    "enter((address[],bytes32[][]))",
                    TransientStorageSetInputsFuseEnterData({fuse: fuses_, inputsByFuse: inputsByFuse_})
                )
            });
    }

    /// @dev supply WETH -> enable as collateral -> borrow USDC (Prime hub) on the Bluechip spoke, in one execute
    function _openPosition(uint256 wethSupply_, uint256 usdcBorrow_) internal {
        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = _supplyAction(BLUECHIP_SPOKE, WETH, BLUECHIP_WETH, wethSupply_, 0);
        actions[1] = _enableCollateralAction(BLUECHIP_SPOKE, BLUECHIP_WETH);
        actions[2] = _borrowAction(BLUECHIP_SPOKE, USDC, BLUECHIP_USDC_PRIME, usdcBorrow_, 0);
        _execute(actions);
    }

    // ============ View helpers ============

    function _supplied(address spoke_, uint256 reserveId_) internal view returns (uint256) {
        return IAaveV4Spoke(spoke_).getUserSuppliedAssets(reserveId_, address(plasmaVault));
    }

    function _debt(address spoke_, uint256 reserveId_) internal view returns (uint256) {
        return IAaveV4Spoke(spoke_).getUserTotalDebt(reserveId_, address(plasmaVault));
    }

    function _status(
        address spoke_,
        uint256 reserveId_
    ) internal view returns (bool usingAsCollateral, bool borrowing) {
        return IAaveV4Spoke(spoke_).getUserReserveStatus(reserveId_, address(plasmaVault));
    }

    function _healthFactor(address spoke_) internal view returns (uint256) {
        return IAaveV4Spoke(spoke_).getUserAccountData(address(plasmaVault)).healthFactor;
    }

    /// @dev USD value (WAD) of an asset amount according to the vault's PriceOracleMiddleware
    function _usdValueWad(address asset_, uint256 amount_) internal view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).getAssetPrice(asset_);
        uint256 assetDecimals = asset_ == USDC ? 6 : 18;
        return (amount_ * price * 1e18) / (10 ** (assetDecimals + priceDecimals));
    }

    /// @dev Converts a USD value (WAD) into USDC units (6 decimals) using the oracle USDC price
    function _usdWadToUsdc(uint256 usdWad_) internal view returns (uint256) {
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE).getAssetPrice(USDC);
        return (usdWad_ * (10 ** priceDecimals) * 1e6) / (price * 1e18);
    }

    function _aaveMarketBalance() internal view returns (uint256) {
        return plasmaVault.totalAssetsInMarket(IporFusionMarkets.AAVE_V4);
    }

    function _erc20MarketBalance() internal view returns (uint256) {
        return plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
    }
}
