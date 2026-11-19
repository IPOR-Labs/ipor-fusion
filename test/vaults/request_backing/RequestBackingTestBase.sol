// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {FeeManager} from "../../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";

import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MutableValuePriceFeed} from "../../managers/MutableValuePriceFeed.sol";
import {ExternalValueBalanceFuse, MarketValueSource} from "../../crosschain/mocks/ExternalValueBalanceFuse.sol";

/// @dev A contract account that holds vault shares and exits with owner = address(this), like the cross-chain
///      dispatchers and PlasmaVaultRedeemFromRequestFuse. `strike` is mint + redeemFromRequest in one transaction
///      (the assets it holds stand in for a flash loan).
contract RequestBackingActor {
    function request(WithdrawManager wm_, uint256 shares_) external {
        wm_.requestShares(shares_);
    }

    function deposit(PlasmaVault vault_, IERC20 asset_, uint256 assets_) external returns (uint256) {
        asset_.approve(address(vault_), assets_);
        return vault_.deposit(assets_, address(this));
    }

    function redeemFromRequest(PlasmaVault vault_, uint256 shares_) external returns (uint256) {
        return vault_.redeemFromRequest(shares_, address(this), address(this));
    }

    function transfer(PlasmaVault vault_, address to_, uint256 shares_) external {
        vault_.transfer(to_, shares_);
    }

    function strike(PlasmaVault vault_, IERC20 asset_, uint256 shares_) external returns (uint256 paid, uint256 got) {
        paid = vault_.previewMint(shares_);
        asset_.approve(address(vault_), paid);
        vault_.mint(shares_, address(this));
        got = vault_.redeemFromRequest(shares_, address(this), address(this));
    }
}

/// @dev IL-9531 harness: a real PlasmaVault clone, IporFusionAccessManager with a one-day redemption delay,
///      WithdrawManager (window 3 days, instant withdraw fee 1 %) and one market whose value the test sets. No fork.
abstract contract RequestBackingTestBase is Test {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 internal constant DELAY = 1 days;
    uint256 internal constant WINDOW = 3 days;
    uint256 internal constant MARKET = 4242;
    uint256 internal constant WITHDRAW_FEE = 1e16;

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal constant ALPHA = TestAddresses.ALPHA;
    address internal constant OWNER = TestAddresses.OWNER;
    address internal constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address internal constant HONEST = address(0xA11CE);
    address internal constant GRIEFER = address(0xD057);
    address internal constant BYSTANDER = address(0xB0B);
    address internal constant SINK = address(0x5111C);

    MockERC20 internal usdc;
    PlasmaVault internal vault;
    IporFusionAccessManager internal accessManager;
    WithdrawManager internal wm;
    MarketValueSource internal marketValue;
    RequestBackingActor internal actor;

    function setUp() public virtual {
        vm.warp(1_750_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        _deployVault();

        marketValue = new MarketValueSource();
        ExternalValueBalanceFuse balanceFuse = new ExternalValueBalanceFuse(MARKET, marketValue);
        vm.prank(FUSE_MANAGER);
        PlasmaVaultGovernance(address(vault)).addBalanceFuse(MARKET, address(balanceFuse));

        vm.startPrank(ATOMIST);
        wm.updatePlasmaVaultAddress(address(vault));
        wm.updateWithdrawWindow(WINDOW);
        wm.updateWithdrawFee(WITHDRAW_FEE);
        PlasmaVaultGovernance(address(vault)).enableTransferShares();
        vm.stopPrank();

        actor = new RequestBackingActor();
        vm.label(address(actor), "actor");
        vm.label(HONEST, "honest");
        vm.label(address(vault), "PlasmaVault");
        vm.label(address(wm), "WithdrawManager");
    }

    /// @dev Deposits `assets_`, waits out the lock and requests all shares
    function _depositAndRequest(address who_, uint256 assets_) internal returns (uint256 shares) {
        shares = _deposit(who_, assets_);
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(who_);
        wm.requestShares(shares);
    }

    /// @dev The honest holder alone: deposit 100 000 USDC, wait out the lock, request q, ALPHA releases q
    function _honestScenario() internal returns (uint256 q) {
        q = _depositAndRequest(HONEST, 100_000e6);
        vm.warp(block.timestamp + 1 hours);
        _release(q);
    }

    function _dustDeposit(address receiver_) internal {
        usdc.mint(GRIEFER, 1);
        vm.startPrank(GRIEFER);
        usdc.approve(address(vault), 1);
        vault.deposit(1, receiver_);
        vm.stopPrank();
    }

    function _mintTo(address who_, uint256 amount_) internal returns (uint256) {
        usdc.mint(who_, amount_);
        return amount_;
    }

    function _deposit(address who_, uint256 assets_) internal returns (uint256 shares) {
        usdc.mint(who_, assets_);
        vm.startPrank(who_);
        usdc.approve(address(vault), assets_);
        shares = vault.deposit(assets_, who_);
        vm.stopPrank();
    }

    function _release(uint256 shares_) internal returns (uint256 t) {
        t = block.timestamp - 1;
        vm.prank(ALPHA);
        wm.releaseFunds(t, shares_);
    }

    function _requestShares(address who_) internal view returns (uint256) {
        return wm.requestInfo(who_).shares;
    }

    function _deployVault() private {
        accessManager = new IporFusionAccessManager(ATOMIST, DELAY);
        wm = new WithdrawManager(address(accessManager));

        PriceOracleMiddleware oracleImpl = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(oracleImpl), abi.encodeWithSignature("initialize(address)", ATOMIST)))
        );
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        address[] memory sources = new address[](1);
        sources[0] = address(new MutableValuePriceFeed(1e18));
        vm.prank(ATOMIST);
        oracle.setAssetsPricesSources(assets, sources);

        address plasmaVaultBase = vm.deployCode("PlasmaVaultBase.sol:PlasmaVaultBase");
        address feeFactory = vm.deployCode("FeeManagerFactory.sol:FeeManagerFactory");
        vault = PlasmaVaultCloneLib.clone(vm.deployCode("PlasmaVault.sol:PlasmaVault"));

        vm.startPrank(ATOMIST);
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Request Backing Vault",
                assetSymbol: "vRB",
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(oracle),
                feeConfig: FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: feeFactory,
                    iporDaoFeeRecipientAddress: TestAddresses.IPOR_DAO_FEE_RECIPIENT_ADDRESS
                }),
                accessManager: address(accessManager),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: address(wm),
                plasmaVaultVotesPlugin: address(0)
            })
        );
        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(vault));
        IporFusionAccessManagerHelper.RoleAddresses memory roles = IporFusionAccessManagerHelper
            .createDefaultRoleAddresses();
        roles.withdrawManagerRequestFeeManagers = new address[](1);
        roles.withdrawManagerRequestFeeManagers[0] = ATOMIST;
        roles.withdrawManagerWithdrawFeeManagers = new address[](1);
        roles.withdrawManagerWithdrawFeeManagers[0] = ATOMIST;
        accessManager.setupInitRoles(vault, roles, address(wm), address(rewardsClaimManager));
        vm.stopPrank();

        address feeAccount = PlasmaVaultGovernance(address(vault)).getPerformanceFeeData().feeAccount;
        FeeManager(FeeAccount(feeAccount).FEE_MANAGER()).initialize();
    }
}
