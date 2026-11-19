// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {IPlasmaVaultGovernance} from "../../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {
    MoonwellSupplyFuseEnterData,
    MoonwellSupplyFuseExitData
} from "../../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {MoonwellHelper, MoonWellAddresses} from "../../test_helpers/MoonwellHelper.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @title MoonwellSupplyFuseInstantWithdrawCashForkTest
/// @notice IL-9563: the instant withdraw path of MoonwellSupplyFuse caps each request at the mToken cash (the
///         underlying held by the mToken), reads the redeem result the right way round (0 is success) and the ALPHA
///         exit reverts on a redeem error code. Real Moonwell mUSDC on Base, a real PlasmaVault and the real
///         withdrawFromMarkets loop with a second instant withdraw entry (Steakhouse Prime USDC, ERC4626).
///         The mToken cash is set with `deal` of the underlying to the mToken.
/// forge-config: default.isolate = true
contract MoonwellSupplyFuseInstantWithdrawCashForkTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 private constant _FORK_BLOCK = 52_588_000;
    address private constant _USDC = TestAddresses.BASE_USDC;
    address private constant _M_USDC = TestAddresses.BASE_M_USDC;
    /// @dev Steakhouse Prime USDC (Morpho Vaults V2) on Base, the second instant withdraw entry
    address private constant _ERC4626_VAULT = 0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9;
    address private constant _USER = TestAddresses.USER;

    /// @dev Moonwell (Compound V2) error code TOKEN_INSUFFICIENT_CASH
    uint256 private constant _TOKEN_INSUFFICIENT_CASH = 14;

    PlasmaVault private _plasmaVault;
    PriceOracleMiddleware private _priceOracleMiddleware;
    address private _moonwellFuse;
    address private _erc4626Fuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), _FORK_BLOCK);

        vm.startPrank(TestAddresses.ATOMIST);
        _priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            TestAddresses.ATOMIST,
            address(0)
        );
        _priceOracleMiddleware.addSource(_USDC, TestAddresses.BASE_CHAINLINK_USDC_PRICE);

        address withdrawManager;
        (_plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(
            DeployMinimalPlasmaVaultParams({
                underlyingToken: _USDC,
                underlyingTokenName: "USDC",
                priceOracleMiddleware: _priceOracleMiddleware.addressOf(),
                atomist: TestAddresses.ATOMIST
            })
        );
        IporFusionAccessManager accessManager = _plasmaVault.accessManagerOf();
        accessManager.setupInitRoles(
            _plasmaVault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(_plasmaVault)))
        );
        vm.stopPrank();

        address[] memory mTokens = new address[](1);
        mTokens[0] = _M_USDC;
        MoonWellAddresses memory moonwell = MoonwellHelper.addSupplyToMarket(_plasmaVault, mTokens, vm);
        _moonwellFuse = moonwell.suppluFuse;

        _erc4626Fuse = address(new Erc4626SupplyFuse(IporFusionMarkets.ERC4626_0001));
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_ERC4626_VAULT);
        address[] memory fuses = new address[](1);
        fuses[0] = _erc4626Fuse;
        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _plasmaVault.addSubstratesToMarket(IporFusionMarkets.ERC4626_0001, substrates);
        _plasmaVault.addFusesToVault(fuses);
        _plasmaVault.addBalanceFusesToVault(
            IporFusionMarkets.ERC4626_0001,
            address(new Erc4626BalanceFuse(IporFusionMarkets.ERC4626_0001))
        );
        vm.stopPrank();

        deal(_USDC, _USER, 10_000e6);
        vm.startPrank(_USER);
        IERC20(_USDC).approve(address(_plasmaVault), 10_000e6);
        _plasmaVault.deposit(10_000e6, _USER);
        vm.stopPrank();

        _allocate(6_000e6, 4_000e6);
    }

    /// @notice Case 1: Moonwell (cash 3,000, position 6,000) is the first entry, the ERC4626 venue (4,000) the
    ///         second: the withdrawal draws the Moonwell cash and the rest from the second entry instead of
    ///         reverting, and the success is reported as MoonwellSupplyExitFuse (on the base the Moonwell entry
    ///         pays 0, reports the error code 14 as an amount and the second entry cannot cover 5,000 alone)
    function test_withdrawTakesPartialCashFromMoonwellAndRestFromNextEntry() public {
        _setCash(3_000e6);
        assertGt(_positionUnderlying(), 3_000e6, "the position exceeds the cash");

        vm.recordLogs();
        vm.prank(_USER);
        _plasmaVault.withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs), 3_000e6, "Moonwell pays its whole cash");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
        assertEq(IERC20(_USDC).balanceOf(_M_USDC), 0, "Moonwell cash fully used");
    }

    /// @notice Case 2: an mToken with no cash is skipped: no redeemUnderlying call and no Moonwell event, the next
    ///         entry pays the whole withdrawal (on the base the call returns 14 and the fuse emits a success event)
    function test_zeroCashDoesNotCallMTokenAndNextEntryPays() public {
        _setCash(0);

        vm.expectCall(_M_USDC, abi.encodeWithSignature("redeemUnderlying(uint256)"), 0);
        vm.recordLogs();
        vm.prank(_USER);
        _plasmaVault.withdraw(3_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC20(_USDC).balanceOf(_USER), 3_000e6, "user received the payout from the next entry");
        assertEq(_exitAmount(logs), 0, "no Moonwell exit event");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice Case 3: with ample cash the instant withdraw succeeds and reports MoonwellSupplyExitFuse with the
    ///         redeemed amount, never ExitFailed (on the base the success code 0 is reported as ExitFailed)
    function test_successIsReportedAsExitFuse() public {
        _setCash(100_000e6);
        uint256 positionBefore = _positionUnderlying();

        vm.recordLogs();
        vm.prank(_USER);
        _plasmaVault.withdraw(1_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(IERC20(_USDC).balanceOf(_USER), 1_000e6, "user received the payout");
        assertGe(_exitAmount(logs), 1_000e6, "Moonwell paid the request");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
        assertLe(_positionUnderlying(), positionBefore - 1_000e6 + 1, "Moonwell position reduced");
    }

    /// @notice Case 4 (D-010): the ALPHA exit is not capped at the cash, a request above it reverts with the redeem
    ///         error code (on the base it does not revert and reports the code as an amount)
    function test_alphaExitAboveCashRevertsWithErrorCode() public {
        _setCash(3_000e6);

        FuseAction[] memory exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: _moonwellFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256))",
                MoonwellSupplyFuseExitData({asset: _USDC, amount: 5_000e6})
            )
        });
        uint256 positionBefore = _positionUnderlying();

        vm.prank(TestAddresses.ALPHA);
        vm.expectRevert(abi.encodeWithSignature("MoonwellSupplyFuseRedeemFailed(uint256)", _TOKEN_INSUFFICIENT_CASH));
        _plasmaVault.execute(exits);

        assertEq(_positionUnderlying(), positionBefore, "no tokens moved");
    }

    /// @notice Case 4b: the ALPHA exit within the cash succeeds and reports MoonwellSupplyExitFuse
    function test_alphaExitWithinCashSucceeds() public {
        _setCash(100_000e6);

        FuseAction[] memory exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: _moonwellFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256))",
                MoonwellSupplyFuseExitData({asset: _USDC, amount: 2_000e6})
            )
        });

        vm.recordLogs();
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(exits);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_exitAmount(logs), 2_000e6, "ALPHA exit reported as success");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
        assertEq(IERC20(_USDC).balanceOf(address(_plasmaVault)), 2_000e6, "underlying moved to the vault");
    }

    /// @notice Case 5: an error code from redeemUnderlying on the instant path (the amount after the cap is positive
    ///         and within the cash, so the cap is not what fails) is reported as MoonwellSupplyExitFailed, no success
    ///         event, no tokens move out of Moonwell, and the next entry pays. The Comptroller rejection cannot be
    ///         built on a fork without a borrowing position, so the redeem result is mocked (error code 9
    ///         COMPTROLLER_REJECTION is a value the real mToken returns); on the base the code is reported as a success
    function test_instantErrorCodeEmitsExitFailedAndNextEntryPays() public {
        _setCash(100_000e6);
        uint256 positionBefore = _positionUnderlying();
        vm.mockCall(_M_USDC, abi.encodeWithSignature("redeemUnderlying(uint256)"), abi.encode(uint256(9)));

        vm.recordLogs();
        vm.prank(_USER);
        _plasmaVault.withdraw(1_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_failedCount(logs), 1, "ExitFailed event");
        assertGt(_failedAmount(logs), 0, "ExitFailed carries the attempted amount");
        assertEq(_exitAmount(logs), 0, "no success event");
        assertEq(IERC20(_USDC).balanceOf(_USER), 1_000e6, "the next entry paid");
        assertEq(_positionUnderlying(), positionBefore, "no tokens moved out of Moonwell");
    }

    // ============ helpers ============

    /// @dev The mToken cash is the underlying it holds
    function _setCash(uint256 cash_) private {
        deal(_USDC, _M_USDC, cash_);
        (bool ok, bytes memory data) = _M_USDC.staticcall(abi.encodeWithSignature("getCash()"));
        assertTrue(ok, "getCash failed");
        assertEq(abi.decode(data, (uint256)), cash_, "mToken cash");
    }

    function _positionUnderlying() private returns (uint256) {
        (bool ok, bytes memory data) = _M_USDC.call(
            abi.encodeWithSignature("balanceOfUnderlying(address)", address(_plasmaVault))
        );
        assertTrue(ok, "balanceOfUnderlying failed");
        return abi.decode(data, (uint256));
    }

    function _exitAmount(Vm.Log[] memory logs_) private view returns (uint256 total) {
        bytes32 topic = keccak256("MoonwellSupplyExitFuse(address,address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(_plasmaVault) && logs_[i].topics[0] == topic) {
                (, , , uint256 amount) = abi.decode(logs_[i].data, (address, address, address, uint256));
                total += amount;
            }
        }
    }

    function _failedCount(Vm.Log[] memory logs_) private view returns (uint256 count) {
        bytes32 topic = keccak256("MoonwellSupplyExitFailed(address,address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(_plasmaVault) && logs_[i].topics[0] == topic) ++count;
        }
    }

    function _failedAmount(Vm.Log[] memory logs_) private view returns (uint256 total) {
        bytes32 topic = keccak256("MoonwellSupplyExitFailed(address,address,address,uint256)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(_plasmaVault) && logs_[i].topics[0] == topic) {
                (, , , uint256 amount) = abi.decode(logs_[i].data, (address, address, address, uint256));
                total += amount;
            }
        }
    }

    /// @dev Allocates idle USDC to Moonwell (first instant withdraw entry) and to the ERC4626 venue (second)
    function _allocate(uint256 moonwellAmount_, uint256 erc4626Amount_) private {
        FuseAction[] memory enter = new FuseAction[](2);
        enter[0] = FuseAction({
            fuse: _moonwellFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256))",
                MoonwellSupplyFuseEnterData({asset: _USDC, amount: moonwellAmount_})
            )
        });
        enter[1] = FuseAction({
            fuse: _erc4626Fuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                Erc4626SupplyFuseEnterData({vault: _ERC4626_VAULT, vaultAssetAmount: erc4626Amount_, minSharesOut: 0})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(enter);

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](2);
        iw[0] = InstantWithdrawalFusesParamsStruct({fuse: _moonwellFuse, params: _iwParams(_USDC)});
        iw[1] = InstantWithdrawalFusesParamsStruct({fuse: _erc4626Fuse, params: _iwParams(_ERC4626_VAULT)});
        vm.prank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        IPlasmaVaultGovernance(address(_plasmaVault)).configureInstantWithdrawalFuses(iw);
    }

    function _iwParams(address asset_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](2);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(asset_);
    }
}
