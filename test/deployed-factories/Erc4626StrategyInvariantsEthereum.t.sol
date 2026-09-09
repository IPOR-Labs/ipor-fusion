// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {FuseAction, IPlasmaVault} from "../../contracts/interfaces/IPlasmaVault.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {
    AssetDistributionProtectionLib,
    MarketLimit
} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {RedemptionDelayLib} from "../../contracts/managers/access/RedemptionDelayLib.sol";
import {IPriceOracleMiddleware} from "../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";

/// @dev Data of the *deployed* ERC4626 supply fuse (selectors 0xd5ee7916 / 0x92876ac8),
/// which predates the slippage bounds this checkout's Erc4626SupplyFuse.sol has.
struct DeployedSupplyFuseData {
    address vault;
    uint256 vaultAssetAmount;
}

/// @dev Minimal interface transcribed from the implementation-bound T22 ABI.
interface IPilotFusionFactory {
    struct FusionInstance {
        uint256 index;
        uint256 version;
        string assetName;
        string assetSymbol;
        uint8 assetDecimals;
        address underlyingToken;
        string underlyingTokenSymbol;
        uint8 underlyingTokenDecimals;
        address initialOwner;
        address plasmaVault;
        address plasmaVaultBase;
        address accessManager;
        address feeManager;
        address rewardsManager;
        address withdrawManager;
        address contextManager;
        address priceManager;
    }

    function clone(
        string memory assetName,
        string memory assetSymbol,
        address underlyingToken,
        uint256 redemptionDelayInSeconds,
        address owner,
        uint256 daoFeePackageIndex
    ) external returns (FusionInstance memory);
}

