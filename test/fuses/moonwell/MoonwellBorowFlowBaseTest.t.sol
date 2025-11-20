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
import {MoonwellHelper} from "../../test_helpers/MoonwellHelper.sol";
import {MoonwellSupplyFuseEnterData} from "../../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {MoonwellEnableMarketFuseEnterData, MoonwellEnableMarketFuseExitData} from "../../../contracts/fuses/moonwell/MoonwellEnableMarketFuse.sol";
import {MoonwellBorrowFuseEnterData, MoonwellBorrowFuseExitData} from "../../../contracts/fuses/moonwell/MoonwellBorrowFuse.sol";
import {MoonWellAddresses} from "../../test_helpers/MoonwellHelper.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

contract MoonwellBorowFlowBaseTest is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address private constant _UNDERLYING_TOKEN = TestAddresses.BASE_WSTETH;
    string private constant _UNDERLYING_TOKEN_NAME = "WSTETH";
    address private constant _USER = TestAddresses.USER;
    uint256 private constant ERROR_DELTA = 100;

    PlasmaVault private _plasmaVault;
    PriceOracleMiddleware private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    MoonWellAddresses private _moonwellAddresses;

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
        _accessManager.setupInitRoles(
            _plasmaVault,
            address(0x123),
            address(new RewardsClaimManager(address(_accessManager), address(_plasmaVault)))
        );

        address[] memory mTokens = new address[](3);
        mTokens[0] = TestAddresses.BASE_M_WSTETH;
        mTokens[1] = TestAddresses.BASE_M_CBBTC;
        mTokens[2] = TestAddresses.BASE_M_CBETH;

        vm.stopPrank();
        // Use addFullMarket instead of addSupplyToMarket
        _moonwellAddresses = MoonwellHelper.addFullMarket(
            _plasmaVault,
            mTokens,
            TestAddresses.BASE_MOONWELL_COMPTROLLER,
            vm
        );

        // Deploy and add wstETH price feed
        vm.startPrank(TestAddresses.ATOMIST);
        address wstEthPriceFeed = PriceOracleMiddlewareHelper.deployWstEthPriceFeedOnBase();
        _priceOracleMiddleware.addSource(TestAddresses.BASE_WSTETH, wstEthPriceFeed);
        _priceOracleMiddleware.addSource(TestAddresses.BASE_CBBTC, TestAddresses.BASE_CHAINLINK_CBBTC_PRICE);
        _priceOracleMiddleware.addSource(TestAddresses.BASE_CBETH, TestAddresses.BASE_CHAINLINK_CBETH_PRICE);
        vm.stopPrank();

        deal(_UNDERLYING_TOKEN, _USER, 100e18); // Note: wstETH uses 18 decimals

        vm.startPrank(_USER);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 100e18);
        _plasmaVault.deposit(100e18, _USER);
        vm.stopPrank();
    }

    function testSupplyWstEthEnableMarketAndBorrowCbEth() public {
        // Setup supply action - 50 wstETH
        uint256 supplyAmount = 50e18;
        MoonwellSupplyFuseEnterData memory supplyData = MoonwellSupplyFuseEnterData({
            asset: TestAddresses.BASE_WSTETH,
            amount: supplyAmount
        });

        // Setup enable market action
        address[] memory marketsToEnable = new address[](1);
        marketsToEnable[0] = TestAddresses.BASE_M_WSTETH;
        MoonwellEnableMarketFuseEnterData memory enableData = MoonwellEnableMarketFuseEnterData({
            mTokens: marketsToEnable
        });

        // Setup borrow action - 1 cbETH
        uint256 borrowAmount = 1e18;
        MoonwellBorrowFuseEnterData memory borrowData = MoonwellBorrowFuseEnterData({
            asset: TestAddresses.BASE_CBETH,
            amount: borrowAmount
        });

        // Create array of actions
        FuseAction[] memory actions = new FuseAction[](3);

        // Supply action
        actions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", supplyData)
        });

        // Enable market action
        actions[1] = FuseAction({
            fuse: _moonwellAddresses.enableMarketFuse,
            data: abi.encodeWithSignature("enter((address[]))", enableData)
        });

        // Borrow action
        actions[2] = FuseAction({
            fuse: _moonwellAddresses.borrowFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", borrowData)
        });

        // Initial balance checks
        uint256 initialMoonwellBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);
        uint256 initialErc20Balance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        uint256 initialWstEthBalance = IERC20(TestAddresses.BASE_WSTETH).balanceOf(address(_plasmaVault));
        uint256 initialCbEthBalance = IERC20(TestAddresses.BASE_CBETH).balanceOf(address(_plasmaVault));

        // Execute all actions
        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(actions);
        vm.stopPrank();

        // Final balance checks
        uint256 finalMoonwellBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);
        uint256 finalErc20Balance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        uint256 finalWstEthBalance = IERC20(TestAddresses.BASE_WSTETH).balanceOf(address(_plasmaVault));
        uint256 finalCbEthBalance = IERC20(TestAddresses.BASE_CBETH).balanceOf(address(_plasmaVault));

        // Assert initial balances
        assertEq(initialMoonwellBalance, 0, "Initial Moonwell balance should be 0");
        assertEq(initialErc20Balance, 0, "Initial ERC20 balance should be 0");
        assertEq(initialWstEthBalance, 100e18, "Initial wstETH balance should be 100");
        assertEq(initialCbEthBalance, 0, "Initial cbETH balance should be 0");

        // Assert final balances with small error delta for floating point calculations
        assertApproxEqAbs(finalMoonwellBalance, 49087648471794404612, ERROR_DELTA, "Final Moonwell balance incorrect");
        assertApproxEqAbs(finalErc20Balance, 912351528146566905, ERROR_DELTA, "Final ERC20 balance incorrect");
        assertEq(finalWstEthBalance, 50e18, "Final wstETH balance should be 50");
        assertEq(finalCbEthBalance, 1e18, "Final cbETH balance should be 1");
    }

    function testSupplyBorrowRepayAndExit() public {
        // PART 1: Create position
        uint256 supplyAmount = 50e18;
        uint256 borrowAmount = 1e18;

        // Get initial state
        PositionState memory initialState = _getPositionState();

        // Create and execute initial position
        FuseAction[] memory createPositionActions = _createPositionActions(supplyAmount, borrowAmount);

        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(createPositionActions);
        vm.stopPrank();

        // Verify position creation
        PositionState memory positionState = _getPositionState();
        _verifyInitialState(initialState);
        _verifyPositionState(positionState);

        // PART 2: Repay and exit
        FuseAction[] memory closePositionActions = _createClosePositionActions(borrowAmount);

        vm.startPrank(TestAddresses.ALPHA);
        _plasmaVault.execute(closePositionActions);
        vm.stopPrank();

        // Verify final state
        PositionState memory finalState = _getPositionState();
        _verifyFinalState(finalState);
    }

    // Helper struct to store position state
    struct PositionState {
        uint256 moonwellBalance;
        uint256 erc20Balance;
        uint256 wstEthBalance;
        uint256 cbEthBalance;
    }

    function _getPositionState() private view returns (PositionState memory state) {
        state.moonwellBalance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.MOONWELL);
        state.erc20Balance = _plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC20_VAULT_BALANCE);
        state.wstEthBalance = IERC20(TestAddresses.BASE_WSTETH).balanceOf(address(_plasmaVault));
        state.cbEthBalance = IERC20(TestAddresses.BASE_CBETH).balanceOf(address(_plasmaVault));
        return state;
    }

    function _verifyInitialState(PositionState memory state) private {
        assertEq(state.moonwellBalance, 0, "Initial Moonwell balance should be 0");
        assertEq(state.erc20Balance, 0, "Initial ERC20 balance should be 0");
        assertEq(state.wstEthBalance, 100e18, "Initial wstETH balance should be 100");
        assertEq(state.cbEthBalance, 0, "Initial cbETH balance should be 0");
    }

    function _verifyPositionState(PositionState memory state) private {
        assertApproxEqAbs(
            state.moonwellBalance,
            49087648471794404612,
            ERROR_DELTA,
            "Position Moonwell balance incorrect"
        );
        assertApproxEqAbs(state.erc20Balance, 912351528146566905, ERROR_DELTA, "Position ERC20 balance incorrect");
        assertEq(state.wstEthBalance, 50e18, "Position wstETH balance should be 50");
        assertEq(state.cbEthBalance, 1e18, "Position cbETH balance should be 1");
    }

    function _verifyFinalState(PositionState memory state) private {
        assertApproxEqAbs(
            state.moonwellBalance,
            49999999999940971518,
            ERROR_DELTA,
            "Final Moonwell balance should be 49999999999940971518"
        );
        assertApproxEqAbs(state.erc20Balance, 0, ERROR_DELTA, "Final ERC20 balance should be 0");
        assertEq(state.wstEthBalance, 50e18, "Final wstETH balance should be back to 100");
        assertEq(state.cbEthBalance, 0, "Final cbETH balance should be 0");
    }

    function _createClosePositionActions(uint256 borrowAmount) private view returns (FuseAction[] memory) {
        // Setup repay action
        MoonwellBorrowFuseExitData memory repayData = MoonwellBorrowFuseExitData({
            asset: TestAddresses.BASE_CBETH,
            amount: borrowAmount
        });

        // Setup exit market action
        address[] memory marketsToExit = new address[](1);
        marketsToExit[0] = TestAddresses.BASE_M_WSTETH;
        MoonwellEnableMarketFuseExitData memory exitMarketData = MoonwellEnableMarketFuseExitData({
            mTokens: marketsToExit
        });

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: _moonwellAddresses.borrowFuse,
            data: abi.encodeWithSignature("exit((address,uint256))", repayData)
        });
        // not needed only for testing
        actions[1] = FuseAction({
            fuse: _moonwellAddresses.enableMarketFuse,
            data: abi.encodeWithSignature("exit((address[]))", exitMarketData)
        });

        return actions;
    }

    // Helper function to create position actions (extracted from testSupplyWstEthEnableMarketAndBorrowCbEth)
    function _createPositionActions(
        uint256 supplyAmount,
        uint256 borrowAmount
    ) internal view returns (FuseAction[] memory) {
        // Supply data
        MoonwellSupplyFuseEnterData memory supplyData = MoonwellSupplyFuseEnterData({
            asset: TestAddresses.BASE_WSTETH,
            amount: supplyAmount
        });

        // Enable market data
        address[] memory marketsToEnable = new address[](1);
        marketsToEnable[0] = TestAddresses.BASE_M_WSTETH;
        MoonwellEnableMarketFuseEnterData memory enableData = MoonwellEnableMarketFuseEnterData({
            mTokens: marketsToEnable
        });

        // Borrow data
        MoonwellBorrowFuseEnterData memory borrowData = MoonwellBorrowFuseEnterData({
            asset: TestAddresses.BASE_CBETH,
            amount: borrowAmount
        });

        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = FuseAction({
            fuse: _moonwellAddresses.suppluFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", supplyData)
        });
        actions[1] = FuseAction({
            fuse: _moonwellAddresses.enableMarketFuse,
            data: abi.encodeWithSignature("enter((address[]))", enableData)
        });
        actions[2] = FuseAction({
            fuse: _moonwellAddresses.borrowFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", borrowData)
        });

        return actions;
    }
}
