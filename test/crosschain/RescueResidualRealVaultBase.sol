// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {RescueModule} from "../../contracts/crosschain/lib/RescueModule.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";

/// @title RescueResidualRealVaultBase
/// @notice IL-9654 setup of the residual-recovery suites: a real `PlasmaVault` with a real `IporFusionAccessManager`
///         and a real `WithdrawManager` (wired to the vault the way the factory wires it), a rescue host (a
///         dispatcher, supplied by the transport subclass) that holds shares of that vault, and helpers for the
///         rescue queue. It is self-contained: it imports nothing from the other IL-9654 suites.
/// @dev The residual is created the way it arises in production: ALPHA releases a reserve equal to the whole
///      supply (`WithdrawManager.releaseFunds`), so a plain `redeem` fails on the reserve, and the vault is then
///      removed from the host, whose sweep cannot redeem anything. The position stays on the host outside both of
///      its vault sets. The tests never pin the reason code of the sweep.
abstract contract RescueResidualRealVaultBase is Test {
    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant FEE_MANAGER = address(0xFEE0);
    address internal constant RECEIVER = address(0xBEEF);
    uint256 internal constant RESCUE_DELAY = 3 days;
    uint256 internal constant WITHDRAW_WINDOW = 10 days;
    /// @dev The deposit that creates the position, in whole asset units.
    uint256 internal constant DEPOSIT_UNITS = 100;

    MockERC20 internal asset;
    PlasmaVault internal vault;
    WithdrawManager internal withdrawManager;
    IporFusionAccessManager internal accessManager;

    /// @dev The rescue host that holds the shares (a dispatcher).
    function _host() internal view virtual returns (address);

    /// @dev The rescue admin of the host.
    function _admin() internal view virtual returns (address);

    /// @dev Makes the host allowlist and track `vault`, through the transport's own route (a command, not a rescue).
    function _trackVault() internal virtual;

    /// @dev Removes `vault` from the host's allowlist through the transport's own route; the host sweeps and untracks.
    function _removeVault() internal virtual;

    function _isTracked() internal view virtual returns (bool);

    function _isAllowed() internal view virtual returns (bool);

    function _rescue() internal view returns (RescueModule) {
        return RescueModule(payable(_host()));
    }

    function _schedule(address target_, bytes memory callData_) internal returns (uint256 id) {
        vm.prank(_admin());
        id = _rescue().scheduleRescue(target_, 0, callData_);
    }

    function _execute(uint256 id_, bytes memory callData_) internal {
        vm.prank(_admin());
        _rescue().executeRescue(id_, callData_);
    }

    function _expectScheduleRevert(address target_, bytes memory callData_, bytes memory error_) internal {
        vm.expectRevert(error_);
        vm.prank(_admin());
        _rescue().scheduleRescue(target_, 0, callData_);
    }

    function _expectExecuteRevert(uint256 id_, bytes memory callData_, bytes memory error_) internal {
        vm.expectRevert(error_);
        vm.prank(_admin());
        _rescue().executeRescue(id_, callData_);
    }

    function _warpTimelock() internal {
        vm.warp(block.timestamp + RESCUE_DELAY);
    }

    /// @dev A third party deposits for the host: the host ends up with shares without any transport command, which is
    ///      all the residual needs.
    function _depositForHost() internal returns (uint256 shares) {
        uint256 amount = DEPOSIT_UNITS * 10 ** asset.decimals();
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(amount, _host());
        shares = vault.balanceOf(_host());
        assertGt(shares, 0, "host holds shares");
    }

    /// @dev Tops up the host's own ASSET backing by `units_` whole units (a transport may already hold some), so an
    ///      ASSET-floor assertion is not vacuous. The recovery of vault shares must never touch it: the vault pays
    ///      the rescue receiver, not the host. Returns the host's ASSET balance after the top-up.
    function _fundHostAsset(uint256 units_) internal returns (uint256 backing) {
        uint256 before = asset.balanceOf(_host());
        asset.mint(_host(), units_ * 10 ** asset.decimals());
        backing = asset.balanceOf(_host());
        assertGt(backing, before, "host ASSET backing topped up");
    }

    /// @dev ASSET floor after a recovery step: the host's ASSET balance is exactly the backing it had before, so the
    ///      non-worsening floor holds and nothing leaked out of (or was swept into) the host.
    function _assertHostAssetFloor(uint256 backing_, string memory step_) internal view {
        assertGt(backing_, 0, "meaningful ASSET backing");
        assertEq(asset.balanceOf(_host()), backing_, step_);
    }

    /// @dev ALPHA reserves `shares_` for withdrawal requests, stamped one second before now.
    function _release(uint256 shares_) internal {
        vm.warp(block.timestamp + 2);
        vm.prank(ALPHA);
        withdrawManager.releaseFunds(block.timestamp - 1, shares_);
    }

    /// @dev Builds the residual: shares on the host, vault tracked, reserve = whole supply, vault removed.
    function _createResidual() internal returns (uint256 shares) {
        shares = _depositForHost();
        _trackVault();
        assertTrue(_isTracked(), "vault tracked before removal");
        _release(vault.totalSupply());
        _removeVault();
        _assertResidual(shares);
    }

    function _assertResidual(uint256 shares_) internal view {
        assertFalse(_isTracked(), "vault no longer tracked");
        assertFalse(_isAllowed(), "vault no longer allowlisted");
        assertEq(vault.balanceOf(_host()), shares_, "the whole position stays on the host");
    }

    function _setRequestFee(uint256 fee_) internal {
        vm.prank(FEE_MANAGER);
        withdrawManager.updateRequestFee(fee_);
    }

    /// @dev Real access manager, vault and WithdrawManager. The manager is wired to the vault with
    ///      `updatePlasmaVaultAddress`, as `FusionFactoryLogicLib` does, and gets a request-fee role holder.
    function _deployVault(MockERC20 asset_) internal {
        asset = asset_;
        accessManager = new IporFusionAccessManager(ATOMIST, 0);
        withdrawManager = new WithdrawManager(address(accessManager));

        PriceOracleMiddleware oracleImpl = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(oracleImpl), abi.encodeWithSignature("initialize(address)", ATOMIST)))
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset_);
        address[] memory sources = new address[](1);
        sources[0] = address(new MutableValuePriceFeed(1e18));
        vm.prank(ATOMIST);
        oracle.setAssetsPricesSources(assets, sources);

        address plasmaVaultBase = vm.deployCode("PlasmaVaultBase.sol:PlasmaVaultBase");
        address feeFactory = vm.deployCode("FeeManagerFactory.sol:FeeManagerFactory");
        vault = PlasmaVaultCloneLib.clone(vm.deployCode("PlasmaVault.sol:PlasmaVault"));

        vm.startPrank(ATOMIST);
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Residual Recovery Vault",
                assetSymbol: "rrv",
                underlyingToken: address(asset_),
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
        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(vault));
        IporFusionAccessManagerHelper.RoleAddresses memory roles = IporFusionAccessManagerHelper
            .createDefaultRoleAddresses();
        roles.withdrawManagerRequestFeeManagers = new address[](1);
        roles.withdrawManagerRequestFeeManagers[0] = FEE_MANAGER;
        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            vault,
            roles,
            address(withdrawManager),
            address(rewardsClaimManager)
        );
        withdrawManager.updatePlasmaVaultAddress(address(vault));
        withdrawManager.updateWithdrawWindow(WITHDRAW_WINDOW);
        vm.stopPrank();
    }
}