/// @notice The properties docs/invariants.md lists as postulated for the pilot path,
/// pinned down on a vault created by the unchanged deployed factory and running the
/// catalogued, unchanged ERC4626 fuses: each test is one row of that document.
/// @dev Fixture type: deployed-usage. The deployment is never upgraded, etched or
/// granted anything. Test-only shortcuts are limited to `deal` for the depositor's
/// USDC and `vm.warp` where a delay is waited out or interest is let to accrue; each is
/// marked where it happens.
contract Erc4626StrategyInvariantsEthereumTest is Test {
    address private constant PILOT_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Steakhouse USDC, a MetaMorpho ERC4626 vault denominated in USDC: the only substrate.
    address private constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    /// @dev Gauntlet USDC Prime, another USDC MetaMorpho vault that is deliberately NOT granted.
    address private constant GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;
    /// @dev Catalogued deployments, `observed` in catalog/fuses.json at this block.
    address private constant SUPPLY_FUSE = 0x12FD0EE183c85940CAedd4877f5d3Fc637515870;
    address private constant BALANCE_FUSE = 0x2C10C36028C430f445a4bA9f7Dd096a5DcC75d5e;
    uint256 private constant FORK_BLOCK = 25937526;
    /// @dev Time the yield-accrual test lets pass. Steakhouse USDC is a MetaMorpho vault
    /// whose totalAssets accrue Morpho Blue interest from block.timestamp, so warping
    /// moves its share price without reading another block.
    uint256 private constant ACCRUAL_PERIOD = 7 days;
    uint256 private constant REDEMPTION_DELAY = 1 hours;
    uint256 private constant DEPOSIT = 100_000e6;
    uint256 private constant SUPPLIED = 40_000e6;
    /// @dev 60% of the deposit against a 50% market limit.
    uint256 private constant OVER_LIMIT = 60_000e6;
    /// @dev ERC4626 rounding plus the vault's share accounting; 1 USDC on 100k.
    uint256 private constant TOLERANCE = 1e6;

    IPilotFusionFactory.FusionInstance private instance;
    address private owner;
    address private alpha;
    address private depositor;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), vm.envOr("FUSION_FORK_BLOCK", FORK_BLOCK));

        owner = makeAddr("pilotVaultOwner");
        alpha = makeAddr("pilotAlpha");
        depositor = makeAddr("pilotDepositor");

        vm.prank(makeAddr("pilotCaller"));
        instance = IPilotFusionFactory(PILOT_FACTORY).clone(
            "Strategy Invariants USDC Vault",
            "siUSDC",
            USDC,
            REDEMPTION_DELAY,
            owner,
            0
        );
        _configureStrategy();
    }

    /// @dev W1: a depositor cannot redeem before the vault's redemption delay has passed.
    function testW1ShouldRefuseRedeemBeforeTheRedemptionDelay() public {
        uint256 shares = _deposit();
        uint256 depositedAt = block.timestamp;

        // One second before the delay ends: still locked.
        vm.warp(depositedAt + REDEMPTION_DELAY - 1);
        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(RedemptionDelayLib.AccountIsLocked.selector, depositedAt + REDEMPTION_DELAY)
        );
        IERC4626(instance.plasmaVault).redeem(shares, depositor, depositor);

        // Test-only: the delay itself is waited out by warping; then the same call succeeds.
        vm.warp(depositedAt + REDEMPTION_DELAY);
        vm.prank(depositor);
        uint256 assetsOut = IERC4626(instance.plasmaVault).redeem(shares, depositor, depositor);
        assertApproxEqAbs(assetsOut, DEPOSIT, TOLERANCE, "redeem after the delay returned a different amount");
    }

    /// @dev P4: the deployed fuse refuses a substrate that was never granted, even a
    /// vault of the right asset.
    function testP4ShouldRefuseAVaultThatIsNotAGrantedSubstrate() public {
        _deposit();
        assertEq(IERC4626(GAUNTLET_USDC_PRIME).asset(), USDC, "the control vault is not a USDC vault");

        FuseAction[] memory enter = new FuseAction[](1);
        enter[0] = FuseAction(
            SUPPLY_FUSE,
            abi.encodeWithSignature("enter((address,uint256))", DeployedSupplyFuseData(GAUNTLET_USDC_PRIME, SUPPLIED))
        );
        vm.prank(alpha);
        vm.expectRevert(
            abi.encodeWithSignature("Erc4626SupplyFuseUnsupportedVault(string,address)", "enter", GAUNTLET_USDC_PRIME)
        );
        IPlasmaVault(instance.plasmaVault).execute(enter);

        assertEq(
            IERC4626(GAUNTLET_USDC_PRIME).balanceOf(instance.plasmaVault),
            0,
            "shares of the refused vault appeared"
        );
        assertEq(IERC20(USDC).balanceOf(instance.plasmaVault), DEPOSIT, "idle balance changed on a refused action");
    }

    /// @dev P5: a market cannot exceed its configured share of the vault's assets.
    function testP5ShouldRefuseASupplyAboveTheMarketLimit() public {
        _deposit();

        FuseAction[] memory enter = new FuseAction[](1);
        enter[0] = FuseAction(
            SUPPLY_FUSE,
            abi.encodeWithSignature("enter((address,uint256))", DeployedSupplyFuseData(STEAKHOUSE_USDC, OVER_LIMIT))
        );
        vm.prank(alpha);
        vm.expectPartialRevert(AssetDistributionProtectionLib.MarketLimitExceeded.selector);
        IPlasmaVault(instance.plasmaVault).execute(enter);

        // The same vault accepts a supply within the limit.
        enter[0] = FuseAction(
            SUPPLY_FUSE,
            abi.encodeWithSignature("enter((address,uint256))", DeployedSupplyFuseData(STEAKHOUSE_USDC, SUPPLIED))
        );
        vm.prank(alpha);
        IPlasmaVault(instance.plasmaVault).execute(enter);
        assertEq(IERC20(USDC).balanceOf(instance.plasmaVault), DEPOSIT - SUPPLIED, "supply within the limit failed");
    }

    /// @dev A6: total assets track yield accruing in the external ERC4626 vault.
    function testA6ShouldTrackYieldAccruedInTheExternalVault() public {
        _deposit();
        _supply(SUPPLIED);

        uint256 externalShares = IERC4626(STEAKHOUSE_USDC).balanceOf(instance.plasmaVault);
        uint256 valueBefore = IERC4626(STEAKHOUSE_USDC).convertToAssets(externalShares);
        uint256 totalBefore = IERC4626(instance.plasmaVault).totalAssets();

        // Test-only: let interest accrue. The external vault's share price moves because
        // Morpho Blue accrues interest from block.timestamp on the pinned state; nothing
        // else on the fork changes.
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
        assertEq(IERC4626(STEAKHOUSE_USDC).balanceOf(instance.plasmaVault), externalShares, "external shares changed");

        uint256 valueAfter = IERC4626(STEAKHOUSE_USDC).convertToAssets(externalShares);
        assertGt(valueAfter, valueBefore, "the external vault accrued no yield over the period");

        // The market balance is cached; the alpha refreshes it as on a network.
        uint256[] memory markets = new uint256[](1);
        markets[0] = IporFusionMarkets.ERC4626_0001;
        vm.prank(alpha);
        IPlasmaVault(instance.plasmaVault).updateMarketsBalances(markets);

        // totalAssets() is net of the management fee accrued over the same period, so
        // the accrual is compared gross of that fee.
        uint256 totalAfter = IERC4626(instance.plasmaVault).totalAssets();
        uint256 unrealizedManagementFee = IPlasmaVault(instance.plasmaVault).getUnrealizedManagementFee();
        assertGt(totalAfter + unrealizedManagementFee, totalBefore, "total assets did not follow the accrual");
        assertApproxEqAbs(
            totalAfter + unrealizedManagementFee - totalBefore,
            valueAfter - valueBefore,
            TOLERANCE,
            "accrual not reflected in total assets"
        );
        emit log_named_uint("accrued in the external vault (USDC, 6 decimals)", valueAfter - valueBefore);
        emit log_named_uint("unrealized management fee (USDC, 6 decimals)", unrealizedManagementFee);
    }

    function _deposit() private returns (uint256 shares) {
        // Test-only: the depositor's USDC is dealt, never acquired on a market.
        deal(USDC, depositor, DEPOSIT);
        vm.startPrank(depositor);
        IERC20(USDC).approve(instance.plasmaVault, DEPOSIT);
        shares = IERC4626(instance.plasmaVault).deposit(DEPOSIT, depositor);
        vm.stopPrank();
    }

    function _supply(uint256 amount) private {
        FuseAction[] memory enter = new FuseAction[](1);
        enter[0] = FuseAction(
            SUPPLY_FUSE,
            abi.encodeWithSignature("enter((address,uint256))", DeployedSupplyFuseData(STEAKHOUSE_USDC, amount))
        );
        vm.prank(alpha);
        IPlasmaVault(instance.plasmaVault).execute(enter);
    }

    function _configureStrategy() private {
        vm.startPrank(owner);
        IAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IAccessManager(instance.accessManager).grantRole(Roles.FUSE_MANAGER_ROLE, owner, 0);
        IAccessManager(instance.accessManager).grantRole(Roles.ALPHA_ROLE, alpha, 0);
        IAccessManager(instance.accessManager).grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, alpha, 0);
        IAccessManager(instance.accessManager).grantRole(Roles.WHITELIST_ROLE, depositor, 0);

        address[] memory fuses = new address[](1);
        fuses[0] = SUPPLY_FUSE;
        IPlasmaVaultGovernance(instance.plasmaVault).addFuses(fuses);
        IPlasmaVaultGovernance(instance.plasmaVault).addBalanceFuse(IporFusionMarkets.ERC4626_0001, BALANCE_FUSE);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(STEAKHOUSE_USDC)));
        IPlasmaVaultGovernance(instance.plasmaVault).grantMarketSubstrates(IporFusionMarkets.ERC4626_0001, substrates);

        MarketLimit[] memory limits = new MarketLimit[](1);
        // 1e18 is 100% of the vault's assets; this caps the market at 50%.
        limits[0] = MarketLimit({marketId: IporFusionMarkets.ERC4626_0001, limitInPercentage: 5e17});
        IPlasmaVaultGovernance(instance.plasmaVault).setupMarketsLimits(limits);
        IPlasmaVaultGovernance(instance.plasmaVault).activateMarketsLimits();
        vm.stopPrank();
    }
}
