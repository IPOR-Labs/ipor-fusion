// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";

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

        address plasmaVaultBase = address(new PlasmaVaultBase());

        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses = fusionFactory.getFactoryAddresses();
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());
        factoryAddresses.accessManagerFactory = address(new AccessManagerFactory());

        address factoryAdmin = fusionFactory.getRoleMember(fusionFactory.DEFAULT_ADMIN_ROLE(), 0);

        vm.startPrank(factoryAdmin);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), factoryAdmin);
        fusionFactory.updateFactoryAddresses(1000, factoryAddresses);
        fusionFactory.updatePlasmaVaultBase(plasmaVaultBase);

        // Deploy all base addresses for cloning
        address plasmaVaultCoreBase = address(new PlasmaVault());
        address accessManagerBase = address(new IporFusionAccessManager(factoryAdmin, 0));
        address priceOracleMiddleware = fusionFactory.getPriceOracleMiddleware();
        address priceManagerBase = address(new PriceOracleMiddlewareManager(factoryAdmin, priceOracleMiddleware));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));
        address rewardsManagerBase = address(new RewardsClaimManager(accessManagerBase, plasmaVaultCoreBase));
        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = plasmaVaultCoreBase;
        address contextManagerBase = address(new ContextManager(accessManagerBase, approvedTargets));
        fusionFactory.updateBaseAddresses(
            1001,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
        vm.stopPrank();

        // Setup fee packages before creating vault
        FusionFactoryDaoFeePackagesHelper.setupDefaultDaoFeePackages(vm, fusionFactory);

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.clone(
            "AreodromeSlipstream",
            "VSS",
            _UNDERLYING_TOKEN,
            0,
            _ATOMIST,
            0
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

        // IL-8743: the fee is 10% of the GROSS shares (as in deposit): gross = 10_000e6 / 0.9, fee = gross - net,
        // rounded up = 1_111_111_112 (was 10% of the net shares = 1_000_000_000)
        assertEq(withdrawManagerBalanceAfter, 1111111112, "withdrawManagerBalanceAfter should be 1111111112");
        assertEq(withdrawManagerBalanceBefore, 0, "withdrawManagerBalanceBefore should be 0");
        assertEq(userBalanceAfter, 10000000000, "userBalanceAfter should be 10000000000");
        assertEq(userBalanceBefore, 0, "userBalanceBefore should be 0");
        assertEq(totalSupplyAfter, 11111111112, "totalSupplyAfter should be 11111111112");
        assertEq(totalSupplyBefore, 0, "totalSupplyBefore should be 0");
    }

    function test_shouldMintCorrectAmountOfAssetsWhenFeeIsSet() public {
        // given
        uint256 depositFee = 1e17; // 10%
        uint256 sharesToMint = 10_000e6;

        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        uint256 expectedAssets = _plasmaVault.previewMint(sharesToMint);
        uint256 userUsdcBefore = ERC20(_USDC).balanceOf(_USER);
        uint256 feeRecipientSharesBefore = _plasmaVault.balanceOf(address(_withdrawManager));

        // when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_plasmaVault), type(uint256).max);
        uint256 actualAssets = _plasmaVault.mint(sharesToMint, _USER);
        vm.stopPrank();

        // then
        uint256 userUsdcAfter = ERC20(_USDC).balanceOf(_USER);
        uint256 usdcSpent = userUsdcBefore - userUsdcAfter;
        uint256 userShares = _plasmaVault.balanceOf(_USER);
        uint256 feeShares = _plasmaVault.balanceOf(address(_withdrawManager)) - feeRecipientSharesBefore;
        // IL-8743: fee = 10% of the gross shares: gross = ceil(10_000e6 / 0.9), fee = gross - net
        uint256 expectedFeeShares = 1111111112;

        // User pays exactly what previewMint() declared
        assertEq(actualAssets, expectedAssets, "actualAssets should match previewMint");
        assertEq(usdcSpent, expectedAssets, "USDC spent should match previewMint");
        // User gets exactly the shares they requested
        assertEq(userShares, sharesToMint, "user should receive exactly requested shares");
        // Fee recipient gets 10% of the gross shares (net + fee), rounded up in the vault's favour
        assertEq(feeShares, expectedFeeShares, "fee recipient should get the fee on the gross shares");
        assertGe(feeShares * 1e18, (sharesToMint + feeShares) * depositFee, "fee rounds up, never below 10% of gross");
        assertApproxEqAbs(
            feeShares * 1e18,
            (sharesToMint + feeShares) * depositFee,
            1e18,
            "fee is 10% of the gross shares"
        );
        // Total minted = user shares + fee shares
        assertEq(_plasmaVault.totalSupply(), sharesToMint + expectedFeeShares, "totalSupply should be shares + fee");
    }

    function test_shouldMintAndDepositHaveConsistentFeeAccounting() public {
        // given
        uint256 depositFee = 1e17; // 10%
        uint256 depositAmount = 1_000_000e6;

        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        // Deposit path: user pays depositAmount, gets shares minus fee
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_plasmaVault), type(uint256).max);
        _plasmaVault.deposit(depositAmount, _USER);
        vm.stopPrank();

        uint256 userSharesAfterDeposit = _plasmaVault.balanceOf(_USER);
        uint256 feeSharesAfterDeposit = _plasmaVault.balanceOf(address(_withdrawManager));

        // Mint path: user requests exact shares, pays assets covering shares + fee
        address user2 = address(0x1234567890);
        deal(_USDC, user2, 10_000_000e6);

        // mint(userSharesAfterDeposit) should give user2 exactly userSharesAfterDeposit shares
        // and additionally mint fee shares to feeRecipient
        uint256 sharesToMint = userSharesAfterDeposit;
        uint256 feeManagerBalanceBefore = _plasmaVault.balanceOf(address(_withdrawManager));

        uint256 user2UsdcBefore = ERC20(_USDC).balanceOf(user2);

        vm.startPrank(user2);
        ERC20(_USDC).approve(address(_plasmaVault), type(uint256).max);
        uint256 assetsFromMint = _plasmaVault.mint(sharesToMint, user2);
        vm.stopPrank();

        uint256 user2UsdcSpent = user2UsdcBefore - ERC20(_USDC).balanceOf(user2);
        uint256 user2SharesAfterMint = _plasmaVault.balanceOf(user2);
        uint256 feeSharesFromMint = _plasmaVault.balanceOf(address(_withdrawManager)) - feeManagerBalanceBefore;

        // User gets exactly the shares they requested
        assertEq(user2SharesAfterMint, sharesToMint, "user should get exactly requested shares");
        // IL-8743: mint charges the same fee shares as the deposit that yields the same net shares (+-1 wei, rounded
        // up in the vault's favour); it was 10% of the net shares = 1/9 less than the deposit fee
        assertGe(feeSharesFromMint, feeSharesAfterDeposit, "mint fee is not below the deposit fee");
        assertApproxEqAbs(feeSharesFromMint, feeSharesAfterDeposit, 1, "mint fee equals the deposit fee");
        // Assets spent matches previewMint
        assertEq(assetsFromMint, user2UsdcSpent, "actual cost should match returned assets");
        assertEq(assetsFromMint, _plasmaVault.previewMint(sharesToMint), "actual cost should match previewMint");
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

    function test_shouldNotUpdateDepositFeeWhenAboveMaxFee() public {
        //given
        uint256 depositFee = _feeManager.DEPOSIT_MAX_FEE_IN_PERCENTAGE() + 1;

        //when
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidDepositFee.selector, depositFee));
        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //then
        assertEq(_feeManager.getDepositFee(), 0, "getDepositFee should still be 0 after reverted call");
    }

    function test_shouldNotUpdateDepositFeeWhenBelowOneHundredPercentButAboveMaxFee() public {
        //given
        uint256 depositFee = 99e16;

        //when
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidDepositFee.selector, depositFee));
        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //then
        assertEq(_feeManager.getDepositFee(), 0, "getDepositFee should still be 0 after reverted call");
    }

    function test_shouldNotUpdateDepositFeeWhenOneHundredPercent() public {
        //given
        uint256 depositFee = 1e18;

        //when
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidDepositFee.selector, depositFee));
        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //then
        assertEq(_feeManager.getDepositFee(), 0, "getDepositFee should still be 0 after reverted call");
    }

    function test_shouldNotUpdateDepositFeeWhenAboveOneHundredPercent() public {
        //given
        uint256 depositFee = 2e18;

        //when
        vm.expectRevert(abi.encodeWithSelector(FeeManager.InvalidDepositFee.selector, depositFee));
        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //then
        assertEq(_feeManager.getDepositFee(), 0, "getDepositFee should still be 0 after reverted call");
    }

    function test_shouldUpdateDepositFeeAtMaxFee() public {
        //given
        uint256 depositFee = _feeManager.DEPOSIT_MAX_FEE_IN_PERCENTAGE();

        //when
        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //then
        assertEq(_feeManager.getDepositFee(), depositFee, "getDepositFee should equal the cap");
        assertEq(_feeManager.DEPOSIT_MAX_FEE_IN_PERCENTAGE(), 1e17, "DEPOSIT_MAX_FEE_IN_PERCENTAGE should be 1e17");
    }

    function test_shouldKeepAllUserPathsFunctionalAtMaxDepositFee() public {
        //given
        uint256 depositFee = _feeManager.DEPOSIT_MAX_FEE_IN_PERCENTAGE();
        address user2 = address(0x2222222222);
        deal(_USDC, user2, 1_000_000e6);

        vm.startPrank(_ATOMIST);
        _feeManager.setDepositFee(depositFee);
        vm.stopPrank();

        //when
        uint256 previewDepositAssets = _plasmaVault.previewDeposit(1_000_000e6);
        uint256 maxDepositUser = _plasmaVault.maxDeposit(_USER);
        uint256 maxMintUser2 = _plasmaVault.maxMint(user2);
        uint256 previewMintAssets = _plasmaVault.previewMint(10_000e6);

        //then
        assertTrue(previewDepositAssets > 0, "previewDeposit should be > 0 at the cap");
        assertTrue(maxDepositUser > 0, "maxDeposit should be > 0 at the cap");
        assertTrue(maxMintUser2 > 0, "maxMint should be > 0 at the cap");
        assertTrue(previewMintAssets > 0, "previewMint should be > 0 at the cap");

        //when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_plasmaVault), type(uint256).max);
        uint256 sharesFromDeposit = _plasmaVault.deposit(1_000_000e6, _USER);
        vm.stopPrank();

        vm.startPrank(user2);
        ERC20(_USDC).approve(address(_plasmaVault), type(uint256).max);
        uint256 assetsFromMint = _plasmaVault.mint(10_000e6, user2);
        vm.stopPrank();

        //then
        assertEq(sharesFromDeposit, previewDepositAssets, "shares from deposit should equal previewDeposit value");
        assertEq(
            _plasmaVault.balanceOf(_USER),
            previewDepositAssets,
            "user share balance after deposit should equal previewDeposit value"
        );
        assertEq(assetsFromMint, previewMintAssets, "assets paid on mint should equal previewMint value");
    }
}
