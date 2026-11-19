// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {HighWaterMarkPerformanceFeeStorage} from "../../contracts/managers/fee/FeeManagerStorageLib.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @title Manual HWM reset only downwards (IL-9667, Olympix L36)
/// @notice updateHighWaterMarkPerformanceFee stored the current rate also above the stored high water mark, so the
///         owner could raise the HWM over a gain that was not crystallized yet and waive the performance fee on it,
///         the IPOR DAO share included. The reset now reverts when the stored HWM is not zero and the current rate is
///         above it; lowering, an equal rate and a zero stored HWM behave as before.
/// @dev The assertions compare the rate with the stored HWM in the unit the FeeManager keeps it in (the rate scale is
///      read from HIGH_WATER_MARK_SCALE(), 1 on a FeeManager built before IL-9601), so the tests run unchanged on the
///      base commit, where the two tests of the upward reset fail.
contract FeeManagerHwmManualResetDirectionTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public owner = address(0x0A11);
    address public user = address(0xA11CE);

    /// @dev 20% performance fee, all of it the IPOR DAO share (FeeManager percentages use 2 decimals, 10000 = 100%)
    uint256 public constant PERFORMANCE_FEE = 2000;

    /// @dev keccak256("HighWaterMarkResetAboveStored(uint256,uint256)"), the FeeManager error of IL-9667
    bytes4 internal constant HIGH_WATER_MARK_RESET_ABOVE_STORED =
        bytes4(keccak256("HighWaterMarkResetAboveStored(uint256,uint256)"));

    /// @dev FeeManagerStorageLib HIGH_WATER_MARK_PERFORMANCE_FEE_SLOT; highWaterMark is the low 128 bits
    bytes32 internal constant HIGH_WATER_MARK_SLOT = 0xb9423b11a8779228bace4bf919d779502e12a07e11bd2f782c23aeac55439c00;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    FeeManager public feeManager;
    address public performanceFeeAccount;
    uint256 public oneShare;
    uint256 public userDeposit;

    function setUp() public {
        _deployVault();
        _deposit();
    }

    /// @dev Regression: a gain in idle puts the rate above the stored HWM; the owner reset reverts with both values
    ///      and leaves the HWM as it was. Before IL-9667 the reset stored the higher rate.
    function testShouldRevertManualResetWhenRateIsAboveStoredHighWaterMark() public {
        asset.mint(address(plasmaVault), userDeposit / 10);
        uint256 storedHighWaterMark = _hwm();
        uint256 rate = _rate();
        assertGt(rate, storedHighWaterMark, "precondition: rate above the stored HWM");

        vm.expectRevert(abi.encodeWithSelector(HIGH_WATER_MARK_RESET_ABOVE_STORED, rate, storedHighWaterMark));
        vm.prank(owner);
        feeManager.updateHighWaterMarkPerformanceFee();

        assertEq(_hwm(), storedHighWaterMark, "HWM unchanged by the refused reset");
    }

    /// @dev Regression on the economic outcome: after the attempted reset the next crystallization still charges the
    ///      performance fee on the gain (20%, the IPOR DAO share) and moves the HWM to the price after the fee mint.
    ///      Before IL-9667 the reset raised the HWM to the rate and the crystallization minted no fee shares.
    function testShouldChargeFeeOnGainWhenManualResetAboveStoredIsAttempted() public {
        uint256 gain = userDeposit / 10;
        asset.mint(address(plasmaVault), gain);

        vm.prank(owner);
        (bool resetSucceeded, ) = address(feeManager).call(
            abi.encodeWithSelector(FeeManager.updateHighWaterMarkPerformanceFee.selector)
        );

        _crystallize();

        uint256 feeShares = plasmaVault.balanceOf(performanceFeeAccount);
        assertGt(feeShares, 0, "the gain is still charged after the attempted reset");
        assertApproxEqRel(
            plasmaVault.convertToAssets(feeShares),
            (gain * PERFORMANCE_FEE) / 10000,
            1e14,
            "the fee shares are worth 20% of the gain"
        );
        assertEq(_hwm(), _rate(), "the crystallization moved the HWM to the price after the fee mint");
        assertFalse(resetSucceeded, "the manual reset over the uncrystallized gain is refused");
    }

    /// @dev Lowering is unchanged (IL-6921): after a loss the reset stores the lower current rate
    function testShouldLowerHighWaterMarkOnManualResetBelowStored() public {
        uint256 storedHighWaterMark = _hwm();
        _loss(userDeposit / 2);
        uint256 rate = _rate();
        assertLt(rate, storedHighWaterMark, "precondition: rate below the stored HWM");

        vm.prank(owner);
        feeManager.updateHighWaterMarkPerformanceFee();

        assertEq(_hwm(), rate, "HWM lowered to the current rate");
    }

    /// @dev Right after a crystallization the rate equals the HWM: the reset is accepted, keeps the HWM and only
    ///      refreshes lastUpdate, as before
    function testShouldAcceptManualResetWhenRateEqualsStoredHighWaterMark() public {
        asset.mint(address(plasmaVault), userDeposit / 10);
        _crystallize();
        uint256 storedHighWaterMark = _hwm();
        assertEq(_rate(), storedHighWaterMark, "precondition: rate at the HWM after the crystallization");

        vm.warp(block.timestamp + 1 hours);
        vm.prank(owner);
        feeManager.updateHighWaterMarkPerformanceFee();

        HighWaterMarkPerformanceFeeStorage memory hwm = feeManager.getPlasmaVaultHighWaterMarkPerformanceFee();
        assertEq(hwm.highWaterMark, storedHighWaterMark, "HWM unchanged");
        assertEq(hwm.lastUpdate, block.timestamp, "lastUpdate refreshed by the reset");
    }

    /// @dev A zero stored HWM (not initialized) is set to the current rate, whatever it is
    function testShouldSetHighWaterMarkOnManualResetWhenStoredIsZero() public {
        asset.mint(address(plasmaVault), userDeposit / 10);
        _clearStoredHighWaterMark();
        assertEq(_hwm(), 0, "precondition: zero stored HWM");

        vm.prank(owner);
        feeManager.updateHighWaterMarkPerformanceFee();

        assertEq(_hwm(), _rate(), "zero HWM set to the current rate");
        assertGt(_hwm(), 0, "HWM is not zero after the reset");
    }

    // ---------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Share price in the HWM unit: assets per 10 ** decimals() shares times the FeeManager rate scale
    function _rate() internal view returns (uint256) {
        return plasmaVault.convertToAssets(oneShare * _hwmScale());
    }

    /// @dev HIGH_WATER_MARK_SCALE() of the FeeManager (IL-9601); 1 on a FeeManager without it
    function _hwmScale() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(feeManager).staticcall(
            abi.encodeWithSignature("HIGH_WATER_MARK_SCALE()")
        );
        return ok && data.length == 32 ? abi.decode(data, (uint256)) : 1;
    }

    function _hwm() internal view returns (uint256) {
        return feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
    }

    function _crystallize() internal {
        vm.prank(alpha);
        plasmaVault.execute(new FuseAction[](0));
    }

    function _loss(uint256 amount_) internal {
        vm.prank(address(plasmaVault));
        asset.transfer(address(0xdead), amount_);
    }

    function _clearStoredHighWaterMark() internal {
        uint256 word = uint256(vm.load(address(feeManager), HIGH_WATER_MARK_SLOT));
        vm.store(address(feeManager), HIGH_WATER_MARK_SLOT, bytes32((word >> 128) << 128));
    }

    function _deposit() internal {
        asset.mint(user, userDeposit);
        vm.startPrank(user);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(userDeposit, user);
        vm.stopPrank();
    }

    function _deployVault() internal {
        asset = new MockERC20Decimals("Mock Asset", "mA", 6);
        userDeposit = 1_000_000 * 10 ** 6;

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mA",
                "ipfmA",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({marketId: 1, fuse: address(new ZeroBalanceFuse(1))});
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            new address[](0),
            balanceFuses,
            new MarketSubstratesConfig[](0)
        );

        performanceFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        feeManager = FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER());
        oneShare = 10 ** uint256(plasmaVault.decimals());

        /// @dev The production initializer (IporFusionAccessManagerInitializerLibV1) maps the reset to OWNER_ROLE;
        ///      RoleLib maps it to ALPHA_ROLE
        bytes4[] memory resetSig = new bytes4[](1);
        resetSig[0] = FeeManager.updateHighWaterMarkPerformanceFee.selector;
        accessManager.setTargetFunctionRole(address(feeManager), resetSig, Roles.OWNER_ROLE);
        accessManager.grantRole(Roles.OWNER_ROLE, owner, 0);
    }
}
