// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {CFG_DONT_SOCIALIZE_DEBT} from "../../../contracts/fuses/euler/ext/IEulerV2VaultGovernance.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

/// @dev EVC stand-in: `call` forwards to the target with the on-behalf-of account appended to the calldata, which the
///      eVault stand-in reads as its message sender (the role of EVK `EVCUtil._msgSender`); the collaterals enabled by
///      each account are set by the test
contract UnderlyingSkipMockEVC {
    mapping(address => address[]) private _collaterals;

    function setCollaterals(address account_, address[] calldata collaterals_) external {
        _collaterals[account_] = collaterals_;
    }

    function getCollaterals(address account_) external view returns (address[] memory) {
        return _collaterals[account_];
    }

    function call(
        address targetContract_,
        address onBehalfOfAccount_,
        uint256 value_,
        bytes calldata data_
    ) external payable returns (bytes memory result) {
        bool success;
        (success, result) = targetContract_.call{value: value_}(abi.encodePacked(data_, onBehalfOfAccount_));
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/// @dev eVault stand-in: an ERC-4626 share of `asset_` (one share per asset unit while it earns nothing) with the EVK
///      views EulerV2BalanceFuse reads (`debtOf`, `configFlags`, `LTVFull`). Debts and recognized collaterals are set
///      by the test; no tokens move for a debt.
contract UnderlyingSkipMockEVault is ERC4626 {
    address public immutable EVC;
    uint32 public configFlags;
    mapping(address => uint256) public debtOf;
    mapping(address => bool) private _recognized;

    constructor(IERC20 asset_, address evc_, string memory name_) ERC4626(asset_) ERC20(name_, name_) {
        EVC = evc_;
    }

    function setDebt(address account_, uint256 debt_) external {
        debtOf[account_] = debt_;
    }

    function setConfigFlags(uint32 configFlags_) external {
        configFlags = configFlags_;
    }

    function setRecognizedCollateral(address collateral_, bool recognized_) external {
        _recognized[collateral_] = recognized_;
    }

    /// @dev EVK `LTVFull`: a recognized collateral has a configured LTV (targetTimestamp != 0)
    function LTVFull(address collateral_) external view returns (uint16, uint16, uint16, uint48, uint32) {
        if (!_recognized[collateral_]) {
            return (0, 0, 0, 0, 0);
        }
        return (8_500, 9_000, 9_000, 1, 0);
    }

    function _msgSender() internal view override returns (address) {
        if (msg.sender == EVC && msg.data.length >= 20) {
            return address(bytes20(msg.data[msg.data.length - 20:]));
        }
        return msg.sender;
    }
}

/// @title EulerV2BalanceFuseUnderlyingSkipTest
/// @notice IL-9707 (3sigma audit v3 #21): EVC sub-account 0x00 is the Plasma Vault address itself, so when the vault's
///         underlying is an eVault share E and market 11 has a row (E, 0x00), the E shares on sub-account 0x00 are the
///         vault's idle balance, already in `totalAssets`. EulerV2BalanceFuse keeps that position in the valuation of
///         sub-account 0x00 and takes its value off the result of that sub-account (floor 0), so it is not counted a
///         second time. A real PlasmaVault runs the fuse (`execute` with EulerV2SupplyFuse, `updateMarketsBalances`).
/// @dev All eVaults hold the same 6-decimals base token at 1 USD and are 1:1 with it, so an amount of the base token is
///      also its value in the vault's underlying units.
contract EulerV2BalanceFuseUnderlyingSkipTest is Test {
    uint256 private constant _MARKET_ID = IporFusionMarkets.EULER_V2;

    bytes1 private constant _SUB_ACCOUNT_ZERO = 0x00;
    bytes1 private constant _SUB_ACCOUNT_ONE = 0x01;

    /// @dev E shares a user deposits into the Plasma Vault: its idle underlying, held on sub-account 0x00
    uint256 private constant _IDLE = 1_000e6;
    /// @dev The unit of the base token the vault wraps into E
    uint256 private constant _UNIT = 1e6;

    address private constant _ALPHA = address(0x1);
    address private constant _UPDATER = address(0x2);
    address private constant _USER = address(0xA11CE);

    MockERC20 private _baseToken;
    UnderlyingSkipMockEVC private _evc;
    /// @dev E: the underlying of the Plasma Vault
    UnderlyingSkipMockEVault private _eVaultUnderlying;
    /// @dev Another eVault, plain supply
    UnderlyingSkipMockEVault private _eVaultOther;
    /// @dev The eVault the vault borrows from (controller)
    UnderlyingSkipMockEVault private _eVaultController;
    PriceOracleMiddleware private _oracle;
    EulerV2SupplyFuse private _supplyFuse;
    EulerV2BalanceFuse private _balanceFuse;
    PlasmaVault private _plasmaVault;

    function setUp() public {
        _baseToken = new MockERC20("Base", "BASE", 6);
        _evc = new UnderlyingSkipMockEVC();
        _eVaultUnderlying = new UnderlyingSkipMockEVault(IERC20(address(_baseToken)), address(_evc), "eBASE-1");
        _eVaultOther = new UnderlyingSkipMockEVault(IERC20(address(_baseToken)), address(_evc), "eBASE-2");
        _eVaultController = new UnderlyingSkipMockEVault(IERC20(address(_baseToken)), address(_evc), "eBASE-3");

        _oracle = _createOracle();
        _supplyFuse = new EulerV2SupplyFuse(_MARKET_ID, address(_evc));
        _balanceFuse = new EulerV2BalanceFuse(_MARKET_ID, address(_evc));

        _plasmaVault = _createPlasmaVault(address(_eVaultUnderlying));

        // a user deposits E shares: the vault's idle underlying, on the vault address = sub-account 0x00
        uint256 shares = _supplyTo(_eVaultUnderlying, _USER, _IDLE);
        vm.startPrank(_USER);
        _eVaultUnderlying.approve(address(_plasmaVault), shares);
        _plasmaVault.deposit(shares, _USER);
        vm.stopPrank();

        // the controller recognizes E as collateral; sub-accounts 0x00 and 0x01 enabled it on the EVC
        _eVaultController.setRecognizedCollateral(address(_eVaultUnderlying), true);
        _evc.setCollaterals(address(_plasmaVault), _oneAddress(address(_eVaultUnderlying)));
        _evc.setCollaterals(_subAccount(_SUB_ACCOUNT_ONE), _oneAddress(address(_eVaultUnderlying)));
    }

    //******************************************************************************************************************
    //********************                    BASE REGRESSION: UNDERLYING ON SUB-ACCOUNT 0x00       ********************
    //******************************************************************************************************************

    /// @notice The vault wraps one unit of the base token into E on sub-account 0x00 through EulerV2SupplyFuse. The new
    ///         E shares land on the vault address, i.e. in its idle underlying, so `totalAssets` grows by the value of
    ///         that unit and market 11 holds nothing. Before IL-9707 the fuse counted every E share of sub-account 0x00
    ///         again: market 11 = idle, `totalAssets` about doubled (2 002 instead of 1 001).
    function testShouldGrowTotalAssetsByWrappedUnitWhenUnderlyingIsOnSubAccountZero() external {
        // given
        _grant(_oneSubstrate(_substrate(address(_eVaultUnderlying), false, false, _SUB_ACCOUNT_ZERO)));
        uint256 totalAssetsBefore = _plasmaVault.totalAssets();
        assertEq(totalAssetsBefore, _IDLE, "idle underlying only");

        // when
        _mintAndSupply(_eVaultUnderlying, _SUB_ACCOUNT_ZERO, _UNIT);

        // then
        assertEq(_eVaultUnderlying.balanceOf(address(_plasmaVault)), _IDLE + _UNIT, "wrapped unit is idle underlying");
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 0, "idle underlying not counted again in market 11");
        assertEq(_plasmaVault.totalAssets(), totalAssetsBefore + _UNIT, "totalAssets grows by the wrapped unit");
    }

    /// @notice The same E on sub-accounts 0x00 and 0x01: only sub-account 0x00 is the vault address, so the shares on
    ///         0x01 are counted in full and the idle shares on 0x00 are not. Before IL-9707: 1 300.
    function testShouldSkipUnderlyingOnlyOnSubAccountZero() external {
        // given
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _substrate(address(_eVaultUnderlying), false, false, _SUB_ACCOUNT_ZERO);
        substrates[1] = _substrate(address(_eVaultUnderlying), false, false, _SUB_ACCOUNT_ONE);
        _grant(substrates);

        // when
        _mintAndSupply(_eVaultUnderlying, _SUB_ACCOUNT_ONE, 300e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 300e6, "E on 0x01 counted, idle E on 0x00 not");
        assertEq(_plasmaVault.totalAssets(), _IDLE + 300e6, "idle + E on 0x01");
    }

    /// @notice Another eVault on sub-account 0x00 is counted in full next to the skipped underlying. Before IL-9707:
    ///         1 500.
    function testShouldCountOtherEulerVaultOnSubAccountZero() external {
        // given
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _substrate(address(_eVaultUnderlying), false, false, _SUB_ACCOUNT_ZERO);
        substrates[1] = _substrate(address(_eVaultOther), false, false, _SUB_ACCOUNT_ZERO);
        _grant(substrates);

        // when
        _mintAndSupply(_eVaultOther, _SUB_ACCOUNT_ZERO, 500e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 500e6, "other eVault on 0x00 counted in full");
        assertEq(_plasmaVault.totalAssets(), _IDLE + 500e6, "idle + other eVault");
    }

    /// @notice Row (E, 0x00) granted twice (as collateral and as plain supply): the position is read once and its
    ///         value is taken off once. Taking it off twice would give 1 500 - 1 000 = 500. Before IL-9707: 2 500.
    function testShouldTakeUnderlyingOffOnceWhenRowIsGrantedTwice() external {
        // given
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _substrate(address(_eVaultUnderlying), true, false, _SUB_ACCOUNT_ZERO);
        substrates[1] = _substrate(address(_eVaultUnderlying), false, false, _SUB_ACCOUNT_ZERO);
        substrates[2] = _substrate(address(_eVaultOther), false, false, _SUB_ACCOUNT_ZERO);
        _grant(substrates);

        // when
        _mintAndSupply(_eVaultOther, _SUB_ACCOUNT_ZERO, 1_500e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 1_500e6, "underlying taken off once");
    }

    //******************************************************************************************************************
    //********************                    DEBT ON SUB-ACCOUNT 0x00 SECURED BY THE UNDERLYING    ********************
    //******************************************************************************************************************

    /// @notice Sub-account 0x00: idle E 1 000 (seizable collateral), plain supply 500 in another eVault, debt 300.
    ///         Valuation of the sub-account v = 500 + 1 000 - 300 = 1 200; without E: max(0, 1 200 - 1 000) = 200.
    ///         `totalAssets` = 1 000 + 200 = the real value 1 000 + 500 - 300. Before IL-9707: 1 200 in market 11.
    function testShouldTakeUnderlyingOffSubAccountZeroWithDebtWhenFreeSupplyExceedsDebt() external {
        // given / when
        _setUpBorrowOnSubAccountZero(500e6, 300e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 200e6, "max(0, v - E) = free supply - debt");
        assertEq(_plasmaVault.totalAssets(), _IDLE + 200e6, "idle + free supply - debt");
    }

    /// @notice Same sub-account with plain supply 100 below the debt 300: v = 100 + 1 000 - 300 = 800, without E
    ///         max(0, 800 - 1 000) = 0, no revert. Documented limitation (atomist rule: with an eVault-share
    ///         underlying, do not borrow on sub-account 0x00): the part of the debt borne by idle (200) cannot be shown
    ///         by the market, so `totalAssets` stays at idle 1 000 while the real value is 800. Before IL-9707: 800 in
    ///         market 11.
    function testShouldFloorSubAccountZeroWithDebtWhenFreeSupplyIsBelowDebt() external {
        // given / when
        _setUpBorrowOnSubAccountZero(100e6, 300e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 0, "max(0, v - E) floored at zero");
        assertEq(_plasmaVault.totalAssets(), _IDLE, "idle only; the debt part borne by idle is not shown");
    }

    /// @notice Sub-account 0x00 underwater with socializable debt: idle E 1 000 < debt 1 500. A liquidation seizes E,
    ///         the plain supply 1 200 survives: v = 1 200; without E: max(0, 1 200 - 1 000) = 200, so `totalAssets`
    ///         = 1 200, what the vault keeps after the liquidation. Before IL-9707: 1 200 in market 11.
    function testShouldTakeUnderlyingOffUnderwaterSubAccountZero() external {
        // given / when
        _setUpBorrowOnSubAccountZero(1_200e6, 1_500e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 200e6, "max(0, F - E)");
        assertEq(_plasmaVault.totalAssets(), 1_200e6, "what survives the liquidation");
    }

    /// @notice Underwater sub-account 0x00 with plain supply 400 below the idle E: max(0, 400 - 1 000) = 0, no revert.
    ///         Before IL-9707: 400 in market 11.
    function testShouldReturnZeroForUnderwaterSubAccountZeroBelowUnderlying() external {
        // given / when
        _setUpBorrowOnSubAccountZero(400e6, 1_500e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 0, "floored at zero, no revert");
        assertEq(_plasmaVault.totalAssets(), _IDLE, "idle only");
    }

    /// @notice The controller keeps the residual debt (CFG_DONT_SOCIALIZE_DEBT): v = max(0, 1 000 + 1 800 - 1 500) =
    ///         1 300; without E: 300, `totalAssets` = 1 300 = the real value. Before IL-9707: 1 300 in market 11.
    function testShouldTakeUnderlyingOffSubAccountZeroWhenControllerKeepsResidualDebt() external {
        // given
        _eVaultController.setConfigFlags(CFG_DONT_SOCIALIZE_DEBT);

        // when
        _setUpBorrowOnSubAccountZero(1_800e6, 1_500e6);

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 300e6, "max(0, C + F - D - E)");
        assertEq(_plasmaVault.totalAssets(), 1_300e6, "idle + free supply - debt");
    }

    //******************************************************************************************************************
    //********************                    FLOOR PER SUB-ACCOUNT                                 ********************
    //******************************************************************************************************************

    /// @notice Sub-account 0x00 falls below its underlying (idle E 1 000, debt 300: v = 700, without E 0) next to a
    ///         healthy sub-account 0x01 with 500 of plain supply: 0x00 contributes 0, not -300, and 0x01 counts in
    ///         full. Before IL-9707: 1 200.
    function testShouldNotLowerHealthySubAccountWhenSubAccountZeroFallsBelowUnderlying() external {
        // given
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _substrate(address(_eVaultUnderlying), true, false, _SUB_ACCOUNT_ZERO);
        substrates[1] = _substrate(address(_eVaultController), false, true, _SUB_ACCOUNT_ZERO);
        substrates[2] = _substrate(address(_eVaultOther), false, false, _SUB_ACCOUNT_ONE);
        _grant(substrates);
        _mintAndSupply(_eVaultOther, _SUB_ACCOUNT_ONE, 500e6);
        _eVaultController.setDebt(address(_plasmaVault), 300e6);

        // when
        _refresh();

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 500e6, "0x00 floored at zero, 0x01 in full");
    }

    /// @notice Only sub-account 0x00 is configured and falls below its underlying: the market is worth 0 and the
    ///         refresh does not revert. Before IL-9707: 700.
    function testShouldReturnZeroWhenOnlySubAccountZeroFallsBelowUnderlying() external {
        // given
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _substrate(address(_eVaultUnderlying), true, false, _SUB_ACCOUNT_ZERO);
        substrates[1] = _substrate(address(_eVaultController), false, true, _SUB_ACCOUNT_ZERO);
        _grant(substrates);
        _eVaultController.setDebt(address(_plasmaVault), 300e6);

        // when
        _refresh();

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 0, "floored at zero instead of reverting");
        assertEq(_plasmaVault.totalAssets(), _IDLE, "idle only");
    }

    /// @notice A healthy sub-account without a row on 0x00 (E collateral 400, plain supply 500, debt 300 on 0x01) keeps
    ///         its value 600, and the vault's `asset()` is not read (lazy read, no gas for markets without 0x00).
    function testShouldKeepHealthySubAccountWithoutRowOnSubAccountZeroAndNotReadVaultAsset() external {
        // given
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _substrate(address(_eVaultUnderlying), true, false, _SUB_ACCOUNT_ONE);
        substrates[1] = _substrate(address(_eVaultOther), false, false, _SUB_ACCOUNT_ONE);
        substrates[2] = _substrate(address(_eVaultController), false, true, _SUB_ACCOUNT_ONE);
        _grant(substrates);
        _mintAndSupply(_eVaultUnderlying, _SUB_ACCOUNT_ONE, 400e6);
        _mintAndSupply(_eVaultOther, _SUB_ACCOUNT_ONE, 500e6);
        _eVaultController.setDebt(_subAccount(_SUB_ACCOUNT_ONE), 300e6);

        // then
        vm.expectCall(address(_plasmaVault), abi.encodeWithSignature("asset()"), 0);

        // when
        _refresh();

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 600e6, "400 + 500 - 300, unchanged");
    }

    /// @notice With a row on sub-account 0x00 the vault's `asset()` is read once per refresh.
    function testShouldReadVaultAssetOnceWhenMarketHasRowOnSubAccountZero() external {
        // given
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _substrate(address(_eVaultUnderlying), false, false, _SUB_ACCOUNT_ZERO);
        substrates[1] = _substrate(address(_eVaultOther), false, false, _SUB_ACCOUNT_ZERO);
        _grant(substrates);
        _mintAndSupply(_eVaultOther, _SUB_ACCOUNT_ZERO, 500e6);

        // then
        vm.expectCall(address(_plasmaVault), abi.encodeWithSignature("asset()"), 1);

        // when
        _refresh();

        // then
        assertEq(_plasmaVault.totalAssetsInMarket(_MARKET_ID), 500e6, "other eVault only");
    }

    //******************************************************************************************************************
    //********************                    VAULT WITH ANOTHER UNDERLYING                         ********************
    //******************************************************************************************************************

    /// @notice A vault whose underlying is the base token holds E on sub-account 0x00: E is not its underlying, so the
    ///         position is counted in full, as before IL-9707.
    function testShouldCountEulerVaultOnSubAccountZeroWhenVaultHasAnotherUnderlying() external {
        // given
        PlasmaVault plasmaVault = _createPlasmaVault(address(_baseToken));
        _baseToken.mint(_USER, 1_000e6);
        vm.startPrank(_USER);
        _baseToken.approve(address(plasmaVault), 1_000e6);
        plasmaVault.deposit(1_000e6, _USER);
        vm.stopPrank();

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _substrate(address(_eVaultUnderlying), false, false, _SUB_ACCOUNT_ZERO);
        substrates[1] = _substrate(address(_eVaultOther), false, false, _SUB_ACCOUNT_ZERO);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(_MARKET_ID, substrates);

        // when
        _supplyThroughFuse(plasmaVault, _eVaultUnderlying, _SUB_ACCOUNT_ZERO, 700e6);
        _supplyThroughFuse(plasmaVault, _eVaultOther, _SUB_ACCOUNT_ZERO, 200e6);

        // then
        assertEq(plasmaVault.totalAssetsInMarket(_MARKET_ID), 900e6, "E and the other eVault counted in full");
        assertEq(plasmaVault.totalAssets(), 1_000e6, "idle 100 + market 900: unchanged by the allocation");
    }

    //******************************************************************************************************************
    //********************                              HELPERS                                     ********************
    //******************************************************************************************************************

    /// @dev Sub-account 0x00 holds the idle E (seizable: enabled on the EVC and recognized by the controller), `free_`
    ///      of plain supply in the other eVault and `debt_` in the controller; market 11 is refreshed afterwards
    function _setUpBorrowOnSubAccountZero(uint256 free_, uint256 debt_) private {
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _substrate(address(_eVaultUnderlying), true, false, _SUB_ACCOUNT_ZERO);
        substrates[1] = _substrate(address(_eVaultOther), false, false, _SUB_ACCOUNT_ZERO);
        substrates[2] = _substrate(address(_eVaultController), false, true, _SUB_ACCOUNT_ZERO);
        _grant(substrates);
        _mintAndSupply(_eVaultOther, _SUB_ACCOUNT_ZERO, free_);
        _eVaultController.setDebt(address(_plasmaVault), debt_);
        _refresh();
    }

    /// @dev The vault receives `amount_` of the base token (not its underlying, so not counted) and supplies it to
    ///      `eVault_` on `subAccount_` through EulerV2SupplyFuse; `execute` refreshes market 11
    function _mintAndSupply(UnderlyingSkipMockEVault eVault_, bytes1 subAccount_, uint256 amount_) private {
        _baseToken.mint(address(_plasmaVault), amount_);
        _supplyThroughFuse(_plasmaVault, eVault_, subAccount_, amount_);
    }

    function _supplyThroughFuse(
        PlasmaVault plasmaVault_,
        UnderlyingSkipMockEVault eVault_,
        bytes1 subAccount_,
        uint256 amount_
    ) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_supplyFuse),
            abi.encodeCall(
                EulerV2SupplyFuse.enter,
                (
                    EulerV2SupplyFuseEnterData({
                        eulerVault: address(eVault_),
                        maxAmount: amount_,
                        subAccount: subAccount_
                    })
                )
            )
        );
        vm.prank(_ALPHA);
        plasmaVault_.execute(actions);
    }

    function _refresh() private {
        uint256[] memory markets = new uint256[](1);
        markets[0] = _MARKET_ID;
        vm.prank(_UPDATER);
        _plasmaVault.updateMarketsBalances(markets);
    }

    function _supplyTo(UnderlyingSkipMockEVault eVault_, address receiver_, uint256 amount_) private returns (uint256) {
        _baseToken.mint(address(this), amount_);
        _baseToken.approve(address(eVault_), amount_);
        return eVault_.deposit(amount_, receiver_);
    }

    function _grant(bytes32[] memory substrates_) private {
        PlasmaVaultGovernance(address(_plasmaVault)).grantMarketSubstrates(_MARKET_ID, substrates_);
    }

    function _subAccount(bytes1 subAccount_) private view returns (address) {
        return EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), subAccount_);
    }

    function _substrate(
        address eulerVault_,
        bool isCollateral_,
        bool canBorrow_,
        bytes1 subAccount_
    ) private pure returns (bytes32) {
        return
            EulerFuseLib.substrateToBytes32(
                EulerSubstrate({
                    eulerVault: eulerVault_,
                    isCollateral: isCollateral_,
                    canBorrow: canBorrow_,
                    subAccounts: subAccount_
                })
            );
    }

    function _oneSubstrate(bytes32 substrate_) private pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = substrate_;
    }

    function _oneAddress(address account_) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = account_;
    }

    function _createOracle() private returns (PriceOracleMiddleware oracle) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](2);
        assets[0] = address(_baseToken);
        assets[1] = address(_eVaultUnderlying);
        address[] memory sources = new address[](2);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        sources[1] = address(new FixedValuePriceFeed(1e8));
        oracle.setAssetsPricesSources(assets, sources);
    }

    /// @dev A locally built PlasmaVault (never a factory clone, so the test runs the code of this tree) with
    ///      EulerV2SupplyFuse and EulerV2BalanceFuse on market 11; the test contract is atomist and fuse manager
    function _createPlasmaVault(address underlying_) private returns (PlasmaVault plasmaVault) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = _ALPHA;
        usersToRoles.alphas = alphas;
        IporFusionAccessManager accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion eBASE",
                "ipfeBASE",
                underlying_,
                address(_oracle),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        bytes4[] memory updateSig = new bytes4[](1);
        updateSig[0] = PlasmaVault.updateMarketsBalances.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), updateSig, Roles.UPDATE_MARKETS_BALANCES_ROLE);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, _UPDATER, 0);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_supplyFuse);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(_MARKET_ID, address(_balanceFuse));
    }
}
