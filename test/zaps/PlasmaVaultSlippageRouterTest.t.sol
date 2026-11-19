// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryDaoFeePackagesHelper} from "../test_helpers/FusionFactoryDaoFeePackagesHelper.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";

import {PlasmaVaultSlippageRouter} from "../../contracts/zaps/PlasmaVaultSlippageRouter.sol";

/// @title PlasmaVaultSlippageRouterTest
/// @notice Fork test (Base) of the ERC-5143-style slippage router against a real PlasmaVault clone (IL-9681).
///         The base behaviour it guards against (a deposit fee raised right before a deposit silently reduces the
///         shares) is pinned by the direct-deposit assertions.
contract PlasmaVaultSlippageRouterTest is Test {
    address private constant _USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant _USER = TestAddresses.USER;
    address private constant _ATOMIST = TestAddresses.ATOMIST;
    address private constant _FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant _ALPHA = TestAddresses.ALPHA;
    address private constant _fusionFactory = 0x1455717668fA96534f675856347A973fA907e922;

    uint256 private constant _ASSETS = 1_000_000e6;
    /// @dev shares of a 1_000_000e6 deposit into the empty vault at zero fee (see PlasmaVaultDepositFeeTest)
    uint256 private constant _SHARES_NO_FEE = 100000000000000;
    uint256 private constant _SHARES_10_PCT_FEE = 90000000000000;

    PlasmaVault private _plasmaVault;
    PlasmaVaultGovernance private _plasmaVaultGovernance;
    IporFusionAccessManager private _accessManager;
    FeeManager private _feeManager;
    PlasmaVaultSlippageRouter private _router;

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
            _USDC,
            0,
            _ATOMIST,
            0
        );

        _plasmaVault = PlasmaVault(fusionInstance.plasmaVault);
        _accessManager = IporFusionAccessManager(fusionInstance.accessManager);
        _plasmaVaultGovernance = PlasmaVaultGovernance(fusionInstance.plasmaVault);
        _feeManager = FeeManager(fusionInstance.feeManager);

        vm.startPrank(_ATOMIST);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, _ATOMIST, 0);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, _FUSE_MANAGER, 0);
        _accessManager.grantRole(Roles.ALPHA_ROLE, _ALPHA, 0);
        vm.stopPrank();

        // Router is deployed once; the vault stays whitelist-only until a test converts it to public
        _router = new PlasmaVaultSlippageRouter();

        deal(_USDC, _USER, 1_000_000e6);
    }

    function _makePublic() private {
        vm.prank(_ATOMIST);
        _plasmaVaultGovernance.convertToPublicVault();
    }

    function _setDepositFee(uint256 fee_) private {
        vm.prank(_ATOMIST);
        _feeManager.setDepositFee(fee_);
    }

    function _assertRouterClean() private view {
        assertEq(ERC20(_USDC).balanceOf(address(_router)), 0, "router must hold no assets");
        assertEq(_plasmaVault.balanceOf(address(_router)), 0, "router must hold no shares");
        assertEq(ERC20(_USDC).allowance(address(_router), address(_plasmaVault)), 0, "router must leave no allowance");
    }

    function testShouldRevertRouterDepositWhenFeeRaisedAfterUserChoseMinShares() public {
        // given: public vault; the user expects the zero-fee share amount
        _makePublic();
        _setDepositFee(0);
        uint256 minShares = _plasmaVault.previewDeposit(_ASSETS);
        assertEq(minShares, _SHARES_NO_FEE, "quote at zero fee");

        // when: the fee goes up to 10% before the deposit is included
        _setDepositFee(1e17);

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_router), _ASSETS);

        // then: the router reverts and nothing moves
        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultSlippageRouter.SlippageExceeded.selector, _SHARES_10_PCT_FEE, minShares)
        );
        _router.deposit(address(_plasmaVault), _ASSETS, _USER, minShares);
        vm.stopPrank();

        assertEq(ERC20(_USDC).balanceOf(_USER), _ASSETS, "user keeps assets");
        assertEq(_plasmaVault.balanceOf(_USER), 0, "no shares minted");
    }

    function testShouldLoseSharesOnDirectDepositWhenFeeRaised() public {
        // given (base behaviour pinned): without the router the same fee raise is silently accepted
        _makePublic();
        _setDepositFee(1e17);

        // when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_plasmaVault), _ASSETS);
        uint256 shares = _plasmaVault.deposit(_ASSETS, _USER);
        vm.stopPrank();

        // then: 10% fewer shares than the zero-fee quote, no revert
        assertEq(shares, _SHARES_10_PCT_FEE, "direct deposit silently receives fewer shares");
        assertLt(shares, _SHARES_NO_FEE, "loss versus the zero-fee quote");
    }

    function testShouldDepositThroughRouterWhenSharesMeetMinimum() public {
        // given
        _makePublic();
        _setDepositFee(1e17);

        // when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_router), _ASSETS);
        uint256 shares = _router.deposit(address(_plasmaVault), _ASSETS, _USER, _SHARES_10_PCT_FEE);
        vm.stopPrank();

        // then
        assertEq(shares, _SHARES_10_PCT_FEE, "returned shares");
        assertEq(_plasmaVault.balanceOf(_USER), _SHARES_10_PCT_FEE, "receiver shares");
        assertEq(ERC20(_USDC).balanceOf(_USER), 0, "assets pulled from caller");
        _assertRouterClean();
    }

    function testShouldDepositToAnotherReceiverAndStartItsRedemptionLock() public {
        // given: a redemption delay on the vault (the vault holds TECH_PLASMA_VAULT_ROLE on its access manager)
        _makePublic();
        vm.prank(address(_plasmaVault));
        _accessManager.setRedemptionDelay(1 days);
        address receiver = makeAddr("Receiver");

        // when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_router), _ASSETS);
        uint256 shares = _router.deposit(address(_plasmaVault), _ASSETS, receiver, 1);
        vm.stopPrank();

        // then: the router did not bypass the lock - the receiver cannot redeem yet
        assertEq(_plasmaVault.balanceOf(receiver), shares, "receiver got the shares");
        vm.prank(receiver);
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", block.timestamp + 1 days));
        _plasmaVault.redeem(shares, receiver, receiver);
        _assertRouterClean();
    }

    function testShouldMintThroughRouterAndRefundUnspentAssets() public {
        // given
        _makePublic();
        _setDepositFee(1e17);
        uint256 sharesToMint = 10_000e6;
        uint256 expectedAssets = _plasmaVault.previewMint(sharesToMint);
        uint256 maxAssets = expectedAssets + 500e6;

        // when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_router), maxAssets);
        uint256 assets = _router.mint(address(_plasmaVault), sharesToMint, _USER, maxAssets);
        vm.stopPrank();

        // then
        assertEq(assets, expectedAssets, "assets spent");
        assertEq(_plasmaVault.balanceOf(_USER), sharesToMint, "receiver shares");
        assertEq(ERC20(_USDC).balanceOf(_USER), _ASSETS - expectedAssets, "unspent part refunded");
        _assertRouterClean();
    }

    function testShouldRevertRouterMintWhenFeeRaisedAboveMaxAssets() public {
        // given: the user quoted the mint at zero fee
        _makePublic();
        _setDepositFee(0);
        uint256 sharesToMint = 10_000e6;
        uint256 maxAssets = _plasmaVault.previewMint(sharesToMint);

        // when: fee raised to 10%, the same mint costs more assets
        _setDepositFee(1e17);
        uint256 costNow = _plasmaVault.previewMint(sharesToMint);
        assertGt(costNow, maxAssets, "fee raise makes the mint more expensive");

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_router), maxAssets);

        // then: the vault pulls more than the router approved, and Base USDC (Circle FiatToken, not OpenZeppelin)
        // rejects the pull with its own string reason. The router's own SlippageExceeded on mint is pinned by
        // PlasmaVaultSlippageRouterMintSlippageTest.
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        _router.mint(address(_plasmaVault), sharesToMint, _USER, maxAssets);
        vm.stopPrank();

        assertEq(ERC20(_USDC).balanceOf(_USER), _ASSETS, "user keeps assets");
        assertEq(_plasmaVault.balanceOf(_USER), 0, "no shares minted");
        _assertRouterClean();
    }

    function testShouldRejectNonWhitelistedUserOnRestrictedVaultEvenThroughRouter() public {
        // given: whitelist-only vault; the router itself holds WHITELIST_ROLE, the user does not
        vm.prank(_ATOMIST);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, address(_router), 0);

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_router), _ASSETS);

        // when / then: direct call is rejected and so is the router (no whitelist bypass through the router)
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER));
        _plasmaVault.deposit(_ASSETS, _USER);

        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultSlippageRouter.CallerNotAllowed.selector, _USER, address(_plasmaVault))
        );
        _router.deposit(address(_plasmaVault), _ASSETS, _USER, 0);

        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultSlippageRouter.CallerNotAllowed.selector, _USER, address(_plasmaVault))
        );
        _router.mint(address(_plasmaVault), 1e6, _USER, _ASSETS);
        vm.stopPrank();

        assertEq(ERC20(_USDC).balanceOf(_USER), _ASSETS, "user keeps assets");
    }

    function testShouldAllowWhitelistedUserOnRestrictedVaultThroughRouter() public {
        // given: user and router both whitelisted
        vm.startPrank(_ATOMIST);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, address(_router), 0);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _USER, 0);
        vm.stopPrank();

        // when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_router), _ASSETS);
        uint256 shares = _router.deposit(address(_plasmaVault), _ASSETS, _USER, _SHARES_NO_FEE);
        vm.stopPrank();

        // then
        assertEq(_plasmaVault.balanceOf(_USER), shares, "shares minted");
        assertEq(shares, _SHARES_NO_FEE, "no fee");
        _assertRouterClean();
    }

    function testShouldRevertWhenWhitelistedUserUsesRouterNotGrantedAccess() public {
        // given: the user is whitelisted but the atomist never granted the router a role
        vm.prank(_ATOMIST);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _USER, 0);

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(_router), _ASSETS);

        // when / then: the vault rejects the router as msg.sender
        vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(_router)));
        _router.deposit(address(_plasmaVault), _ASSETS, _USER, 0);
        vm.stopPrank();

        assertEq(ERC20(_USDC).balanceOf(_USER), _ASSETS, "user keeps assets");
    }

    function testShouldRevertWhenVaultIsZeroAddress() public {
        vm.expectRevert(PlasmaVaultSlippageRouter.ZeroVault.selector);
        _router.deposit(address(0), 1, _USER, 0);
    }
}
