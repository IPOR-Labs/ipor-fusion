// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FusionFactory} from "../../../contracts/factory/FusionFactory.sol";
import {FusionFactoryStorageLib} from "../../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {AccessManagerFactory} from "../../../contracts/factory/AccessManagerFactory.sol";
import {PriceManagerFactory} from "../../../contracts/factory/PriceManagerFactory.sol";
import {WithdrawManagerFactory} from "../../../contracts/factory/WithdrawManagerFactory.sol";
import {RewardsManagerFactory} from "../../../contracts/factory/RewardsManagerFactory.sol";
import {ContextManagerFactory} from "../../../contracts/factory/ContextManagerFactory.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {ContextManager} from "../../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {BurnRequestFeeFuse} from "../../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

/// @dev All state threaded through the multi-step offline `FusionFactory` bring-up lives in this
/// memory struct (rather than as separate function parameters/locals) specifically to keep every
/// helper function's stack shallow enough to compile without `via_ir` (forbidden repo-wide; see
/// project CLAUDE.md and `[[via-ir-forbidden]]`).
struct FusionFactoryDeployContext {
    address owner;
    address daoFeeManager;
    address underlyingToken;
    FusionFactoryStorageLib.FactoryAddresses factoryAddresses;
    address plasmaVaultBase;
    address priceOracleMiddleware;
    FusionFactory fusionFactory;
}

/// @title HyperCoreFactoryVaultHelper
/// @notice Test-only helper that stands up a fully offline `FusionFactory` (no fork, no live
/// `ipor-abi` registry), mirroring the wiring in `test/factory/FusionFactory.t.sol`'s `setUp()`.
/// Used by `HyperCoreFactoryVaultSimulationTest` so the HyperCore M4 production-configuration
/// checklist can be exercised on a vault actually created *through* the factory's `clone()` path,
/// rather than the minimal hand-rolled `PlasmaVaultHelper.deployMinimalPlasmaVault` fixture used by
/// the other HyperCore offline tests.
library HyperCoreFactoryVaultHelper {
    /// @notice Deploys a fresh, fully-configured `FusionFactory` proxy ready for `clone()`.
    /// @param vm Forge-std cheatcode handle from the calling test (needed for `vm.prank`, since the
    /// factory's admin-gated setup calls must originate from `owner_`/`daoFeeManager_`).
    /// @param owner_ Will hold `DEFAULT_ADMIN_ROLE`/`MAINTENANCE_MANAGER_ROLE` equivalents needed to
    /// finish wiring the factory (matches `FusionFactory.t.sol`'s `owner`/`maintenanceManager`).
    /// @param daoFeeManager_ Account that sets the (zero-fee) DAO fee package used by `clone()`.
    /// @param underlyingToken_ Underlying ERC20 stored in the factory deploy context.
    function deployFusionFactory(
        Vm vm,
        address owner_,
        address daoFeeManager_,
        address underlyingToken_
    ) internal returns (FusionFactory) {
        FusionFactoryDeployContext memory ctx;
        ctx.owner = owner_;
        ctx.daoFeeManager = daoFeeManager_;
        ctx.underlyingToken = underlyingToken_;

        _deployFactoryAddresses(ctx);
        _deployAndInitializeFactory(ctx);
        _grantFactoryRoles(vm, ctx);
        _setZeroFeeDaoPackage(vm, ctx);
        _updateBaseAddresses(vm, ctx);

        return ctx.fusionFactory;
    }

    function _deployFactoryAddresses(FusionFactoryDeployContext memory ctx) private {
        ctx.factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });
        ctx.plasmaVaultBase = address(new PlasmaVaultBase());

        PriceOracleMiddleware priceOracleMiddlewareImpl = new PriceOracleMiddleware(address(0));
        ctx.priceOracleMiddleware = address(
            new ERC1967Proxy(
                address(priceOracleMiddlewareImpl),
                abi.encodeWithSignature("initialize(address)", ctx.owner)
            )
        );
    }

    function _deployAndInitializeFactory(FusionFactoryDeployContext memory ctx) private {
        address burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        address burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        FusionFactory implementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,(address,address,address,address,address,address,address),address,address,address,address)",
            ctx.owner,
            ctx.factoryAddresses,
            ctx.plasmaVaultBase,
            ctx.priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        ctx.fusionFactory = FusionFactory(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _grantFactoryRoles(Vm vm, FusionFactoryDeployContext memory ctx) private {
        vm.startPrank(ctx.owner);
        ctx.fusionFactory.grantRole(ctx.fusionFactory.DAO_FEE_MANAGER_ROLE(), ctx.daoFeeManager);
        ctx.fusionFactory.grantRole(ctx.fusionFactory.MAINTENANCE_MANAGER_ROLE(), ctx.owner);
        vm.stopPrank();
    }

    function _setZeroFeeDaoPackage(Vm vm, FusionFactoryDeployContext memory ctx) private {
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 0,
            performanceFee: 0,
            feeRecipient: address(uint160(uint256(keccak256("HyperCoreFactoryVaultHelper.feeRecipient"))))
        });
        vm.prank(ctx.daoFeeManager);
        ctx.fusionFactory.setDaoFeePackages(packages);
    }

    function _updateBaseAddresses(Vm vm, FusionFactoryDeployContext memory ctx) private {
        address accessManagerBase = address(new IporFusionAccessManager(ctx.owner, 1 seconds));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address priceManagerBase = address(new PriceOracleMiddlewareManager(ctx.owner, ctx.priceOracleMiddleware));
        address plasmaVaultCoreBase = _deployPlasmaVaultCoreBase();
        address rewardsManagerBase = address(new RewardsClaimManager(ctx.owner, plasmaVaultCoreBase));
        address contextManagerBase = _deployContextManagerBase(ctx.owner);

        vm.prank(ctx.owner);
        ctx.fusionFactory.updateBaseAddresses(
            1,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
    }

    function _deployContextManagerBase(address owner_) private returns (address) {
        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = address(1);
        return address(new ContextManager(owner_, approvedAddresses));
    }

    /// @dev `PlasmaVaultFactory.clone()` uses `Clones.clone()` on this address. Like production, the
    /// base is an uninitialized implementation; it is never used for anything else.
    function _deployPlasmaVaultCoreBase() private returns (address plasmaVaultCoreBase) {
        plasmaVaultCoreBase = address(new PlasmaVault());
    }
}
