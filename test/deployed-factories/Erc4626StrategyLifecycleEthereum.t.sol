// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {FuseAction, IPlasmaVault} from "../../contracts/interfaces/IPlasmaVault.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {MarketLimit} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
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

/// @notice Full asset lifecycle of the catalogued ERC4626 pilot strategy on a vault
/// created by the unchanged deployed factory: deposit, supply into the ERC4626 vault,
/// exit back, and redeem.
/// @dev Fixture type: deployed-usage. The deployment is never upgraded, etched or
/// granted anything. Test-only shortcuts are limited to `deal` for the depositor's
/// USDC and one `vm.warp` past the vault's own redemption delay; both are marked
/// where they happen and neither exists on a network.
contract Erc4626StrategyLifecycleEthereumTest is Test {
    address private constant PILOT_FACTORY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Steakhouse USDC, a MetaMorpho ERC4626 vault denominated in USDC.
    address private constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    /// @dev Catalogued deployments, `observed` in catalog/fuses.json at this block.
    address private constant SUPPLY_FUSE = 0x12FD0EE183c85940CAedd4877f5d3Fc637515870;
    address private constant BALANCE_FUSE = 0x2C10C36028C430f445a4bA9f7Dd096a5DcC75d5e;
    uint256 private constant FORK_BLOCK = 25937526;
    uint256 private constant REDEMPTION_DELAY = 1 hours;
    uint256 private constant DEPOSIT = 100_000e6;
    uint256 private constant SUPPLIED = 40_000e6;
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
            "Strategy Lifecycle USDC Vault",
            "slUSDC",
            USDC,
            REDEMPTION_DELAY,
            owner,
            0
        );
    }

    function testShouldRunTheFullAssetLifecycleOfThePilotStrategy() public {
        _configureStrategy();

        // --- deposit ---------------------------------------------------------
        // Test-only: the depositor's USDC is dealt, never acquired on a market.
        deal(USDC, depositor, DEPOSIT);
        vm.startPrank(depositor);
        IERC20(USDC).approve(instance.plasmaVault, DEPOSIT);
        uint256 shares = IERC4626(instance.plasmaVault).deposit(DEPOSIT, depositor);
        vm.stopPrank();

        assertGt(shares, 0, "deposit minted no shares");
        assertApproxEqAbs(IERC4626(instance.plasmaVault).totalAssets(), DEPOSIT, TOLERANCE, "assets lost on deposit");
        assertEq(IERC20(USDC).balanceOf(instance.plasmaVault), DEPOSIT, "vault does not hold the deposit");

        // --- strategy operation: supply into the ERC4626 vault ---------------
        uint256 externalSharesBefore = IERC4626(STEAKHOUSE_USDC).balanceOf(instance.plasmaVault);

        // The deployed fuse is an older version of Erc4626SupplyFuse: its enter
        // and exit take (vault, amount) only, without this checkout's slippage
        // bounds. The deployed interface is what the vault will delegatecall, so
        // it is what the test encodes.
        FuseAction[] memory enter = new FuseAction[](1);
        enter[0] = FuseAction(
            SUPPLY_FUSE,
            abi.encodeWithSignature("enter((address,uint256))", DeployedSupplyFuseData(STEAKHOUSE_USDC, SUPPLIED))
        );
        vm.prank(alpha);
        IPlasmaVault(instance.plasmaVault).execute(enter);

        assertGt(
            IERC4626(STEAKHOUSE_USDC).balanceOf(instance.plasmaVault),
            externalSharesBefore,
            "no ERC4626 shares received"
        );
        assertEq(IERC20(USDC).balanceOf(instance.plasmaVault), DEPOSIT - SUPPLIED, "wrong amount left idle");
        assertApproxEqAbs(
            IERC4626(instance.plasmaVault).totalAssets(),
            DEPOSIT,
            TOLERANCE,
            "total assets changed by moving funds into the market"
        );

        // --- exit the strategy ----------------------------------------------
        FuseAction[] memory exit = new FuseAction[](1);
        exit[0] = FuseAction(
            SUPPLY_FUSE,
            abi.encodeWithSignature("exit((address,uint256))", DeployedSupplyFuseData(STEAKHOUSE_USDC, SUPPLIED))
        );
        vm.prank(alpha);
        IPlasmaVault(instance.plasmaVault).execute(exit);

        assertApproxEqAbs(
            IERC20(USDC).balanceOf(instance.plasmaVault),
            DEPOSIT,
            TOLERANCE,
            "funds did not come back to the vault"
        );

        // --- redeem ----------------------------------------------------------
        // Test-only: the vault's own redemption delay is waited out by warping.
        vm.warp(block.timestamp + REDEMPTION_DELAY + 1);

        vm.prank(depositor);
        uint256 assetsOut = IERC4626(instance.plasmaVault).redeem(shares, depositor, depositor);

        assertApproxEqAbs(assetsOut, DEPOSIT, TOLERANCE, "redeemed a different amount than deposited");
        assertApproxEqAbs(IERC20(USDC).balanceOf(depositor), DEPOSIT, TOLERANCE, "depositor was not made whole");
        assertEq(IERC4626(instance.plasmaVault).balanceOf(depositor), 0, "shares left after full redeem");
    }

    function _configureStrategy() private {
        vm.startPrank(owner);
        IAccessManager(instance.accessManager).grantRole(Roles.ATOMIST_ROLE, owner, 0);
        IAccessManager(instance.accessManager).grantRole(Roles.FUSE_MANAGER_ROLE, owner, 0);
        IAccessManager(instance.accessManager).grantRole(Roles.ALPHA_ROLE, alpha, 0);
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
