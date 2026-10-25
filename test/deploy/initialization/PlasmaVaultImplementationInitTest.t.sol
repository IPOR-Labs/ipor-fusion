// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";

/// @title PlasmaVaultImplementationInitTest
/// @notice IL-8979: the PlasmaVault implementation must be locked, only clones can be initialized (once).
contract PlasmaVaultImplementationInitTest is Test {
    address private constant _ATOMIST = address(0xA11CE);

    MockERC20 private _underlying;

    function setUp() public {
        _underlying = new MockERC20("Mock Token", "MTK", 18);
    }

    function testImplementationRejectsProxyInitialize() public {
        // given
        PlasmaVault implementation = new PlasmaVault();
        PlasmaVaultInitData memory initData = _initData();

        // when / then
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.proxyInitialize(initData);
    }

    function testCloneInitializesOnce() public {
        // given
        PlasmaVault vault = PlasmaVaultCloneLib.newPlasmaVault();
        PlasmaVaultInitData memory initData = _initData();

        // when
        vault.proxyInitialize(initData);

        // then
        assertEq(vault.asset(), address(_underlying), "asset");
        assertEq(vault.name(), "Mock Token Plasma Vault", "name");

        // when / then: a second initialization of the same clone is rejected
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.proxyInitialize(initData);
    }

    function _initData() private returns (PlasmaVaultInitData memory) {
        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();
        address accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        address withdrawManager = address(new WithdrawManager(accessManager));

        return
            PlasmaVaultInitData({
                assetName: "Mock Token Plasma Vault",
                assetSymbol: "MTK-PV",
                underlyingToken: address(_underlying),
                priceOracleMiddleware: address(new PriceOracleMiddleware(address(0))),
                feeConfig: feeConfig,
                accessManager: accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            });
    }
}
