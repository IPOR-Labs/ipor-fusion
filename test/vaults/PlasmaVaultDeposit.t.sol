// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/IAavePoolDataProvider.sol";
import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PlasmaVaultAccessManager} from "../../contracts/managers/PlasmaVaultAccessManager.sol";
import {RoleLib, UsersToRoles, WHITELIST_DEPOSIT_ROLE} from "../RoleLib.sol";

contract PlasmaVaultDepositTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant ETHEREUM_AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    address public atomist = address(this);
    address public alpha = address(0x0001);

    uint256 public amount;
    address public userOne;

    IporPriceOracle public iporPriceOracleProxy;
    UsersToRoles public usersToRoles;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        userOne = address(0x777);

        IporPriceOracle implementation = new IporPriceOracle(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        iporPriceOracleProxy = IporPriceOracle(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldDepositToPlazamVaultWithDAIAsUnderlyingToken() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        userOne = address(0x777);

        amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, 0);
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount);

        assertEq(userVaultBalanceBefore, 0);
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + amount);

        assertEq(amount, ERC20(DAI).balanceOf(address(plasmaVault)));

        assertEq(amount, vaultTotalAssetsAfter);

        assertEq(ERC20(DAI).balanceOf(userOne), 0);

        /// @dev no transfer to the market when depositing
        assertEq(plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID), 0);
    }

    function testShouldDepositToPlazamVaultWithUSDCAsUnderlyingToken() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultUsdc();

        userOne = address(0x777);

        amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, 0, "vaultTotalAssetsBefore");
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount, "vaultTotalAssetsAfter");

        assertEq(userVaultBalanceBefore, 0, "userVaultBalanceBefore");
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + amount, "userVaultBalanceAfter");

        assertEq(amount, ERC20(USDC).balanceOf(address(plasmaVault)), "ERC20(USDC).balanceOf(address(plasmaVault))");

        assertEq(amount, vaultTotalAssetsAfter, "vaultTotalAssetsAfter");

        assertEq(ERC20(USDC).balanceOf(userOne), 0, "ERC20(USDC).balanceOf(userOne)");

        /// @dev no transfer to the market when depositing
        assertEq(plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID), 0);
    }

    function _preparePlasmaVaultUsdc() public returns (PlasmaVault) {
        string memory assetName = "IPOR Fusion USDC";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        address[] memory alphas = new address[](1);

        alphas[0] = address(0x1);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        /// @dev Market Compound V3
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVaultAccessManager accessElectron = createAccessElectron(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessElectron)
            )
        );

        setupRoles(plasmaVault, accessElectron);
        return plasmaVault;
    }

    function _preparePlasmaVaultDai() public returns (PlasmaVault) {
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));
        PlasmaVaultAccessManager accessElectron = createAccessElectron(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessElectron)
            )
        );
        setupRoles(plasmaVault, accessElectron);

        return plasmaVault;
    }

    function testShouldNotDepositToPlazamVaultWithDAIAsUnderlyingTokenWhenNoOnAccessList() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        address userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        bytes4[] memory sig = new bytes4[](1);
        sig[0] = PlasmaVault.deposit.selector;

        vm.prank(atomist);
        PlasmaVaultAccessManager(plasmaVault.getAccessElectronAddress()).setTargetFunctionRole(
            address(plasmaVault),
            sig,
            WHITELIST_DEPOSIT_ROLE
        );

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", userOne);

        //when
        vm.prank(userOne);
        vm.expectRevert(error);
        plasmaVault.deposit(amount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, vaultTotalAssetsAfter);

        assertEq(userVaultBalanceBefore, userVaultBalanceAfter);
    }

    function testShouldDepositToPlazamVaultWithDAIAsUnderlyingTokenWhenAddToOnAccessList() public {
        //given
        address userOne = address(0x777);

        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.deposit(amount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, 0);
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount);

        assertEq(userVaultBalanceBefore, 0);
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + amount);

        assertEq(amount, ERC20(DAI).balanceOf(address(plasmaVault)));

        assertEq(amount, vaultTotalAssetsAfter);

        assertEq(ERC20(DAI).balanceOf(userOne), 0);

        /// @dev no transfer to the market when depositing
        assertEq(plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID), 0);
    }

    function testShouldMintToPlasmaVaultWithDAIAsUnderlyingToken() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        address userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.mint(amount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, 0);
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount);

        assertEq(userVaultBalanceBefore, 0);
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + amount);

        assertEq(amount, ERC20(DAI).balanceOf(address(plasmaVault)));

        assertEq(amount, vaultTotalAssetsAfter);

        assertEq(ERC20(DAI).balanceOf(userOne), 0);

        /// @dev no transfer to the market when depositing
        assertEq(plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID), 0);
    }

    function testShouldNotMintToPlasmaVaultWithDAIAsUnderlyingTokenWhenNoOnAccessList() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        address userOne = address(0x777);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        bytes4[] memory sig = new bytes4[](1);
        sig[0] = PlasmaVault.mint.selector;

        vm.prank(atomist);
        PlasmaVaultAccessManager(plasmaVault.getAccessElectronAddress()).setTargetFunctionRole(
            address(plasmaVault),
            sig,
            WHITELIST_DEPOSIT_ROLE
        );

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", userOne);

        //when
        vm.prank(userOne);
        vm.expectRevert(error);
        plasmaVault.mint(amount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, vaultTotalAssetsAfter);

        assertEq(userVaultBalanceBefore, userVaultBalanceAfter);
    }

    function testShouldMintToPlazamVaultWithDAIAsUnderlyingTokenWhenAddToOnAccessList() public {
        //given
        address userOne = address(0x777);
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        uint256 amount = 100 * 1e18;

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.mint(amount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, 0);
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount);

        assertEq(userVaultBalanceBefore, 0);
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + amount);

        assertEq(amount, ERC20(DAI).balanceOf(address(plasmaVault)));

        assertEq(amount, vaultTotalAssetsAfter);

        assertEq(ERC20(DAI).balanceOf(userOne), 0);

        /// @dev no transfer to the market when depositing
        assertEq(plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID), 0);
    }

    function createAccessElectron(UsersToRoles memory usersToRoles) public returns (PlasmaVaultAccessManager) {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles.alphas = alphas;
        }
        return RoleLib.createAccessElectron(usersToRoles, vm);
    }

    function setupRoles(PlasmaVault plasmaVault, PlasmaVaultAccessManager accessElectron) public {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessElectron);
    }
}
