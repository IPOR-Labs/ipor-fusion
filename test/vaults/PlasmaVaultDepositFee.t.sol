// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";

contract PlasmaVaultDepositFeeTest is Test {
    // Test constants
    address private constant _WETH = 0x4200000000000000000000000000000000000006;
    address private constant _USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant _UNDERLYING_TOKEN = _USDC;
    string private constant _UNDERLYING_TOKEN_NAME = "USDC";
    address private constant _USER = TestAddresses.USER;
    address private constant _ATOMIST = TestAddresses.ATOMIST;
    address private constant _FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant _ALPHA = TestAddresses.ALPHA;

    address private constant _fusionFactory = 0x1455717668fA96534f675856347A973fA907e922;

    // Core contracts
    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    PriceOracleMiddlewareManager private _priceOracleMiddleware;
    IporFusionAccessManager private _accessManager;
    RewardsClaimManager private _rewardsClaimManager;
    FeeManager private _feeManager;
    WithdrawManager private _withdrawManager;

    function setUp() public {
        // Fork Base network
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 35566963);

        FusionFactory fusionFactory = FusionFactory(_fusionFactory);

        FusionFactory newImplementation = new FusionFactory();

        address admin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(admin);
        fusionFactory.upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = fusionFactory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());
        factoryAddresses.accessManagerFactory = address(new AccessManagerFactory());

        address factoryAdmin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(factoryAdmin);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), factoryAdmin);
        fusionFactory.updateFactoryAddresses(1000, factoryAddresses);
        vm.stopPrank();

        FusionFactoryLib.FusionInstance memory fusionInstance = fusionFactory.create(
            "AreodromeSlipstream",
            "VSS",
            _UNDERLYING_TOKEN,
            0,
            _ATOMIST
        );

        _plasmaVault = PlasmaVault(fusionInstance.plasmaVault);
        _priceOracleMiddleware = PriceOracleMiddlewareManager(fusionInstance.priceManager);
        _accessManager = IporFusionAccessManager(fusionInstance.accessManager);
        _plasmaVaultGovernance = PlasmaVaultGovernance(fusionInstance.plasmaVault);
        _rewardsClaimManager = RewardsClaimManager(fusionInstance.rewardsManager);
        _feeManager = FeeManager(fusionInstance.feeManager);
        _withdrawManager = WithdrawManager(fusionInstance.withdrawManager);

        vm.startPrank(_ATOMIST);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, _ATOMIST, 0);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, _FUSE_MANAGER, 0);
        _accessManager.grantRole(Roles.ALPHA_ROLE, _ALPHA, 0);
        _accessManager.grantRole(Roles.CLAIM_REWARDS_ROLE, _ALPHA, 0);
        _accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, _ATOMIST, 0);
        _plasmaVaultGovernance.convertToPublicVault();
        _plasmaVaultGovernance.enableTransferShares();
        vm.stopPrank();

        // Provide initial liquidity to user
        deal(_USDC, _USER, 1_000_000e6);
        deal(_WETH, _USER, 1_000_000e18);
    }

    function test_shouldUpdateDepositFee() public {
        //given
        uint256 depositFee = 1e17;

        uint256 depositFeeBefore = _feeManager.getDepositFee();
        //when
        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //then
        uint256 depositFeeAfter = _feeManager.getDepositFee();
        assertEq(depositFeeAfter, depositFee, "depositFeeAfter should be equal to depositFee");
        assertEq(depositFeeBefore, 0, "depositFeeBefore should be 0");
    }

    function test_shouldNotUpdateDepositFee() public {
        //given
        uint256 depositFee = 1e17;

        uint256 depositFeeBefore = _feeManager.getDepositFee();
        //when
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER));
        vm.startPrank(_USER);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();
    }

    function test_shouldCalculateFeeWhenDeposit() public {
        //given
        uint256 depositFee = 1e17;

        uint256 withdrawManagerBalanceBefore = _plasmaVault.balanceOf(address(_withdrawManager));
        uint256 userBalanceBefore = _plasmaVault.balanceOf(_USER);

        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_plasmaVault), 1_000_000e6);
        _plasmaVault.deposit(1_000_000e6, _USER);
        vm.stopPrank();

        //then
        uint256 withdrawManagerBalanceAfter = _plasmaVault.balanceOf(address(_withdrawManager));
        uint256 userBalanceAfter = _plasmaVault.balanceOf(_USER);

        assertEq(withdrawManagerBalanceAfter, 10000000000000, "withdrawManagerBalanceAfter should be 10000000000000");
        assertEq(withdrawManagerBalanceBefore, 0, "withdrawManagerBalanceBefore should be 0");
        assertEq(userBalanceAfter, 90000000000000, "userBalanceAfter should be 90000000000000");
        assertEq(userBalanceBefore, 0, "userBalanceBefore should be 0");
    }

    function test_shouldDepositWhenFeeDepositInNotSet() public {
        //given
        uint256 withdrawManagerBalanceBefore = _plasmaVault.balanceOf(address(_withdrawManager));
        uint256 userBalanceBefore = _plasmaVault.balanceOf(_USER);

        //when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_plasmaVault), 1_000_000e6);
        _plasmaVault.deposit(1_000_000e6, _USER);
        vm.stopPrank();

        //then
        uint256 withdrawManagerBalanceAfter = _plasmaVault.balanceOf(address(_withdrawManager));
        uint256 userBalanceAfter = _plasmaVault.balanceOf(_USER);

        assertEq(withdrawManagerBalanceAfter, 0, "withdrawManagerBalanceAfter should be 0");
        assertEq(withdrawManagerBalanceBefore, 0, "withdrawManagerBalanceBefore should be 0");
        assertEq(userBalanceAfter, 100000000000000, "userBalanceAfter should be 100000000000000");
        assertEq(userBalanceBefore, 0, "userBalanceBefore should be 0");
    }

    function test_shouldMintWhenFeeDepositIsSet() public {
        //given
        uint256 depositFee = 1e17;

        uint256 withdrawManagerBalanceBefore = _plasmaVault.balanceOf(address(_withdrawManager));
        uint256 userBalanceBefore = _plasmaVault.balanceOf(_USER);
        uint256 totalSupplyBefore = _plasmaVault.totalSupply();

        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_plasmaVault), 1_000_000e6);
        _plasmaVault.mint(10_000e6, _USER);
        vm.stopPrank();

        //then
        uint256 withdrawManagerBalanceAfter = _plasmaVault.balanceOf(address(_withdrawManager));
        uint256 userBalanceAfter = _plasmaVault.balanceOf(_USER);
        uint256 totalSupplyAfter = _plasmaVault.totalSupply();

        assertEq(withdrawManagerBalanceAfter, 1000000000, "withdrawManagerBalanceAfter should be 1000000000");
        assertEq(withdrawManagerBalanceBefore, 0, "withdrawManagerBalanceBefore should be 0");
        assertEq(userBalanceAfter, 10000000000, "userBalanceAfter should be 10000000000");
        assertEq(userBalanceBefore, 0, "userBalanceBefore should be 0");
        assertEq(totalSupplyAfter, 11000000000, "totalSupplyAfter should be 11000000000");
        assertEq(totalSupplyBefore, 0, "totalSupplyBefore should be 0");
    }

    function test_shouldMintWhenFeeDepositIsNotSet() public {
        //given
        uint256 withdrawManagerBalanceBefore = _plasmaVault.balanceOf(address(_withdrawManager));
        uint256 userBalanceBefore = _plasmaVault.balanceOf(_USER);
        uint256 totalSupplyBefore = _plasmaVault.totalSupply();

        //when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_plasmaVault), 1_000_000e6);
        _plasmaVault.mint(10_000e6, _USER);
        vm.stopPrank();

        //then
        uint256 withdrawManagerBalanceAfter = _plasmaVault.balanceOf(address(_withdrawManager));
        uint256 userBalanceAfter = _plasmaVault.balanceOf(_USER);
        uint256 totalSupplyAfter = _plasmaVault.totalSupply();

        assertEq(withdrawManagerBalanceAfter, 0, "withdrawManagerBalanceAfter should be 0");
        assertEq(withdrawManagerBalanceBefore, 0, "withdrawManagerBalanceBefore should be 0");
        assertEq(userBalanceAfter, 10000000000, "userBalanceAfter should be 10000000000");
        assertEq(userBalanceBefore, 0, "userBalanceBefore should be 0");
        assertEq(totalSupplyAfter, 10000000000, "totalSupplyAfter should be 10000000000");
        assertEq(totalSupplyBefore, 0, "totalSupplyBefore should be 0");
    }
}
