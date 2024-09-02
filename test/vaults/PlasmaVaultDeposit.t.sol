// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";

contract PlasmaVaultDepositTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    address public atomist = address(this);
    address public alpha = address(0x0001);

    uint256 public amount;
    uint256 public sharesAmount;
    address public userOne;

    PriceOracleMiddleware public priceOracleMiddlewareProxy;
    UsersToRoles public usersToRoles;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        userOne = address(0x777);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldDepositToPlasmaVaultWithDAIAsUnderlyingToken() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        userOne = address(0x777);

        amount = 100 * 1e18;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

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

        assertEq(vaultTotalAssetsBefore, 0, "vaultTotalAssetsBefore");
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount, "vaultTotalAssetsAfter");

        assertEq(userVaultBalanceBefore, 0, "userVaultBalanceBefore");
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + sharesAmount, "userVaultBalanceAfter");

        assertEq(amount, ERC20(DAI).balanceOf(address(plasmaVault)));

        assertEq(amount, vaultTotalAssetsAfter, "vaultTotalAssetsAfter and amount");

        assertEq(ERC20(DAI).balanceOf(userOne), 0, "ERC20(DAI).balanceOf(userOne)");

        /// @dev no transfer to the market when depositing
        assertEq(
            plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID),
            0,
            "plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID)"
        );
    }

    function testShouldDepositToPlasmaVaultWithUSDCAsUnderlyingToken() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultUsdc(type(uint256).max);

        userOne = address(0x777);

        amount = 100 * 1e6;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

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
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + sharesAmount, "userVaultBalanceAfter");

        assertEq(amount, ERC20(USDC).balanceOf(address(plasmaVault)), "ERC20(USDC).balanceOf(address(plasmaVault))");

        assertEq(amount, vaultTotalAssetsAfter, "vaultTotalAssetsAfter");

        assertEq(ERC20(USDC).balanceOf(userOne), 0, "ERC20(USDC).balanceOf(userOne)");

        /// @dev no transfer to the market when depositing
        assertEq(plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID), 0);
    }

    function testShouldNotDepositBecauseOfTotalSupplyCap() public {
        //given
        uint256 decimals = 6 + PlasmaVaultLib.DECIMALS_OFFSET;
        PlasmaVault plasmaVault = _preparePlasmaVaultUsdc(99 * 10 ** decimals);

        userOne = address(0x777);

        amount = 100 * 1e6;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);

        vm.prank(userOne);
        ERC20(USDC).approve(address(plasmaVault), amount);

        bytes memory error = abi.encodeWithSignature(
            "ERC20ExceededCap(uint256,uint256)",
            sharesAmount,
            99 * 10 ** plasmaVault.decimals()
        );

        //when
        vm.prank(userOne);
        vm.expectRevert(error);
        plasmaVault.deposit(amount, userOne);
    }

    function _preparePlasmaVaultUsdc(uint256 totalSupplyCap) public returns (PlasmaVault) {
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
            AAVE_PRICE_ORACLE_MAINNET,
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

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion USDC",
                "ipfUSDC",
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                totalSupplyCap
            )
        );

        setupRoles(plasmaVault, accessManager);
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
            AAVE_PRICE_ORACLE_MAINNET,
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );
        setupRoles(plasmaVault, accessManager);

        return plasmaVault;
    }

    function testShouldNotDepositToPlasmaVaultWithDAIAsUnderlyingTokenWhenNoOnAccessList() public {
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
        IporFusionAccessManager(IPlasmaVaultGovernance(address(plasmaVault)).getAccessManagerAddress())
            .setTargetFunctionRole(address(plasmaVault), sig, Roles.WHITELIST_ROLE);

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

    function testShouldDepositToPlasmaVaultWithDAIAsUnderlyingTokenWhenAddToOnAccessList() public {
        //given
        address userOne = address(0x777);

        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        amount = 100 * 1e18;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

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

        assertEq(vaultTotalAssetsBefore, 0, "vaultTotalAssetsBefore");
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount, "vaultTotalAssetsAfter");

        assertEq(userVaultBalanceBefore, 0, "userVaultBalanceBefore");
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + sharesAmount, "userVaultBalanceAfter");

        assertEq(amount, ERC20(DAI).balanceOf(address(plasmaVault)));

        assertEq(amount, vaultTotalAssetsAfter, "vaultTotalAssetsAfter amount");

        assertEq(ERC20(DAI).balanceOf(userOne), 0, "ERC20(DAI).balanceOf(userOne)");

        /// @dev no transfer to the market when depositing
        assertEq(
            plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID),
            0,
            "plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID)"
        );
    }

    function testShouldMintToPlasmaVaultWithDAIAsUnderlyingToken() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        address userOne = address(0x777);

        amount = 100 * 1e18;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.mint(sharesAmount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, 0, "vaultTotalAssetsBefore");
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount, "vaultTotalAssetsAfter");

        assertEq(userVaultBalanceBefore, 0);
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + sharesAmount, "userVaultBalanceAfter");

        assertEq(amount, ERC20(DAI).balanceOf(address(plasmaVault)), "ERC20(DAI).balanceOf(address(plasmaVault)");

        assertEq(amount, vaultTotalAssetsAfter, "vaultTotalAssetsAfter and amount");

        assertEq(ERC20(DAI).balanceOf(userOne), 0, "ERC20(DAI).balanceOf(userOne)");

        /// @dev no transfer to the market when depositing
        assertEq(
            plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID),
            0,
            "plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID)"
        );
    }

    function testShouldNotMintToPlasmaVaultWithDAIAsUnderlyingTokenWhenNoOnAccessList() public {
        //given
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        address userOne = address(0x777);

        amount = 100 * 1e18;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        bytes4[] memory sig = new bytes4[](1);
        sig[0] = PlasmaVault.mint.selector;

        vm.prank(atomist);
        IporFusionAccessManager(IPlasmaVaultGovernance(address(plasmaVault)).getAccessManagerAddress())
            .setTargetFunctionRole(address(plasmaVault), sig, Roles.WHITELIST_ROLE);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", userOne);

        //when
        vm.prank(userOne);
        vm.expectRevert(error);
        plasmaVault.mint(sharesAmount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, vaultTotalAssetsAfter);

        assertEq(userVaultBalanceBefore, userVaultBalanceAfter);
    }

    function testShouldMintToPlasmaVaultWithDAIAsUnderlyingTokenWhenAddToOnAccessList() public {
        //given
        address userOne = address(0x777);
        PlasmaVault plasmaVault = _preparePlasmaVaultDai();

        amount = 100 * 1e18;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        deal(DAI, address(userOne), amount);

        vm.prank(userOne);
        ERC20(DAI).approve(address(plasmaVault), 3 * amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.mint(sharesAmount, userOne);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, 0, "vaultTotalAssetsBefore");
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount, "vaultTotalAssetsAfter");

        assertEq(userVaultBalanceBefore, 0);
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + sharesAmount, "userVaultBalanceAfter");

        assertEq(amount, ERC20(DAI).balanceOf(address(plasmaVault)), "ERC20(DAI).balanceOf(address(plasmaVault)");

        assertEq(amount, vaultTotalAssetsAfter, "vaultTotalAssetsAfter and amount");

        assertEq(ERC20(DAI).balanceOf(userOne), 0, "ERC20(DAI).balanceOf(userOne)");

        /// @dev no transfer to the market when depositing
        assertEq(
            plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID),
            0,
            "plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID)"
        );
    }

    function testShouldDepositWithPermitToPlasmaVault() public {
        //given
        uint256 privateKey = 0xBEEF;
        address userOne = vm.addr(privateKey);

        PlasmaVault plasmaVault = _preparePlasmaVaultUsdc(type(uint256).max);

        amount = 100 * 1e6;
        sharesAmount = 100 * 10 ** plasmaVault.decimals();

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    IERC20Permit(USDC).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, userOne, address(plasmaVault), amount, 0, block.timestamp))
                )
            )
        );

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);

        uint256 vaultTotalAssetsBefore = plasmaVault.totalAssets();
        uint256 userVaultBalanceBefore = plasmaVault.balanceOf(userOne);

        //when
        vm.prank(userOne);
        plasmaVault.depositWithPermit(amount, userOne, userOne, block.timestamp, v, r, s);

        //then
        uint256 vaultTotalAssetsAfter = plasmaVault.totalAssets();
        uint256 userVaultBalanceAfter = plasmaVault.balanceOf(userOne);

        assertEq(vaultTotalAssetsBefore, 0);
        assertEq(vaultTotalAssetsAfter, vaultTotalAssetsBefore + amount);

        assertEq(userVaultBalanceBefore, 0);
        assertEq(userVaultBalanceAfter, userVaultBalanceBefore + sharesAmount);

        assertEq(amount, ERC20(USDC).balanceOf(address(plasmaVault)));

        assertEq(amount, vaultTotalAssetsAfter);

        assertEq(ERC20(USDC).balanceOf(userOne), 0);

        /// @dev no transfer to the market when depositing
        assertEq(plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID), 0);
    }

    function testShouldRevertDepositWithPermitToPlasmaVaultWhenInvalidSignature() public {
        //given
        uint256 privateKey = 0xBEEF;
        address userOne = vm.addr(privateKey);

        uint256 amount = 100 * 1e6;

        PlasmaVault plasmaVault = _preparePlasmaVaultUsdc(type(uint256).max);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            privateKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    IERC20Permit(USDC).DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, userOne, address(plasmaVault), amount, 0, block.timestamp))
                )
            )
        );

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(userOne), amount);

        //when
        vm.prank(userOne);
        vm.expectRevert(bytes("EIP2612: invalid signature"));
        plasmaVault.depositWithPermit(amount + 1, userOne, userOne, block.timestamp, v, r, s);
    }

    function createAccessManager(UsersToRoles memory usersToRoles) public returns (IporFusionAccessManager) {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles, vm);
    }

    function setupRoles(PlasmaVault plasmaVault, IporFusionAccessManager accessManager) public {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }
}
