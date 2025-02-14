// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {MarketSubstratesConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";

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
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData({
                    assetName: "PLASMA VAULT",
                    assetSymbol: "PLASMA",
                    underlyingToken: _USDC,
                    priceOracleMiddleware: _priceOracle,
                    marketSubstratesConfigs: _setupMarketConfigs(),
                    fuses: _setupFuses(),
                    balanceFuses: _setupBalanceFuses(),
                    feeConfig: _setupFeeConfig(),
                    accessManager: address(_accessManager),
                    plasmaVaultBase: address(new PlasmaVaultBase()),
                    totalSupplyCap: type(uint256).max,
                    withdrawManager: _withdrawManager
                })
            )
        );
        vm.stopPrank();
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

        fuses = new address[](1);
        fuses[0] = address(_burnRequestFeeFuse);
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
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0),
                withdrawManager: _withdrawManager,
                feeManager: address(0),
                contextManager: address(0)
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

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidAmountToRelease(uint256)", withdrawAmount);
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
        WithdrawManager(_withdrawManager).request(withdrawAmount);
        vm.stopPrank();

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidAmountToRelease(uint256)", withdrawAmount);

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
        WithdrawManager(_withdrawManager).request(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, withdrawAmount);

        vm.warp(block.timestamp + 10 hours);

        uint256 balanceBefore = ERC20(_USDC).balanceOf(_USER);

        // when
        vm.startPrank(_USER);
        PlasmaVault(_plasmaVault).redeemFromRequest(withdrawAmount, _USER, _USER);
        vm.stopPrank();

        // then
        uint256 balanceAfter = ERC20(_USDC).balanceOf(_USER);

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
        WithdrawManager(_withdrawManager).request(withdrawAmount);
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
        WithdrawManager(_withdrawManager).request(withdrawAmount);
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
        WithdrawManager(_withdrawManager).request(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.warp(block.timestamp + 10 hours);

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidAmountToRelease(uint256)", withdrawAmount);

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
        WithdrawManager(_withdrawManager).request(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);

        vm.warp(block.timestamp + 24 hours);

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidAmountToRelease(uint256)", withdrawAmount);

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
        WithdrawManager(_withdrawManager).request(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);

        bytes memory error = abi.encodeWithSignature("WithdrawManagerInvalidAmountToRelease(uint256)", withdrawAmount);

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
        WithdrawManager(_withdrawManager).request(withdrawAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        vm.prank(_ALPHA);
        WithdrawManager(_withdrawManager).releaseFunds(block.timestamp - 1, type(uint128).max);

        vm.warp(block.timestamp + 24 hours);

        bytes memory error = abi.encodeWithSignature(
            "WithdrawManagerInvalidAmountToRelease(uint256)",
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

        // Set amountToRelease to 0 and release funds
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
        WithdrawManager(_withdrawManager).request(requestAmount);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);

        // Set amountToRelease to 0 and release funds
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
}
