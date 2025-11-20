// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager, WithdrawRequestInfo} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {MarketSubstratesConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {UpdateWithdrawManagerMaintenanceFuse, UpdateWithdrawManagerMaintenanceFuseEnterData} from "../../contracts/fuses/maintenance/UpdateWithdrawManagerMaintenanceFuse.sol";
import {UniversalReader, ReadResult} from "../../contracts/universal_reader/UniversalReader.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";

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
                withdrawManager: _withdrawManager
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

        fuses = new address[](2);
        fuses[0] = address(_burnRequestFeeFuse);
        fuses[1] = address(_updateWithdrawManagerMaintenanceFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ZeroBalanceFuse zeroBalanceFuse = new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);
        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.ZERO_BALANCE_MARKET,
            fuse: address(zeroBalanceFuse)
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
        assertEq(balanceAfter, 9990100000);
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
}
