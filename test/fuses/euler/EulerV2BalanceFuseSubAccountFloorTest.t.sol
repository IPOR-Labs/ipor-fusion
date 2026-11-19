// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {
    IEulerV2VaultGovernance,
    CFG_DONT_SOCIALIZE_DEBT
} from "../../../contracts/fuses/euler/ext/IEulerV2VaultGovernance.sol";
import {IEVC} from "@ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title EulerV2BalanceFuseSubAccountFloorTest
/// @notice IL-9528 (3sigma audit finding #1): EulerV2BalanceFuse values each EVC sub-account on its own and floors it
///         at zero, so an underwater sub-account contributes 0 instead of charging its shortfall to the other
///         sub-accounts, and a negative market total no longer reverts. Positions are mocked; the fuse runs in the
///         storage context of PlasmaVaultMock through a delegatecall, as in a Plasma Vault.
contract EulerV2BalanceFuseSubAccountFloorTest is Test {
    uint256 private constant _MARKET_ID = 11;

    bytes1 private constant _SUB_ACCOUNT_A = 0x01;
    bytes1 private constant _SUB_ACCOUNT_B = 0x02;

    /// @dev USD prices with 8 decimals, as returned by the price oracle middleware
    uint256 private constant _PRICE_DECIMALS = 8;
    uint256 private constant _ONE_USD = 1e8;
    uint256 private constant _WETH_PRICE_USD = 2_000e8;
    uint256 private constant _WETH_UNDERWATER_PRICE_USD = 1_000e8;

    address private _evc;
    address private _middleware;

    /// @dev Euler vault tokens: USDT-like (6 decimals), WETH-like (18 decimals), USDC-like (6 decimals)
    address private _usdt;
    address private _weth;
    address private _usdc;

    /// @dev Euler vaults over these tokens
    address private _eulerVaultUsdt;
    address private _eulerVaultWeth;
    address private _eulerVaultUsdc;

    EulerV2BalanceFuse private _balanceFuse;
    PlasmaVaultMock private _plasmaVault;

    address private _subAccountA;
    address private _subAccountB;

    function setUp() public {
        _evc = _codeAddress("evc");
        _middleware = _codeAddress("priceOracleMiddleware");

        _usdt = _codeAddress("usdt");
        _weth = _codeAddress("weth");
        _usdc = _codeAddress("usdc");

        _eulerVaultUsdt = _codeAddress("eulerVaultUsdt");
        _eulerVaultWeth = _codeAddress("eulerVaultWeth");
        _eulerVaultUsdc = _codeAddress("eulerVaultUsdc");

        _balanceFuse = new EulerV2BalanceFuse(_MARKET_ID, _evc);
        _plasmaVault = new PlasmaVaultMock(address(0), address(_balanceFuse));
        _plasmaVault.setPriceOracleMiddleware(_middleware);

        _subAccountA = EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), _SUB_ACCOUNT_A);
        _subAccountB = EulerFuseLib.generateSubAccountAddress(address(_plasmaVault), _SUB_ACCOUNT_B);

        _mockToken(_usdt, 6, _ONE_USD);
        _mockToken(_weth, 18, _WETH_PRICE_USD);
        _mockToken(_usdc, 6, _ONE_USD);

        _mockEulerVaultAsset(_eulerVaultUsdt, _usdt);
        _mockEulerVaultAsset(_eulerVaultWeth, _weth);
        _mockEulerVaultAsset(_eulerVaultUsdc, _usdc);

        // Defaults: every controller socializes; the USDC controller recognizes WETH and USDT as collateral;
        // both sub-accounts enabled WETH as collateral on the EVC
        _mockConfigFlags(_eulerVaultUsdc, 0);
        _mockConfigFlags(_eulerVaultUsdt, 0);
        _mockConfigFlags(_eulerVaultWeth, 0);
        _mockRecognized(_eulerVaultUsdc, _eulerVaultWeth, true);
        _mockRecognized(_eulerVaultUsdc, _eulerVaultUsdt, true);
        _mockCollaterals(_subAccountA, _one(_eulerVaultWeth));
        _mockCollaterals(_subAccountB, _one(_eulerVaultWeth));
    }

    //******************************************************************************************************************
    //********************                    UNDERWATER SUB-ACCOUNT (BASE REGRESSION)              ********************
    //******************************************************************************************************************

    /// @notice (i) Sub-account A holds plain supply worth P; sub-account B is underwater (collateral C < debt D).
    ///         B contributes 0, so the market is worth P. Netting across sub-accounts gave P - (D - C).
    function testShouldNotChargeShortfallOfUnderwaterSubAccountToHealthySubAccount() external {
        // given
        _mockToken(_weth, 18, _WETH_UNDERWATER_PRICE_USD);
        _grantSubstrates(_threeSubstrates(_eulerVaultUsdt, _SUB_ACCOUNT_A, _eulerVaultWeth, _eulerVaultUsdc));

        // A: 5 000 USDT of plain supply (4 900 shares)
        _mockPosition(_eulerVaultUsdt, _subAccountA, 4_900e6, 5_000e6, 0);
        // B: 1 WETH of collateral worth 1 000 USD, 1 600 USDC of debt -> shortfall 600 USD
        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 1_600e6);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 5_000e18, "underwater sub-account B contributes 0, sub-account A counts in full");
    }

    /// @notice (ii) Only the underwater sub-account B is configured: the market is worth 0 and does not revert.
    ///         Netting across sub-accounts reverted with SafeCastOverflowedIntToUint on the negative total.
    function testShouldReturnZeroWhenOnlySubAccountIsUnderwater() external {
        // given
        _mockToken(_weth, 18, _WETH_UNDERWATER_PRICE_USD);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _substrate(_eulerVaultWeth, true, false, _SUB_ACCOUNT_B);
        substrates[1] = _substrate(_eulerVaultUsdc, false, true, _SUB_ACCOUNT_B);
        _grantSubstrates(substrates);

        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 1_600e6);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 0, "underwater sub-account is floored at zero instead of reverting");
    }

    /// @notice (vi) Same positions as (i) with the substrates interleaved (B debt, A supply, B collateral): the
    ///         per-sub-account grouping does not depend on the substrate order.
    function testShouldGroupSubstratesBySubAccountWhenInterleaved() external {
        // given
        _mockToken(_weth, 18, _WETH_UNDERWATER_PRICE_USD);
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _substrate(_eulerVaultUsdc, false, true, _SUB_ACCOUNT_B);
        substrates[1] = _substrate(_eulerVaultUsdt, false, false, _SUB_ACCOUNT_A);
        substrates[2] = _substrate(_eulerVaultWeth, true, false, _SUB_ACCOUNT_B);
        _grantSubstrates(substrates);

        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 1_600e6);
        _mockPosition(_eulerVaultUsdt, _subAccountA, 4_900e6, 5_000e6, 0);
        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 5_000e18, "sub-account B floored at zero regardless of substrate order");
    }

    //******************************************************************************************************************
    //********************                    UNCHANGED VALUATIONS                                  ********************
    //******************************************************************************************************************

    /// @notice (iii) One sub-account with collateral in one Euler vault and debt in another: the debt offsets the
    ///         collateral inside the sub-account (C - D). A floor per substrate would return C instead.
    function testShouldNetCollateralAndDebtInsideOneSubAccount() external {
        // given
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _substrate(_eulerVaultWeth, true, false, _SUB_ACCOUNT_A);
        substrates[1] = _substrate(_eulerVaultUsdc, false, true, _SUB_ACCOUNT_A);
        _grantSubstrates(substrates);

        // 1 WETH of collateral worth 2 000 USD, 1 500 USDC of debt
        _mockPosition(_eulerVaultWeth, _subAccountA, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountA, 0, 0, 1_500e6);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 500e18, "collateral minus debt of the same sub-account");
    }

    /// @notice (iv) Two healthy sub-accounts: the value equals the market-wide net of all positions, the value the
    ///         fuse returned before the per-sub-account floor.
    function testShouldKeepValueOfHealthySubAccounts() external {
        // given
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = _substrate(_eulerVaultWeth, true, false, _SUB_ACCOUNT_A);
        substrates[1] = _substrate(_eulerVaultUsdc, false, true, _SUB_ACCOUNT_A);
        substrates[2] = _substrate(_eulerVaultUsdt, false, false, _SUB_ACCOUNT_B);
        substrates[3] = _substrate(_eulerVaultUsdc, false, true, _SUB_ACCOUNT_B);
        _grantSubstrates(substrates);

        // A: 1.5 WETH of collateral (1.4 shares) worth 3 000 USD, 1 000 USDC of debt -> 2 000 USD
        _mockPosition(_eulerVaultWeth, _subAccountA, 1.4e18, 1.5e18, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountA, 0, 0, 1_000e6);
        // B: 3 000 USDT of supply, 500 USDC of debt -> 2 500 USD
        _mockPosition(_eulerVaultUsdt, _subAccountB, 3_000e6, 3_000e6, 0);
        // B borrows against its USDT, so the USDT is its enabled collateral
        _mockCollaterals(_subAccountB, _one(_eulerVaultUsdt));
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 500e6);

        uint256 marketWideNet = 3_000e18 - 1_000e18 + 3_000e18 - 500e18;

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, marketWideNet, "healthy sub-accounts keep the market-wide net value");
        assertEq(balance, 4_500e18, "2 000 USD + 2 500 USD");
    }

    /// @notice A sub-account whose supply and debt are both zero contributes nothing.
    function testShouldReturnZeroForEmptySubAccounts() external {
        // given
        _grantSubstrates(_threeSubstrates(_eulerVaultUsdt, _SUB_ACCOUNT_A, _eulerVaultWeth, _eulerVaultUsdc));

        _mockPosition(_eulerVaultUsdt, _subAccountA, 0, 0, 0);
        _mockPosition(_eulerVaultWeth, _subAccountB, 0, 0, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 0);

        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 0, "no positions");
    }

    /// @notice An empty substrate list returns 0 without reading the price oracle middleware.
    function testShouldReturnZeroWithoutSubstrates() external {
        // when
        uint256 balance = _plasmaVault.balanceOf();

        // then
        assertEq(balance, 0, "no substrates");
    }

    /// @notice (v) A zero price still reverts, also when the sub-account would be floored at zero.
    function testShouldRevertWhenPriceIsZero() external {
        // given
        _grantSubstrates(_threeSubstrates(_eulerVaultUsdt, _SUB_ACCOUNT_A, _eulerVaultWeth, _eulerVaultUsdc));

        _mockPosition(_eulerVaultUsdt, _subAccountA, 4_900e6, 5_000e6, 0);
        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 1_600e6);
        _mockToken(_weth, 18, 0);

        // then
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedQuoteCurrencyFromOracle.selector));
        // when
        _plasmaVault.balanceOf();
    }

    //******************************************************************************************************************
    //********************     PROPOSAL: 3SIGMA SPLIT + LIQUIDATABILITY + SOCIALIZATION CHARGE      ********************
    //******************************************************************************************************************

    /// @notice (S1) Mixed sub-account, debt socialized: B has 1 WETH of seizable collateral (1 000 USD), 1 000 USDT of
    ///         plain supply and 2 500 USDC of debt. A liquidation seizes the WETH, the controller writes 1 500 USD off and
    ///         the USDT stays: B is worth 1 000 USD. Netting everything (first IL-9528 fix) gave 0 and stepped up by
    ///         1 000 at the liquidation.
    function testShouldCountPlainSupplyInFullWhenDebtIsSocialized() external {
        _mockToken(_weth, 18, _WETH_UNDERWATER_PRICE_USD);
        _grantSubstrates(_mixedSubAccountB());
        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdt, _subAccountB, 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 2_500e6);

        assertEq(_plasmaVault.balanceOf(), 1_000e18, "plain supply survives the liquidation");
    }

    /// @notice (S2) Same sub-account with 1 500 USDC of debt and CFG_DONT_SOCIALIZE_DEBT on the controller: the residual
    ///         debt stays and locks the USDT, so everything is netted: 1 000 + 1 000 - 1 500 = 500 USD.
    function testShouldNetPlainSupplyWhenControllerKeepsResidualDebt() external {
        _mockToken(_weth, 18, _WETH_UNDERWATER_PRICE_USD);
        _mockConfigFlags(_eulerVaultUsdc, CFG_DONT_SOCIALIZE_DEBT);
        _grantSubstrates(_mixedSubAccountB());
        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdt, _subAccountB, 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 1_500e6);

        assertEq(_plasmaVault.balanceOf(), 500e18, "residual debt locks every position");
    }

    /// @notice (S3, defensive) No enabled collateral of B is recognized by its controller, so no liquidation can run
    ///         and the debt is never socialized; it locks every position: B is worth 1 000 + 1 000 - 1 500 = 500 USD. A
    ///         split by `isCollateralEnabled` alone (3sigma) counts the USDT in full: 1 000 USD. Not reachable on
    ///         released EVK (v1.0.0 removed `clearLTV`, a recognized collateral stays recognized); kept because it
    ///         follows the EVK liquidation preconditions at no extra cost.
    function testShouldNetEverythingWhenNoCollateralIsSeizable() external {
        _mockToken(_weth, 18, _WETH_UNDERWATER_PRICE_USD);
        _mockRecognized(_eulerVaultUsdc, _eulerVaultWeth, false);
        _grantSubstrates(_mixedSubAccountB());
        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdt, _subAccountB, 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 1_500e6);

        assertEq(_plasmaVault.balanceOf(), 500e18, "debt that cannot be socialized locks every position");
    }

    /// @notice (S4) B enabled USDT as collateral, but the controller does not recognize it; WETH is recognized. A
    ///         liquidation seizes the WETH only and the debt is socialized although the USDT is left: B keeps 1 000 USD.
    ///         A split by `isCollateralEnabled` alone (3sigma) nets the USDT against the debt: 0.
    function testShouldCountUnrecognizedCollateralAsFree() external {
        _mockToken(_weth, 18, _WETH_UNDERWATER_PRICE_USD);
        _mockRecognized(_eulerVaultUsdc, _eulerVaultUsdt, false);
        _mockCollaterals(_subAccountB, _two(_eulerVaultWeth, _eulerVaultUsdt));
        _grantSubstrates(_mixedSubAccountB());
        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdt, _subAccountB, 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 2_500e6);

        assertEq(_plasmaVault.balanceOf(), 1_000e18, "collateral the controller cannot seize survives");
    }

    /// @notice (S5) A holds 5 000 USDC of plain supply in the USDC eVault (0.5 % of its shares); B is underwater on the
    ///         same eVault with 1 600 USDC of debt. Writing B's debt off lowers the USDC share price for every
    ///         depositor, A included: A is charged 0.5 % of 1 600 = 8 USD up front. Without the charge (first fix and
    ///         3sigma) the market shows 5 000 until the liquidation and then falls.
    function testShouldChargeVaultSharesInControllerTheirPartOfSocializedDebt() external {
        _mockToken(_weth, 18, _WETH_UNDERWATER_PRICE_USD);
        _mockTotalSupply(_eulerVaultUsdc, 1_000_000e6);
        _grantSubstrates(_threeSubstrates(_eulerVaultUsdc, _SUB_ACCOUNT_A, _eulerVaultWeth, _eulerVaultUsdc));
        _mockPosition(_eulerVaultUsdc, _subAccountA, 5_000e6, 5_000e6, 0);
        _mockPosition(_eulerVaultWeth, _subAccountB, 1e18, 1e18, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 1_600e6);

        assertEq(_plasmaVault.balanceOf(), 4_992e18, "5 000 - 0.5 % of the 1 600 written off");
    }

    /// @notice (S6) The same eVault and sub-account granted twice (as collateral and as plain supply): the position is
    ///         counted once. Every earlier version counted it twice.
    function testShouldCountPositionGrantedTwiceOnce() external {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _substrate(_eulerVaultUsdt, true, false, _SUB_ACCOUNT_A);
        substrates[1] = _substrate(_eulerVaultUsdt, false, false, _SUB_ACCOUNT_A);
        _grantSubstrates(substrates);
        _mockPosition(_eulerVaultUsdt, _subAccountA, 4_900e6, 5_000e6, 0);

        assertEq(_plasmaVault.balanceOf(), 5_000e18, "one position, one value");
    }

    /// @notice (S7) An empty position is not priced: a granted eVault whose asset has no price does not freeze the
    ///         market while the vault holds nothing there.
    function testShouldNotPriceEmptyPosition() external {
        _mockToken(_weth, 18, 0);
        _grantSubstrates(_threeSubstrates(_eulerVaultUsdt, _SUB_ACCOUNT_A, _eulerVaultWeth, _eulerVaultUsdc));
        _mockPosition(_eulerVaultUsdt, _subAccountA, 4_900e6, 5_000e6, 0);
        _mockPosition(_eulerVaultWeth, _subAccountB, 0, 0, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 0);

        assertEq(_plasmaVault.balanceOf(), 5_000e18, "empty unpriced position ignored");
    }

    /// @notice (S8) Healthy mixed sub-account: 1.5 WETH of collateral (3 000 USD), 1 000 USDT of plain supply, 2 500 USDC
    ///         of debt: 1 000 + 500 = 1 500 USD, the same as netting everything.
    function testShouldKeepValueOfHealthyMixedSubAccount() external {
        _grantSubstrates(_mixedSubAccountB());
        _mockPosition(_eulerVaultWeth, _subAccountB, 1.4e18, 1.5e18, 0);
        _mockPosition(_eulerVaultUsdt, _subAccountB, 1_000e6, 1_000e6, 0);
        _mockPosition(_eulerVaultUsdc, _subAccountB, 0, 0, 2_500e6);

        assertEq(_plasmaVault.balanceOf(), 1_500e18, "healthy: unchanged");
    }

    //******************************************************************************************************************
    //********************                              HELPERS                                     ********************
    //******************************************************************************************************************

    /// @dev Sub-account A: plain supply in `supplyVault_`; sub-account B: collateral in `collateralVault_` and debt in
    ///      `borrowVault_`
    function _threeSubstrates(
        address supplyVault_,
        bytes1 supplySubAccount_,
        address collateralVault_,
        address borrowVault_
    ) private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](3);
        substrates[0] = _substrate(supplyVault_, false, false, supplySubAccount_);
        substrates[1] = _substrate(collateralVault_, true, false, _SUB_ACCOUNT_B);
        substrates[2] = _substrate(borrowVault_, false, true, _SUB_ACCOUNT_B);
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

    function _grantSubstrates(bytes32[] memory substrates_) private {
        _plasmaVault.grantMarketSubstrates(_MARKET_ID, substrates_);
    }

    function _codeAddress(string memory name_) private returns (address account) {
        account = makeAddr(name_);
        vm.etch(account, hex"00");
    }

    function _mockToken(address token_, uint8 decimals_, uint256 priceUsd_) private {
        vm.mockCall(token_, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(decimals_));
        vm.mockCall(
            _middleware,
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, token_),
            abi.encode(priceUsd_, _PRICE_DECIMALS)
        );
    }

    function _mockEulerVaultAsset(address eulerVault_, address asset_) private {
        vm.mockCall(eulerVault_, abi.encodeWithSelector(ERC4626.asset.selector), abi.encode(asset_));
    }

    function _mockPosition(
        address eulerVault_,
        address subAccount_,
        uint256 shares_,
        uint256 assets_,
        uint256 debt_
    ) private {
        vm.mockCall(eulerVault_, abi.encodeWithSelector(IERC20.balanceOf.selector, subAccount_), abi.encode(shares_));
        if (shares_ > 0) {
            vm.mockCall(
                eulerVault_,
                abi.encodeWithSelector(ERC4626.convertToAssets.selector, shares_),
                abi.encode(assets_)
            );
        }
        vm.mockCall(eulerVault_, abi.encodeWithSelector(IBorrowing.debtOf.selector, subAccount_), abi.encode(debt_));
    }

    /// @dev Sub-account B: WETH collateral, USDT plain supply, USDC debt
    function _mixedSubAccountB() private view returns (bytes32[] memory substrates) {
        substrates = new bytes32[](3);
        substrates[0] = _substrate(_eulerVaultWeth, true, false, _SUB_ACCOUNT_B);
        substrates[1] = _substrate(_eulerVaultUsdt, false, false, _SUB_ACCOUNT_B);
        substrates[2] = _substrate(_eulerVaultUsdc, false, true, _SUB_ACCOUNT_B);
    }

    function _one(address a_) private pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a_;
    }

    function _two(address a_, address b_) private pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a_;
        list[1] = b_;
    }

    /// @dev Collaterals enabled on the EVC by `account_`, also answered through `isCollateralEnabled`
    function _mockCollaterals(address account_, address[] memory collaterals_) private {
        vm.mockCall(_evc, abi.encodeWithSelector(IEVC.getCollaterals.selector, account_), abi.encode(collaterals_));

        address[3] memory eulerVaults = [_eulerVaultUsdt, _eulerVaultWeth, _eulerVaultUsdc];

        for (uint256 i; i < eulerVaults.length; ++i) {
            bool enabled;
            for (uint256 j; j < collaterals_.length; ++j) {
                enabled = enabled || collaterals_[j] == eulerVaults[i];
            }
            vm.mockCall(
                _evc,
                abi.encodeWithSelector(IEVC.isCollateralEnabled.selector, account_, eulerVaults[i]),
                abi.encode(enabled)
            );
        }
    }

    /// @dev Whether `controller_` recognizes `collateral_` (EVK: LTV configured, targetTimestamp != 0)
    function _mockRecognized(address controller_, address collateral_, bool recognized_) private {
        vm.mockCall(
            controller_,
            abi.encodeWithSelector(IEulerV2VaultGovernance.LTVFull.selector, collateral_),
            abi.encode(uint16(8_500), uint16(9_000), uint16(9_000), uint48(recognized_ ? 1 : 0), uint32(0))
        );
    }

    function _mockConfigFlags(address eulerVault_, uint32 flags_) private {
        vm.mockCall(
            eulerVault_,
            abi.encodeWithSelector(IEulerV2VaultGovernance.configFlags.selector),
            abi.encode(flags_)
        );
    }

    function _mockTotalSupply(address eulerVault_, uint256 totalSupply_) private {
        vm.mockCall(eulerVault_, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply_));
    }
}
