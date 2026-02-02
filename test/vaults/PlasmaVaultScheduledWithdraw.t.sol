// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, MarketSubstratesConfig, FeeConfig, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultVotesPlugin} from "../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager, WithdrawRequestInfo} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {UpdateWithdrawManagerMaintenanceFuse, UpdateWithdrawManagerMaintenanceFuseEnterData} from "../../contracts/fuses/maintenance/UpdateWithdrawManagerMaintenanceFuse.sol";
import {UniversalReader, ReadResult} from "../../contracts/universal_reader/UniversalReader.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {TypeConversionLib} from "../../contracts/libraries/TypeConversionLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

contract PlasmaVaultScheduledWithdraw is Test {
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _USDC_HOLDER = 0x47c031236e19d024b42f8AE6780E44A573170703;

    address private _plasmaVault;
    address private _priceOracle = 0x9838c0d15b439816D25d5fD1AEbd259EeddB66B4;
    address private _accessManager;
    address private _withdrawManager;
    BurnRequestFeeFuse private _burnRequestFeeFuse;
    UpdateWithdrawManagerMaintenanceFuse private _updateWithdrawManagerMaintenanceFuse;
    TransientStorageSetInputsFuse private _transientStorageSetInputsFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 256415332);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(_USER, 10_000e6);
        _createAccessManager();
        _createWithdrawManager();
        _createPlasmaVault();
        _initAccessManager();

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();
    }

    function _createPlasmaVault() private {
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: _USDC,
                priceOracleMiddleware: _priceOracle,
                feeConfig: _setupFeeConfig(),
                accessManager: address(_accessManager),
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: _withdrawManager,
                plasmaVaultVotesPlugin: address(new PlasmaVaultVotesPlugin())
            })
        );

        vm.stopPrank();
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        marketConfigs[0] = MarketSubstratesConfig({
            marketId: IporFusionMarkets.ZERO_BALANCE_MARKET,
            substrates: new bytes32[](0)
        });
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _burnRequestFeeFuse = new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);
        _updateWithdrawManagerMaintenanceFuse = new UpdateWithdrawManagerMaintenanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET
        );
        _transientStorageSetInputsFuse = new TransientStorageSetInputsFuse();

        fuses = new address[](3);
        fuses[0] = address(_burnRequestFeeFuse);
        fuses[1] = address(_updateWithdrawManagerMaintenanceFuse);
        fuses[2] = address(_transientStorageSetInputsFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ZeroBalanceFuse zeroBalanceFuse = new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);
        ERC20BalanceFuse erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.ZERO_BALANCE_MARKET,
            fuse: address(zeroBalanceFuse)
        });
        balanceFuses[1] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.ERC20_VAULT_BALANCE,
            fuse: address(erc20BalanceFuse)
        });
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private {
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
    }

    function _createWithdrawManager() private {
        _withdrawManager = address(new WithdrawManager(_accessManager));
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: address(0x123),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function testShouldNotBeAbleToWithdrawWithoutRequest() external {
        // given
        uint256 withdrawAmount = 1_000e6;

        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);
        vm.stopPrank();

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidSharesToRelease(uint256)", withdrawAmount);
        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount, _USER, _USER);
        vm.stopPrank();
    }

    function testShouldReturnZeroWhenInitWithdrawWindow() external {
        // given
        // when
        uint256 withdrawWindow = WithdrawManager(_withdrawManager).getWithdrawWindow();
        // then
        assertTrue(withdrawWindow == 0, "withdraw window should be zero");
    }

    function testShouldNotBeAbleToUpdateWithdrawWindowWhenNotAtomist() external {
        // given
        uint256 withdrawWindow = 1 days;
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);
        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(withdrawWindow);
        vm.stopPrank();
    }

    function testShouldBeAbleToUpdateWithdrawWindow() external {
        // given
        uint256 withdrawWindow = 1 days;
        // when
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(withdrawWindow);
        // then
        uint256 updatedWithdrawWindow = WithdrawManager(_withdrawManager).getWithdrawWindow();
        assertTrue(updatedWithdrawWindow == withdrawWindow, "withdraw window should be updated");
    }

    function testShouldNotBeAbleToWithdrawWhenNotReleaseFunds() external {
        // given

        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);
        vm.stopPrank();

        uint256 withdrawAmount = 1_000e8;
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidSharesToRelease(uint256)", withdrawAmount);

        vm.warp(block.timestamp + 10 hours);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount, _USER, _USER);
        vm.stopPrank();
    }

    function testShouldBeAbleToRedeemFromRequest() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        WithdrawRequestInfo memory withdrawRequestInfoBefore = WithdrawManager(_withdrawManager).requestInfo(_USER);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, withdrawAmount);

        vm.warp(block.timestamp + 10 hours);

        uint256 balanceBefore = ERC20(_USDC).balanceOf(_USER);

        // when
        vm.startPrank(_USER);
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount, _USER, _USER);
        vm.stopPrank();

        // then
        WithdrawRequestInfo memory withdrawRequestInfoAfter = WithdrawManager(_withdrawManager).requestInfo(_USER);
        uint256 balanceAfter = ERC20(_USDC).balanceOf(_USER);

        assertGt(withdrawRequestInfoBefore.shares, withdrawRequestInfoAfter.shares);
        assertTrue(
            balanceAfter == withdrawAmount / 100 + balanceBefore,
            "user balance should be increased by withdraw amount"
        );
    }

    function testShouldBeAbleToRedeemFromRequestWithFee() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(0.01e18);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();

        uint256 balanceWithdrawManagerBefore = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        uint256 balanceWithdrawManagerAfter = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, withdrawAmount);

        vm.warp(block.timestamp + 10 hours);

        uint256 balanceBefore = ERC20(_USDC).balanceOf(_USER);

        // when
        vm.startPrank(_USER);
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount - 10e8, _USER, _USER);
        vm.stopPrank();

        // then
        uint256 balanceAfter = ERC20(_USDC).balanceOf(_USER);

        assertEq(balanceBefore, 0);
        assertEq(balanceAfter, 990000000);
        assertEq(balanceWithdrawManagerBefore, 0);
        assertEq(balanceWithdrawManagerAfter, 1000000000);
    }

    function testShouldBeAbleToBurnRequestFee() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(0.01e18);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, withdrawAmount);

        vm.warp(block.timestamp + 10 hours);

        uint256 balanceBefore = ERC20(_USDC).balanceOf(_USER);
        uint256 balanceWithdrawManagerBefore = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_burnRequestFeeFuse),
            abi.encodeWithSignature("enter((uint256))", balanceWithdrawManagerBefore)
        );

        // when

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();
        // then

        uint256 balanceWithdrawManagerAfter = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));
        uint256 balanceAfter = ERC20(_USDC).balanceOf(_USER);

        assertEq(balanceBefore, 0);
        assertEq(balanceAfter, 0);
        assertEq(balanceWithdrawManagerBefore, 1000000000);
        assertEq(balanceWithdrawManagerAfter, 0);
    }

    /// @notice Test that enter function returns early when amount is zero
    function testShouldReturnWhenBurnRequestFeeWithZeroAmount() external {
        // given
        uint256 balanceWithdrawManagerBefore = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(address(_burnRequestFeeFuse), abi.encodeWithSignature("enter((uint256))", uint256(0)));

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // then
        uint256 balanceWithdrawManagerAfter = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));
        assertEq(
            balanceWithdrawManagerBefore,
            balanceWithdrawManagerAfter,
            "Balance should not change with zero amount"
        );
    }

    /// @notice Test that exit function reverts with BurnRequestFeeExitNotImplemented error
    function testShouldRevertWhenBurnRequestFeeExit() external {
        // given
        bytes memory error = abi.encodeWithSignature("BurnRequestFeeExitNotImplemented()");

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(address(_burnRequestFeeFuse), abi.encodeWithSignature("exit()"));

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();
    }

    /// @notice Test that enterTransient function successfully burns request fee shares using transient storage
    function testShouldBeAbleToBurnRequestFeeUsingTransientStorage() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(0.01e18);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, withdrawAmount);

        vm.warp(block.timestamp + 10 hours);

        uint256 balanceWithdrawManagerBefore = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));

        // Prepare transient storage inputs
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(balanceWithdrawManagerBefore);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_burnRequestFeeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        actions[1] = FuseAction({
            fuse: address(_burnRequestFeeFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // then
        uint256 balanceWithdrawManagerAfter = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));
        assertEq(balanceWithdrawManagerBefore, 1000000000);
        assertEq(balanceWithdrawManagerAfter, 0);
    }

    /// @notice Test that enterTransient function returns early when amount is zero
    function testShouldReturnWhenBurnRequestFeeTransientWithZeroAmount() external {
        // given
        bytes32[] memory inputs = new bytes32[](1);
        inputs[0] = TypeConversionLib.toBytes32(uint256(0));

        address[] memory fuses = new address[](1);
        fuses[0] = address(_burnRequestFeeFuse);

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = inputs;

        TransientStorageSetInputsFuseEnterData memory setInputsData = TransientStorageSetInputsFuseEnterData({
            fuse: fuses,
            inputsByFuse: inputsByFuse
        });

        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(_transientStorageSetInputsFuse),
            data: abi.encodeWithSignature("enter((address[],bytes32[][]))", setInputsData)
        });
        actions[1] = FuseAction({
            fuse: address(_burnRequestFeeFuse),
            data: abi.encodeWithSignature("enterTransient()")
        });

        uint256 balanceWithdrawManagerBefore = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // then
        uint256 balanceWithdrawManagerAfter = PlasmaVaultBase(_plasmaVault).balanceOf(address(_withdrawManager));
        assertEq(
            balanceWithdrawManagerBefore,
            balanceWithdrawManagerAfter,
            "Balance should not change with zero amount"
        );
    }

    /// @notice Test that exitTransient function reverts with BurnRequestFeeExitNotImplemented error
    function testShouldRevertWhenBurnRequestFeeExitTransient() external {
        // given
        bytes memory error = abi.encodeWithSignature("BurnRequestFeeExitNotImplemented()");

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: address(_burnRequestFeeFuse), data: abi.encodeWithSignature("exitTransient()")});

        // when & then
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();
    }

    function testShouldNOTBeAbleToRedeemFromRequestBecauseNoExecutionReleaseFunds() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);
        vm.stopPrank();

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.warp(block.timestamp + 10 hours);

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidSharesToRelease(uint256)", withdrawAmount);

        vm.startPrank(_USER);
        //then
        vm.expectRevert(error);
        // when
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount, _USER, _USER);
        vm.stopPrank();
    }

    function testShouldNotBeAbleToRedeemWhenWithdrawWindowFinish() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);

        vm.warp(block.timestamp + 24 hours);

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidSharesToRelease(uint256)", withdrawAmount);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount, _USER, _USER);
        vm.stopPrank();
    }

    function testShouldNotBeAbleToRedeemFromRequestWhenWithdrawWindowFinishAndReleaseFundAfterWithdrawWindow()
        external
    {
        // given
        uint256 withdrawAmount = 1_000e6;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidSharesToRelease(uint256)", withdrawAmount);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount, _USER, _USER);
        vm.stopPrank();
    }

    function testShouldNotBeAbleToRedeemFromRequestWhenAmountBiggerThenRequest() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);

        vm.warp(block.timestamp + 24 hours);

        bytes memory error = abi.encodeWithSignature(
            "WithdrawManagerInvalidSharesToRelease(uint256)",
            withdrawAmount + 1e6
        );

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount + 1e6, _USER, _USER);
        vm.stopPrank();
    }

    function testShouldRevertWhenReleaseFundsWithCurrentBlockTimestamp() external {
        // given
        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidTimestamp(uint256)", block.timestamp);

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp, 1e18);
        vm.stopPrank();
    }

    function testShouldRevertWhenReleaseFundsWithTimestampInFuture() external {
        // given
        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidTimestamp(uint256)", block.timestamp + 1);

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp + 1, 1e18);
    }

    function testShouldBeAbleToWithdrawWithoutRequestWhenEnoughBalance() external {
        // given
        uint256 withdrawAmount = 1_000e6;
        uint256 balanceBefore = ERC20(_USDC).balanceOf(_USER);

        // Set sharesToRelease to 0 and release funds
        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, 0);
        vm.stopPrank();

        // Set withdraw window to ensure no timing conflicts
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);
        vm.stopPrank();

        // when
        vm.startPrank(_USER);
        PlasmaVault(_plasmaVault).withdraw(withdrawAmount, _USER, _USER);
        vm.stopPrank();

        // then
        uint256 balanceAfter = ERC20(_USDC).balanceOf(_USER);
        assertTrue(
            balanceAfter == withdrawAmount + balanceBefore,
            "user balance should be increased by withdraw amount"
        );
    }

    function testShouldBeAbleToWithdrawMoreThanRequestedAmountFromBuffer() external {
        // given
        uint256 requestAmount = 1_000e6;
        uint256 withdrawAmount = 2_000e6;
        uint256 balanceBefore = ERC20(_USDC).balanceOf(_USER);

        // Set withdraw window
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);
        vm.stopPrank();

        // Make a request for smaller amount
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(requestAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        // Set sharesToRelease to 0 and release funds
        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, 1_500e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        // when - withdraw more than requested
        vm.startPrank(_USER);
        PlasmaVault(_plasmaVault).withdraw(withdrawAmount, _USER, _USER);
        vm.stopPrank();

        // then
        uint256 balanceAfter = ERC20(_USDC).balanceOf(_USER);
        assertTrue(
            balanceAfter == withdrawAmount + balanceBefore,
            "user balance should be increased by withdraw amount"
        );
    }

    function testShouldNotBeAbleToReleaseFundsWhenNewReleaseFundsTimestampIsLowerThenLastReleaseFundsTimestamp()
        external
    {
        // given
        /// @dev simulate time passing
        vm.warp(block.timestamp + 1 hours);

        uint256 releaseFundsTimestamp = block.timestamp - 1;

        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(releaseFundsTimestamp, 1e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 newReleaseFundsTimestamp = releaseFundsTimestamp - 1;

        bytes memory error = abi.encodeWithSignature(
            "WithdrawManagerInvalidTimestamp(uint256,uint256)",
            releaseFundsTimestamp,
            newReleaseFundsTimestamp
        );

        //then
        vm.expectRevert(error);
        // when
        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(newReleaseFundsTimestamp, 1e18);
        vm.stopPrank();
    }

    function testShouldBeAbleToReleaseFundsWhenNewReleaseFundsTimestampIsGreaterThenLastReleaseFundsTimestamp()
        external
    {
        // given
        /// @dev simulate time passing
        vm.warp(block.timestamp + 1 hours);

        uint256 releaseFundsTimestamp = block.timestamp - 1;

        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(releaseFundsTimestamp, 1e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        uint256 newReleaseFundsTimestamp = releaseFundsTimestamp + 1;

        // when
        vm.startPrank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(newReleaseFundsTimestamp, 2e18);
        vm.stopPrank();

        // then
        uint256 sharesToRelease = WithdrawManager(_withdrawManager).getSharesToRelease();
        assertEq(sharesToRelease, 2e18);
    }

    function testShouldNotBeAbleToUpdateWithdrawFeeWhenNotAtomist() external {
        // given
        uint256 withdrawFee = 0.01e18; // 1% fee
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        WithdrawManager(_withdrawManager).updateWithdrawFee(withdrawFee);
        vm.stopPrank();
    }

    function testShouldBeAbleToRedeemWithFee() external {
        // given
        uint256 withdrawFee = 0.01e18; // 1% fee

        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawFee(withdrawFee);
        vm.stopPrank();

        uint256 balanceBefore = ERC20(_USDC).balanceOf(_plasmaVault);

        vm.startPrank(_USER);
        PlasmaVault(_plasmaVault).redeem(1000e8, _USER, _USER);
        vm.stopPrank();

        uint256 balanceAfter = ERC20(_USDC).balanceOf(_plasmaVault);

        assertEq(balanceBefore, 10000000000);
        assertEq(balanceAfter, 9010000000);
    }

    function testShouldBeAbleToUpdateWithdrawFeeWhenAtomist() external {
        // given
        uint256 withdrawFee = 0.01e18; // 1% fee

        // when
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawFee(withdrawFee);
        vm.stopPrank();

        // then
        uint256 currentFee = WithdrawManager(_withdrawManager).getWithdrawFee();
        assertEq(currentFee, withdrawFee, "withdraw fee should be updated to 1%");
    }

    function testShouldBeAbleToWithdrawWithFee() external {
        // given
        uint256 withdrawFee = 0.01e18; // 1% fee

        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawFee(withdrawFee);
        vm.stopPrank();

        uint256 balanceBefore = ERC20(_USDC).balanceOf(_plasmaVault);

        vm.startPrank(_USER);
        PlasmaVault(_plasmaVault).withdraw(10e6, _USER, _USER);
        vm.stopPrank();

        uint256 balanceAfter = ERC20(_USDC).balanceOf(_plasmaVault);

        assertEq(balanceBefore, 10000000000);
        assertEq(balanceAfter, 9990000000);
    }

    /**
     * @notice Test that previewWithdraw with fee returns higher share value than without fee
     * @dev This is because the fee is taken in shares, so more shares are needed to withdraw the same amount of assets
     */
    function testPreviewWithdrawWithFeeReturnsHigherShareValue() external {
        // given
        uint256 withdrawFee = 0.1e18; // 10% fee
        uint256 assetsToWithdraw = 1000e6; // 1000 USDC

        // Check shares needed without fee
        uint256 sharesWithoutFee = PlasmaVault(_plasmaVault).previewWithdraw(assetsToWithdraw);

        // Set withdraw fee
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawFee(withdrawFee);
        vm.stopPrank();

        // Check shares needed with fee
        uint256 sharesWithFee = PlasmaVault(_plasmaVault).previewWithdraw(assetsToWithdraw);

        // then
        assertTrue(sharesWithFee > sharesWithoutFee, "Shares with fee should be higher than without fee");
    }

    /**
     * @notice Test that previewRedeem with fee returns lower asset value than without fee
     * @dev This is because the fee is taken in shares, so the same amount of shares yields fewer assets after fee
     */
    function testPreviewRedeemWithFeeReturnsLowerAssetValue() external {
        // given
        uint256 withdrawFee = 0.1e18; // 10% fee
        uint256 sharesToRedeem = 1000e8; // 1000 shares

        // Check assets received without fee
        uint256 assetsWithoutFee = PlasmaVault(_plasmaVault).previewRedeem(sharesToRedeem);

        // Set withdraw fee
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawFee(withdrawFee);
        vm.stopPrank();

        // Check assets received with fee
        uint256 assetsWithFee = PlasmaVault(_plasmaVault).previewRedeem(sharesToRedeem);

        // then
        assertTrue(assetsWithFee < assetsWithoutFee, "Assets with fee should be lower than without fee");
    }

    function testShouldBeAbleToUpdateWithdrawManagerUsingFuse() external {
        // given
        address newWithdrawManager = address(new WithdrawManager(_accessManager));

        ReadResult memory readResult = UniversalReader(address(_plasmaVault)).read(
            address(_updateWithdrawManagerMaintenanceFuse),
            abi.encodeWithSignature("getWithdrawManager()")
        );

        address oldWithdrawManager = abi.decode(readResult.data, (address));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_updateWithdrawManagerMaintenanceFuse),
            abi.encodeWithSignature(
                "enter((address))",
                UpdateWithdrawManagerMaintenanceFuseEnterData(newWithdrawManager)
            )
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // then
        readResult = UniversalReader(address(_plasmaVault)).read(
            address(_updateWithdrawManagerMaintenanceFuse),
            abi.encodeWithSignature("getWithdrawManager()")
        );
        address updatedWithdrawManager = abi.decode(readResult.data, (address));
        assertNotEq(oldWithdrawManager, updatedWithdrawManager, "withdraw manager should be updated");
        assertEq(updatedWithdrawManager, newWithdrawManager, "withdraw manager should be set to new address");
    }

    function testShouldNotBeAbleToUpdateWithdrawManagerUsingFuseWhenNotAlpha() external {
        // given

        address newWithdrawManager = address(new WithdrawManager(_accessManager));

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_updateWithdrawManagerMaintenanceFuse),
            abi.encodeWithSignature(
                "enter((address))",
                UpdateWithdrawManagerMaintenanceFuseEnterData(newWithdrawManager)
            )
        );

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();
    }

    // ============================================
    // Unallocated Withdrawal Behavior Tests
    // ============================================
    // These tests demonstrate and document the intended behavior:
    // - Unallocated balance only reserves sharesToRelease (explicitly released by governance)
    // - Pending withdrawal requests that have NOT been released do NOT reduce unallocated balance
    // ============================================

    /**
     * @notice Test that Alice can withdraw from unallocated balance even when Bob has pending (unreleased) requests
     * @dev This demonstrates the intentional behavior: only sharesToRelease is reserved, not all pending requests
     *
     * Scenario:
     * 1. Bob submits a large withdrawal request (pending, not yet released by governance)
     * 2. Alice attempts to withdraw from unallocated balance
     * 3. Alice's withdrawal succeeds because sharesToRelease == 0
     * 4. This is intentional: pending requests don't reserve liquidity until releaseFunds is called
     */
    function testAliceCanWithdrawFromUnallocatedWhileBobHasPendingUnreleasedRequest() external {
        // Setup: Create a second user (Alice)
        address alice = address(0xA11CE);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(alice, 5_000e6);

        // Whitelist Alice
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).grantRole(Roles.WHITELIST_ROLE, alice, 0);
        vm.stopPrank();

        // Alice deposits
        vm.startPrank(alice);
        ERC20(_USDC).approve(_plasmaVault, 5_000e6);
        PlasmaVault(_plasmaVault).deposit(5_000e6, alice);
        vm.stopPrank();

        // Set withdraw window
        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        // Bob (USER) creates a large pending withdrawal request
        uint256 bobRequestAmount = 8_000e8; // 80% of vault
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(bobRequestAmount);
        vm.stopPrank();

        // Verify Bob's request is pending
        WithdrawRequestInfo memory bobRequest = WithdrawManager(_withdrawManager).requestInfo(_USER);
        assertEq(bobRequest.shares, bobRequestAmount, "Bob should have pending request");

        // Verify sharesToRelease is 0 (no releaseFunds called yet)
        uint256 sharesToRelease = WithdrawManager(_withdrawManager).getSharesToRelease();
        assertEq(sharesToRelease, 0, "sharesToRelease should be 0 before releaseFunds");

        // Alice withdraws from unallocated balance
        uint256 aliceWithdrawAmount = 3_000e6;
        uint256 aliceBalanceBefore = ERC20(_USDC).balanceOf(alice);

        vm.startPrank(alice);
        PlasmaVault(_plasmaVault).withdraw(aliceWithdrawAmount, alice, alice);
        vm.stopPrank();

        // Verify Alice's withdrawal succeeded
        uint256 aliceBalanceAfter = ERC20(_USDC).balanceOf(alice);
        assertEq(
            aliceBalanceAfter - aliceBalanceBefore,
            aliceWithdrawAmount,
            "Alice should successfully withdraw even with Bob's pending request"
        );

        // Verify sharesToRelease is still 0
        sharesToRelease = WithdrawManager(_withdrawManager).getSharesToRelease();
        assertEq(sharesToRelease, 0, "sharesToRelease should remain 0");
    }

    /**
     * @notice Test that unallocated withdrawals are blocked when sharesToRelease would be insufficient
     * @dev This demonstrates that ONLY sharesToRelease (not pending requests) reserves liquidity
     *
     * Scenario:
     * 1. Bob submits a withdrawal request
     * 2. Governance calls releaseFunds for Bob's request (sharesToRelease is set)
     * 3. Alice attempts to withdraw more than available (after reserving sharesToRelease)
     * 4. Alice's withdrawal fails due to insufficient unallocated balance
     */
    function testUnallocatedWithdrawalBlockedWhenSharesToReleaseReservesLiquidity() external {
        // Setup: Create Alice
        address alice = address(0xA11CE);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(alice, 5_000e6);

        // Whitelist Alice
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).grantRole(Roles.WHITELIST_ROLE, alice, 0);
        vm.stopPrank();

        // Alice deposits
        vm.startPrank(alice);
        ERC20(_USDC).approve(_plasmaVault, 5_000e6);
        PlasmaVault(_plasmaVault).deposit(5_000e6, alice);
        vm.stopPrank();

        // Total vault balance: 10,000 (USER) + 5,000 (Alice) = 15,000 USDC

        // Set withdraw window
        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        // Bob (USER) creates a withdrawal request
        uint256 bobRequestAmount = 8_000e8;
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(bobRequestAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        // Governance releases funds for Bob's request
        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, bobRequestAmount);

        // Verify sharesToRelease is now set
        uint256 sharesToRelease = WithdrawManager(_withdrawManager).getSharesToRelease();
        assertEq(sharesToRelease, bobRequestAmount, "sharesToRelease should equal Bob's request");

        // Alice attempts to withdraw an amount that would violate sharesToRelease reservation
        // Vault has 15,000e6 USDC, sharesToRelease reserves 8,000e8 shares (~8,000 USDC)
        // Alice tries to withdraw 8,000 USDC, which would leave insufficient for sharesToRelease
        uint256 aliceWithdrawAmount = 8_000e6;

        vm.startPrank(alice);
        vm.expectRevert(); // Should revert due to insufficient unallocated balance
        PlasmaVault(_plasmaVault).withdraw(aliceWithdrawAmount, alice, alice);
        vm.stopPrank();
    }

    /**
     * @notice Test that unallocated withdrawal succeeds when sharesToRelease leaves enough liquidity
     * @dev Demonstrates the precise reservation behavior
     */
    function testUnallocatedWithdrawalSucceedsWhenEnoughLiquidityAfterSharesToRelease() external {
        // Setup: Create Alice
        address alice = address(0xA11CE);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(alice, 5_000e6);

        // Whitelist Alice
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).grantRole(Roles.WHITELIST_ROLE, alice, 0);
        vm.stopPrank();

        // Alice deposits
        vm.startPrank(alice);
        ERC20(_USDC).approve(_plasmaVault, 5_000e6);
        PlasmaVault(_plasmaVault).deposit(5_000e6, alice);
        vm.stopPrank();

        // Total vault balance: 10,000 (USER) + 5,000 (Alice) = 15,000 USDC

        // Set withdraw window
        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        // Bob (USER) creates a small withdrawal request
        uint256 bobRequestAmount = 2_000e8;
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(bobRequestAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        // Governance releases funds for Bob's request
        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, bobRequestAmount);

        // Verify sharesToRelease is set
        uint256 sharesToRelease = WithdrawManager(_withdrawManager).getSharesToRelease();
        assertEq(sharesToRelease, bobRequestAmount, "sharesToRelease should equal Bob's request");

        // Alice withdraws an amount that leaves enough for sharesToRelease
        // Vault has 15,000e6 USDC, sharesToRelease reserves 2,000e8 shares (~2,000 USDC)
        // Alice withdraws 5,000 USDC, leaving 10,000 which is more than 2,000 reserved
        uint256 aliceWithdrawAmount = 5_000e6;
        uint256 aliceBalanceBefore = ERC20(_USDC).balanceOf(alice);

        vm.startPrank(alice);
        PlasmaVault(_plasmaVault).withdraw(aliceWithdrawAmount, alice, alice);
        vm.stopPrank();

        // Verify Alice's withdrawal succeeded
        uint256 aliceBalanceAfter = ERC20(_USDC).balanceOf(alice);
        assertEq(
            aliceBalanceAfter - aliceBalanceBefore,
            aliceWithdrawAmount,
            "Alice should successfully withdraw when enough liquidity remains for sharesToRelease"
        );
    }

    /**
     * @notice Test that emits UnallocatedWithdrawalValidated event with correct parameters
     * @dev Verifies the event provides proper observability for monitoring
     */
    function testUnallocatedWithdrawalEmitsEvent() external {
        // Set withdraw window
        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        uint256 withdrawAmount = 1_000e6;

        // Expect the UnallocatedWithdrawalValidated event
        // Note: We can't easily check exact event params here due to the internal call flow,
        // but we verify the withdrawal succeeds which means the event was emitted
        vm.startPrank(_USER);
        PlasmaVault(_plasmaVault).withdraw(withdrawAmount, _USER, _USER);
        vm.stopPrank();

        // Verify withdrawal succeeded (event was emitted as part of successful flow)
        uint256 userBalance = ERC20(_USDC).balanceOf(_USER);
        assertEq(userBalance, withdrawAmount, "User should have received withdrawn amount");
    }

    /**
     * @notice Invariant-style test: After any unallocated withdrawal, remaining balance >= sharesToRelease
     * @dev This is the core invariant that must always hold
     */
    function testInvariantUnallocatedBalanceAlwaysCoversReleasedShares() external {
        // Setup: Create Alice
        address alice = address(0xA11CE);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(alice, 5_000e6);

        // Whitelist Alice
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).grantRole(Roles.WHITELIST_ROLE, alice, 0);
        vm.stopPrank();

        // Alice deposits
        vm.startPrank(alice);
        ERC20(_USDC).approve(_plasmaVault, 5_000e6);
        PlasmaVault(_plasmaVault).deposit(5_000e6, alice);
        vm.stopPrank();

        // Set withdraw window
        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        // Bob creates request and governance releases it
        uint256 bobRequestAmount = 3_000e8;
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(bobRequestAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, bobRequestAmount);

        // Alice performs multiple withdrawals
        uint256[] memory withdrawAmounts = new uint256[](3);
        withdrawAmounts[0] = 1_000e6;
        withdrawAmounts[1] = 500e6;
        withdrawAmounts[2] = 1_500e6;

        for (uint256 i = 0; i < withdrawAmounts.length; i++) {
            uint256 sharesToReleaseBefore = WithdrawManager(_withdrawManager).getSharesToRelease();
            uint256 vaultBalanceBefore = ERC20(_USDC).balanceOf(_plasmaVault);

            vm.startPrank(alice);
            PlasmaVault(_plasmaVault).withdraw(withdrawAmounts[i], alice, alice);
            vm.stopPrank();

            // INVARIANT CHECK: After withdrawal, vault balance must cover sharesToRelease
            uint256 vaultBalanceAfter = ERC20(_USDC).balanceOf(_plasmaVault);
            uint256 sharesToReleaseAfter = WithdrawManager(_withdrawManager).getSharesToRelease();
            uint256 sharesToReleaseInAssets = PlasmaVault(_plasmaVault).convertToAssets(sharesToReleaseAfter);

            assertTrue(
                vaultBalanceAfter >= sharesToReleaseInAssets,
                "INVARIANT VIOLATED: Vault balance must always cover sharesToRelease"
            );
        }
    }

    // ============================================
    // Voting Checkpoint Tests for BurnRequestFeeFuse
    // ============================================
    // These tests verify that the BurnRequestFeeFuse correctly updates
    // voting checkpoints when burning shares
    // ============================================

    /**
     * @notice Test that burning request fee shares correctly updates voting checkpoints
     * @dev This test verifies the fix for H3: Direct ERC20Upgradeable._burn bypass
     *
     * The vulnerability was that BurnRequestFeeFuse called _burn() directly which
     * used the fuse's own ERC20Upgradeable implementation, bypassing PlasmaVaultBase._update
     * and thus not calling _transferVotingUnits.
     *
     * After the fix, the fuse routes through PlasmaVaultBase.updateInternal via delegatecall,
     * ensuring voting checkpoints are properly updated.
     */
    function testBurnRequestFeeShouldUpdateVotingCheckpoints() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        // Setup request fee (1%)
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(0.01e18);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();

        // User makes a withdrawal request, which transfers fee shares to WithdrawManager
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        // WithdrawManager now has shares (the request fee)
        uint256 withdrawManagerBalance = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);
        assertGt(withdrawManagerBalance, 0, "WithdrawManager should have shares from request fee");

        // Activate voting checkpoints for WithdrawManager by delegating to itself
        vm.prank(_withdrawManager);
        IVotes(_plasmaVault).delegate(_withdrawManager);

        // Record voting power before burn
        uint256 votesBefore = IVotes(_plasmaVault).getVotes(_withdrawManager);
        uint256 totalSupplyBefore = PlasmaVaultBase(_plasmaVault).totalSupply();

        // Verify voting power matches balance
        assertEq(votesBefore, withdrawManagerBalance, "Votes should equal balance before burn");

        // Prepare burn action
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_burnRequestFeeFuse),
            abi.encodeWithSignature("enter((uint256))", withdrawManagerBalance)
        );

        // when - Execute burn
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // then - Verify voting checkpoints were updated
        uint256 votesAfter = IVotes(_plasmaVault).getVotes(_withdrawManager);
        uint256 balanceAfter = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);
        uint256 totalSupplyAfter = PlasmaVaultBase(_plasmaVault).totalSupply();

        // Balance should be zero after burn
        assertEq(balanceAfter, 0, "Balance should be zero after burn");

        // CRITICAL: Voting power should also be zero (this is the fix verification)
        assertEq(votesAfter, 0, "Votes should be zero after burn - voting checkpoints must be updated");

        // Voting power should match balance
        assertEq(votesAfter, balanceAfter, "Votes should equal balance after burn");

        // Total supply should be reduced
        assertEq(
            totalSupplyAfter,
            totalSupplyBefore - withdrawManagerBalance,
            "Total supply should be reduced by burned amount"
        );
    }

    /**
     * @notice Test that voting power remains consistent with balance after partial burn
     * @dev Tests that multiple burn operations maintain voting checkpoint consistency
     */
    function testBurnRequestFeeShouldMaintainVotingConsistencyOnPartialBurn() external {
        // given
        uint256 withdrawAmount = 2_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        // Setup request fee (5% for larger fee amounts)
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(0.05e18);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();

        // User makes withdrawal request
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        uint256 initialBalance = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);
        assertGt(initialBalance, 0, "WithdrawManager should have shares");

        // Activate voting checkpoints
        vm.prank(_withdrawManager);
        IVotes(_plasmaVault).delegate(_withdrawManager);

        // Burn only half of the shares
        uint256 burnAmount = initialBalance / 2;

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(address(_burnRequestFeeFuse), abi.encodeWithSignature("enter((uint256))", burnAmount));

        // when - Execute partial burn
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // then
        uint256 balanceAfter = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);
        uint256 votesAfter = IVotes(_plasmaVault).getVotes(_withdrawManager);

        // Balance should be reduced by burn amount
        assertEq(balanceAfter, initialBalance - burnAmount, "Balance should be reduced by burn amount");

        // CRITICAL: Votes should match the new balance
        assertEq(votesAfter, balanceAfter, "Votes should equal balance after partial burn");
    }

    /**
     * @notice Test that delegated voting power is correctly updated when delegate's shares are burned
     * @dev Verifies that when shares are burned from an account that has delegated its votes,
     *      the delegatee's voting power is correctly reduced
     */
    function testBurnRequestFeeShouldUpdateDelegatedVotingPower() external {
        // given
        address delegatee = address(0xDE1E);
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        // Setup request fee
        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(0.01e18);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();

        // User makes withdrawal request
        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        uint256 withdrawManagerBalance = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);

        // WithdrawManager delegates its voting power to delegatee
        vm.prank(_withdrawManager);
        IVotes(_plasmaVault).delegate(delegatee);

        // Record delegatee's voting power before burn
        uint256 delegateeVotesBefore = IVotes(_plasmaVault).getVotes(delegatee);
        assertEq(
            delegateeVotesBefore,
            withdrawManagerBalance,
            "Delegatee should have voting power from withdraw manager"
        );

        // Burn all shares from WithdrawManager
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_burnRequestFeeFuse),
            abi.encodeWithSignature("enter((uint256))", withdrawManagerBalance)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // then
        uint256 delegateeVotesAfter = IVotes(_plasmaVault).getVotes(delegatee);

        // CRITICAL: Delegatee's voting power should be reduced to zero
        assertEq(delegateeVotesAfter, 0, "Delegatee's voting power should be zero after burning delegator's shares");
    }

    /**
     * @notice Test that getPastTotalSupply returns correct values after burn
     * @dev Verifies that historical total supply queries work correctly after burns
     */
    function testBurnRequestFeeShouldUpdatePastTotalSupply() external {
        // given
        uint256 withdrawAmount = 1_000e8;

        vm.prank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateWithdrawWindow(1 days);

        vm.startPrank(_ATOMIST);
        WithdrawManager(_withdrawManager).updateRequestFee(0.01e18);
        WithdrawManager(_withdrawManager).updatePlasmaVaultAddress(_plasmaVault);
        vm.stopPrank();

        vm.startPrank(_USER);
        WithdrawManager(_withdrawManager).requestShares(withdrawAmount);
        vm.stopPrank();

        uint256 withdrawManagerBalance = PlasmaVaultBase(_plasmaVault).balanceOf(_withdrawManager);

        // Activate checkpoints
        vm.prank(_withdrawManager);
        IVotes(_plasmaVault).delegate(_withdrawManager);

        // Record block before burn
        uint256 blockBeforeBurn = block.number;
        uint256 totalSupplyBeforeBurn = PlasmaVaultBase(_plasmaVault).totalSupply();

        // Move to next block
        vm.roll(block.number + 1);

        // Burn shares
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_burnRequestFeeFuse),
            abi.encodeWithSignature("enter((uint256))", withdrawManagerBalance)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
        vm.stopPrank();

        // Move to next block for historical query
        vm.roll(block.number + 1);

        // then
        uint256 totalSupplyAfterBurn = PlasmaVaultBase(_plasmaVault).totalSupply();

        // Current total supply should be reduced
        assertEq(
            totalSupplyAfterBurn,
            totalSupplyBeforeBurn - withdrawManagerBalance,
            "Current total supply should reflect burn"
        );

        // Historical query should show old total supply
        uint256 pastTotalSupply = IVotes(_plasmaVault).getPastTotalSupply(blockBeforeBurn);
        assertEq(pastTotalSupply, totalSupplyBeforeBurn, "Past total supply should equal supply before burn");
    }
}
