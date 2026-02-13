// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {MoonwellHelper, MoonWellAddresses} from "../../test_helpers/MoonwellHelper.sol";
import {MoonwellSupplyFuseEnterData} from "../../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {MoonwellClaimFuse, MoonwellClaimFuseData} from "../../../contracts/rewards_fuses/moonwell/MoonwellClaimFuse.sol";

contract MoonwellClaimFuseBaseTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address private constant _UNDERLYING_TOKEN = TestAddresses.BASE_USDC;
    string private constant _UNDERLYING_TOKEN_NAME = "USDC";
    address private constant _USER = TestAddresses.USER;
    uint256 private constant ERROR_DELTA = 100;

    PlasmaVault private _plasmaVault;
    PriceOracleMiddleware private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    RewardsClaimManager private _rewardsClaimManager;

    MoonWellAddresses private _moonwellAddresses;
    MoonwellClaimFuse private _claimFuse;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 22136992);

        // Deploy price oracle middleware
        vm.startPrank(TestAddresses.ATOMIST);
        _priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            TestAddresses.ATOMIST,
            address(0)
        );
        vm.stopPrank();
        // Deploy minimal plasma vault
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: _UNDERLYING_TOKEN,
            underlyingTokenName: _UNDERLYING_TOKEN_NAME,
            priceOracleMiddleware: _priceOracleMiddleware.addressOf(),
            atomist: TestAddresses.ATOMIST
        });

        vm.startPrank(TestAddresses.ATOMIST);
        (_plasmaVault, ) = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        _accessManager = _plasmaVault.accessManagerOf();
        _rewardsClaimManager = new RewardsClaimManager(address(_accessManager), address(_plasmaVault));
        _plasmaVault.addRewardsClaimManager(address(_rewardsClaimManager));

        _accessManager.setupInitRoles(_plasmaVault, address(0x123), address(_rewardsClaimManager));

        address[] memory mTokens = new address[](1);
        mTokens[0] = TestAddresses.BASE_M_USDC;

        _moonwellAddresses = MoonwellHelper.addSupplyToMarket(_plasmaVault, mTokens, vm);

        vm.startPrank(TestAddresses.ATOMIST);
        _priceOracleMiddleware.addSource(TestAddresses.BASE_USDC, TestAddresses.BASE_CHAINLINK_USDC_PRICE);
        vm.stopPrank();

        deal(_UNDERLYING_TOKEN, _USER, 1000e6);

        vm.startPrank(_USER);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 1000e6);
        _plasmaVault.deposit(1000e6, _USER);
        vm.stopPrank();

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        _addClaimFuses();
        vm.stopPrank();
    }

    function _addClaimFuses() internal {
        _claimFuse = new MoonwellClaimFuse(IporFusionMarkets.MOONWELL, TestAddresses.BASE_MOONWELL_COMPTROLLER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(_claimFuse);
        _rewardsClaimManager.addRewardFuses(fuses);
    }

    function testShouldCalimRewards() public {
        address rewordsToken0 = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address rewordsToken1 = 0xA88594D404727625A9437C3f886C7643872296AE;
        // Setup
        uint256 supplyAmount = 500e6; // 500 USDC

        // Prepare supply action
        MoonwellSupplyFuseEnterData memory enterData = MoonwellSupplyFuseEnterData({
            asset: _UNDERLYING_TOKEN,
            amount: supplyAmount
        });

        // Create FuseAction for supply
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        // Execute supply through PlasmaVault
        vm.prank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);

        vm.warp(block.timestamp + 100 days);

        address[] memory mTokens = new address[](1);
        mTokens[0] = TestAddresses.BASE_M_USDC;

        FuseAction[] memory claimActions = new FuseAction[](1);
        claimActions[0] = FuseAction({
            fuse: address(_claimFuse),
            data: abi.encodeWithSignature("claim((address[]))", MoonwellClaimFuseData({mTokens: mTokens}))
        });

        uint256 rewardsToken0BalanceBefore = IERC20(rewordsToken0).balanceOf(address(_rewardsClaimManager));
        uint256 rewardsToken1BalanceBefore = IERC20(rewordsToken1).balanceOf(address(_rewardsClaimManager));

        vm.prank(TestAddresses.CLAIM_REWARDS);
        _rewardsClaimManager.claimRewards(claimActions);

        uint256 rewardsToken0BalanceAfter = IERC20(rewordsToken0).balanceOf(address(_rewardsClaimManager));
        uint256 rewardsToken1BalanceAfter = IERC20(rewordsToken1).balanceOf(address(_rewardsClaimManager));

        // Assert initial balances
        assertEq(rewardsToken0BalanceBefore, 0, "Initial rewards token 0 balance should be 0");
        assertEq(rewardsToken1BalanceBefore, 0, "Initial rewards token 1 balance should be 0");

        // Assert final balances
        assertEq(rewardsToken0BalanceAfter, 1507, "Final rewards token 0 balance incorrect");
        assertEq(rewardsToken1BalanceAfter, 3611187923739266575, "Final rewards token 1 balance incorrect");

        // Assert rewards were claimed (deltas)
        assertEq(
            rewardsToken0BalanceAfter - rewardsToken0BalanceBefore,
            1507,
            "Rewards token 0 claimed amount incorrect"
        );
        assertEq(
            rewardsToken1BalanceAfter - rewardsToken1BalanceBefore,
            3611187923739266575,
            "Rewards token 1 claimed amount incorrect"
        );
    }
}
