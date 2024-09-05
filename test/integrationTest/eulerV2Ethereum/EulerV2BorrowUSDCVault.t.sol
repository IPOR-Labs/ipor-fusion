// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BorrowTest} from "../supplyFuseTemplate/BorrowTests.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {EulerV2BorrowFuse, EulerV2BorrowFuseEnterData, EulerV2BorrowFuseExitData} from "../../../contracts/fuses/euler_v2/EulerV2BorrowFuse.sol";
import {ERC4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {IEVC} from "../../../node_modules/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

contract EulerV2BorrowUSDCVault is BorrowTest {
    using SafeERC20 for ERC20;

    event EulerV2BorrowEnterFuse(address version, address vault, uint256 amount);
    event EulerV2BorrowExitFuse(address version, address vault, uint256 repaidAmount);

    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant EULER_USDT2_VAULT_BORROW = 0x313603FA690301b0CaeEf8069c065862f9162162;
    address public constant EULER_USDC2_VAULT_COLLATERAL = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address public constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant CHAINLINK_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address public constant EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    uint256 internal depositAmount = 10000e6; // 1000 USDC
    uint256 internal borrowAmount = 80e6; // 500 USDT

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20626532);
        setupBorrowAsset();
        init();
    }

    function getMarketId() public view override returns (uint256) {
        return IporFusionMarkets.EULER_V2;
    }

    function setupAsset() public override {
        asset = USDC;
    }

    function setupBorrowAsset() public override {
        borrowAsset = USDT;
    }

    function dealAssets(address account_, uint256 amount_) public override {
        vm.prank(0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa); // USDC Holder
        ERC20(asset).transfer(account_, amount_);
    }

    function setupPriceOracle() public override returns (address[] memory assets, address[] memory sources) {
        assets = new address[](2);
        sources = new address[](2);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;
        assets[1] = USDT;
        sources[1] = CHAINLINK_USDT_USD;
    }

    function setupMarketConfigs() public override returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(EULER_USDC2_VAULT_COLLATERAL);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(EULER_USDT2_VAULT_BORROW);
        marketConfigs[0] = MarketSubstratesConfig(getMarketId(), substrates);
    }

    function setupFuses() public override {
        Erc4626SupplyFuse fuseSupplyLoc = new Erc4626SupplyFuse(getMarketId());
        EulerV2BorrowFuse fuseBorrowLoc = new EulerV2BorrowFuse(getMarketId(), EVC);
        fuses = new address[](2);
        fuses[0] = address(fuseSupplyLoc);
        fuses[1] = address(fuseBorrowLoc);
    }

    function setupBalanceFuses() public override returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        ERC4626BalanceFuse eulerV2Balances = new ERC4626BalanceFuse(getMarketId());

        balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(getMarketId(), address(eulerV2Balances));
    }

    function getEnterFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (bytes[] memory data) {
        Erc4626SupplyFuseEnterData memory enterSupplyData = Erc4626SupplyFuseEnterData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            vaultAssetAmount: amount_
        });

        EulerV2BorrowFuseEnterData memory enterBorrowData = EulerV2BorrowFuseEnterData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: amount_
        });

        data = new bytes[](2);
        data[0] = abi.encode(enterSupplyData);
        data[1] = abi.encode(enterBorrowData);
    }

    function getExitFuseData(
        uint256 amount_,
        //solhint-disable-next-line
        bytes32[] memory data_
    ) public view virtual override returns (address[] memory fusesSetup, bytes[] memory data) {
        Erc4626SupplyFuseExitData memory exitSupplyData = Erc4626SupplyFuseExitData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            vaultAssetAmount: amount_
        });

        EulerV2BorrowFuseExitData memory exitBorrowData = EulerV2BorrowFuseExitData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: amount_
        });

        data = new bytes[](2);
        data[0] = abi.encode(exitSupplyData);
        data[1] = abi.encode(exitBorrowData);

        fusesSetup = fuses;
    }

    function testShouldEnterBorrow() public {
        // given
        uint256 initialUSDTEulerVaultBalance = ERC20(USDT).balanceOf(EULER_USDT2_VAULT_BORROW);
        uint256 initialUSDCEulerVaultBalance = ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        Erc4626SupplyFuseEnterData memory supplyData = Erc4626SupplyFuseEnterData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            vaultAssetAmount: depositAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", abi.encode(supplyData)));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyActions);

        vm.prank(address(plasmaVault));
        IEVC(EVC).setAccountOperator(address(plasmaVault), alpha, true);

        vm.prank(alpha);
        IEVC(EVC).enableCollateral(address(plasmaVault), EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(alpha);
        IEVC(EVC).enableController(address(plasmaVault), EULER_USDT2_VAULT_BORROW);

        EulerV2BorrowFuseEnterData memory enterBorrowData = EulerV2BorrowFuseEnterData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: borrowAmount
        });

        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(fuses[1], abi.encodeWithSignature("enter(bytes)", abi.encode(enterBorrowData)));

        vm.expectEmit(true, true, true, true);
        emit EulerV2BorrowEnterFuse(address(fuses[1]), EULER_USDT2_VAULT_BORROW, borrowAmount);
        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(borrowActions);

        // then
        assertEq(ERC20(USDT).balanceOf(address(plasmaVault)), borrowAmount);
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), 0);
        assertEq(ERC20(USDT).balanceOf(EULER_USDT2_VAULT_BORROW), initialUSDTEulerVaultBalance - borrowAmount);
        assertEq(ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL), initialUSDCEulerVaultBalance + depositAmount);
    }

    function testShouldExitBorrow() public {
        // given
        uint256 initialUSDTEulerVaultBalance = ERC20(USDT).balanceOf(EULER_USDT2_VAULT_BORROW);
        uint256 initialUSDCEulerVaultBalance = ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        Erc4626SupplyFuseEnterData memory supplyData = Erc4626SupplyFuseEnterData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            vaultAssetAmount: depositAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", abi.encode(supplyData)));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyActions);

        vm.prank(address(plasmaVault));
        IEVC(EVC).setAccountOperator(address(plasmaVault), alpha, true);

        vm.prank(alpha);
        IEVC(EVC).enableCollateral(address(plasmaVault), EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(alpha);
        IEVC(EVC).enableController(address(plasmaVault), EULER_USDT2_VAULT_BORROW);

        EulerV2BorrowFuseEnterData memory enterBorrowData = EulerV2BorrowFuseEnterData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: borrowAmount
        });

        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(fuses[1], abi.encodeWithSignature("enter(bytes)", abi.encode(enterBorrowData)));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(borrowActions);

        EulerV2BorrowFuseExitData memory exitBorrowData = EulerV2BorrowFuseExitData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: borrowAmount
        });

        FuseAction[] memory exitBorrowActions = new FuseAction[](1);
        exitBorrowActions[0] = FuseAction(fuses[1], abi.encodeWithSignature("exit(bytes)", abi.encode(exitBorrowData)));

        vm.expectEmit(true, true, true, true);
        emit EulerV2BorrowExitFuse(address(fuses[1]), EULER_USDT2_VAULT_BORROW, borrowAmount);

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(exitBorrowActions);

        // then
        assertEq(ERC20(USDT).balanceOf(address(plasmaVault)), 0);
        assertEq(ERC20(USDC).balanceOf(address(plasmaVault)), 0);
        assertEq(ERC20(USDT).balanceOf(EULER_USDT2_VAULT_BORROW), initialUSDTEulerVaultBalance);
        assertEq(ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL), initialUSDCEulerVaultBalance + depositAmount);
    }

    function testShouldEnterBorrowWithZeroAmount() public {
        // given
        uint256 initialUSDTEulerVaultBalance = ERC20(USDT).balanceOf(EULER_USDT2_VAULT_BORROW);
        uint256 initialUSDCEulerVaultBalance = ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        Erc4626SupplyFuseEnterData memory supplyData = Erc4626SupplyFuseEnterData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            vaultAssetAmount: depositAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", abi.encode(supplyData)));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyActions);

        vm.prank(address(plasmaVault));
        IEVC(EVC).setAccountOperator(address(plasmaVault), alpha, true);

        vm.prank(alpha);
        IEVC(EVC).enableCollateral(address(plasmaVault), EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(alpha);
        IEVC(EVC).enableController(address(plasmaVault), EULER_USDT2_VAULT_BORROW);

        EulerV2BorrowFuseEnterData memory enterBorrowData = EulerV2BorrowFuseEnterData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: 0
        });

        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(fuses[1], abi.encodeWithSignature("enter(bytes)", abi.encode(enterBorrowData)));

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(borrowActions);

        // then
        // No state change expected, but the transaction should succeed
        assertEq(ERC20(USDT).balanceOf(address(plasmaVault)), 0);
        assertEq(ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL), initialUSDCEulerVaultBalance + depositAmount);
        assertEq(ERC20(USDT).balanceOf(EULER_USDT2_VAULT_BORROW), initialUSDTEulerVaultBalance);
    }

    function testShouldExitBorrowWithZeroAmount() public {
        // given
        uint256 initialUSDTEulerVaultBalance = ERC20(USDT).balanceOf(EULER_USDT2_VAULT_BORROW);
        uint256 initialUSDCEulerVaultBalance = ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(depositAmount, accounts[1]);

        Erc4626SupplyFuseEnterData memory supplyData = Erc4626SupplyFuseEnterData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            vaultAssetAmount: depositAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", abi.encode(supplyData)));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyActions);

        vm.prank(address(plasmaVault));
        IEVC(EVC).setAccountOperator(address(plasmaVault), alpha, true);

        vm.prank(alpha);
        IEVC(EVC).enableCollateral(address(plasmaVault), EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(alpha);
        IEVC(EVC).enableController(address(plasmaVault), EULER_USDT2_VAULT_BORROW);

        EulerV2BorrowFuseEnterData memory enterBorrowData = EulerV2BorrowFuseEnterData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: borrowAmount
        });

        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(fuses[1], abi.encodeWithSignature("enter(bytes)", abi.encode(enterBorrowData)));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(borrowActions);

        EulerV2BorrowFuseExitData memory exitBorrowData = EulerV2BorrowFuseExitData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: 0
        });

        FuseAction[] memory exitBorrowActions = new FuseAction[](1);
        exitBorrowActions[0] = FuseAction(fuses[1], abi.encodeWithSignature("exit(bytes)", abi.encode(exitBorrowData)));

        // when
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(exitBorrowActions);

        // then
        // No state change expected, but the transaction should succeed
        assertEq(ERC20(USDT).balanceOf(address(plasmaVault)), borrowAmount);
        assertEq(ERC20(USDC).balanceOf(EULER_USDC2_VAULT_COLLATERAL), initialUSDCEulerVaultBalance + depositAmount);
        assertEq(ERC20(USDT).balanceOf(EULER_USDT2_VAULT_BORROW), initialUSDTEulerVaultBalance - borrowAmount);
    }

    function testShouldFailEnterBorrowWithInsufficientCollateral() public {
        // given
        uint256 insufficientDepositAmount = 90e6;
        vm.prank(accounts[1]);
        PlasmaVault(plasmaVault).deposit(insufficientDepositAmount, accounts[1]);

        Erc4626SupplyFuseEnterData memory supplyData = Erc4626SupplyFuseEnterData({
            vault: EULER_USDC2_VAULT_COLLATERAL,
            vaultAssetAmount: insufficientDepositAmount
        });

        FuseAction[] memory supplyActions = new FuseAction[](1);
        supplyActions[0] = FuseAction(fuses[0], abi.encodeWithSignature("enter(bytes)", abi.encode(supplyData)));

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(supplyActions);

        vm.prank(address(plasmaVault));
        IEVC(EVC).setAccountOperator(address(plasmaVault), alpha, true);

        vm.prank(alpha);
        IEVC(EVC).enableCollateral(address(plasmaVault), EULER_USDC2_VAULT_COLLATERAL);

        vm.prank(alpha);
        IEVC(EVC).enableController(address(plasmaVault), EULER_USDT2_VAULT_BORROW);

        EulerV2BorrowFuseEnterData memory enterBorrowData = EulerV2BorrowFuseEnterData({
            vault: EULER_USDT2_VAULT_BORROW,
            amount: borrowAmount
        });

        FuseAction[] memory borrowActions = new FuseAction[](1);
        borrowActions[0] = FuseAction(fuses[1], abi.encodeWithSignature("enter(bytes)", abi.encode(enterBorrowData)));

        // when / then
        vm.expectRevert();
        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(borrowActions);
    }
}
