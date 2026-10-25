// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction, FeeConfig} from "contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "contracts/price_oracle/PriceOracleMiddleware.sol";
import {FeeConfigHelper} from "test/test_helpers/FeeConfigHelper.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "test/test_helpers/IporFusionAccessManagerHelper.sol";

import {
    DolomiteSupplyFuse,
    DolomiteSupplyFuseEnterData,
    DolomiteSupplyFuseExitData
} from "contracts/fuses/dolomite/DolomiteSupplyFuse.sol";
import {DolomiteBalanceFuse} from "contracts/fuses/dolomite/DolomiteBalanceFuse.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "contracts/fuses/dolomite/DolomiteFuseLib.sol";
import {IDolomiteMargin} from "contracts/fuses/dolomite/ext/IDolomiteMargin.sol";
import {IDepositWithdrawalRouter} from "contracts/fuses/dolomite/ext/IDepositWithdrawalRouter.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";

// =====================================================================================================
// Minimal stand-ins for the external Dolomite dependency (no RPC needed).
// They model Dolomite's documented router semantics: isolationModeMarketId == 0 credits msg.sender's own
// account; isolationModeMarketId != 0 credits the account of msg.sender's isolation-mode vault proxy
// (created on demand by the isolation market's factory), and withdrawWei with that id debits the proxy
// account and pays the vault owner. Nothing in the fuse under test is stubbed.
// =====================================================================================================

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

contract MockPriceFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e8, block.timestamp, block.timestamp, 1);
    }
}

contract MockDolomiteMargin {
    mapping(address => bool) internal _registered;
    mapping(address => uint256) internal _marketIdOf;
    mapping(uint256 => address) internal _tokenOf;
    /// owner => account number => market id => positive wei balance
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public balances;
    address public router;

    function setRouter(address router_) external {
        router = router_;
    }

    function addMarket(uint256 marketId_, address token_) external {
        _registered[token_] = true;
        _marketIdOf[token_] = marketId_;
        _tokenOf[marketId_] = token_;
    }

    function getMarketIdByTokenAddress(address token_) external view returns (uint256) {
        require(_registered[token_], "market not found");
        return _marketIdOf[token_];
    }

    function getMarketTokenAddress(uint256 marketId_) external view returns (address) {
        return _tokenOf[marketId_];
    }

    function getAccountWei(
        IDolomiteMargin.AccountInfo calldata account_,
        uint256 marketId_
    ) external view returns (IDolomiteMargin.Wei memory) {
        uint256 v = balances[account_.owner][account_.number][marketId_];
        return IDolomiteMargin.Wei({sign: v > 0, value: v});
    }

    function credit(address owner_, uint256 number_, uint256 marketId_, uint256 amount_) external {
        require(msg.sender == router, "only router");
        balances[owner_][number_][marketId_] += amount_;
    }

    function debitAndPay(address owner_, uint256 number_, uint256 marketId_, uint256 amount_, address to_) external {
        require(msg.sender == router, "only router");
        require(balances[owner_][number_][marketId_] >= amount_, "insufficient");
        balances[owner_][number_][marketId_] -= amount_;
        ERC20(_tokenOf[marketId_]).transfer(to_, amount_);
    }
}

/// @dev Per-owner isolation-mode vault proxy (holds the Dolomite account for that owner)
contract MockIsolationVault {
    address public immutable OWNER;

    constructor(address owner_) {
        OWNER = owner_;
    }
}

/// @dev Isolation-mode market token / factory: maps an account to its isolation vault proxy
contract MockIsolationFactory {
    mapping(address => address) public getVaultByAccount;

    function isIsolationAsset() external pure returns (bool) {
        return true;
    }

    function createVault(address account_) external returns (address vault) {
        require(getVaultByAccount[account_] == address(0), "exists");
        vault = address(new MockIsolationVault(account_));
        getVaultByAccount[account_] = vault;
    }
}

contract MockDepositWithdrawalRouter {
    MockDolomiteMargin public immutable MARGIN;

    constructor(MockDolomiteMargin margin_) {
        MARGIN = margin_;
    }

    function DOLOMITE_MARGIN() external view returns (address) {
        return address(MARGIN);
    }

    function depositWei(
        uint256 isolationModeMarketId_,
        uint256 toAccountNumber_,
        uint256 marketId_,
        uint256 amountWei_,
        IDepositWithdrawalRouter.EventFlag
    ) external {
        address accountOwner = msg.sender;
        if (isolationModeMarketId_ != 0) {
            MockIsolationFactory factory = MockIsolationFactory(MARGIN.getMarketTokenAddress(isolationModeMarketId_));
            require(factory.isIsolationAsset(), "not isolation market");
            accountOwner = factory.getVaultByAccount(msg.sender);
            if (accountOwner == address(0)) {
                accountOwner = factory.createVault(msg.sender);
            }
        }
        ERC20(MARGIN.getMarketTokenAddress(marketId_)).transferFrom(msg.sender, address(MARGIN), amountWei_);
        MARGIN.credit(accountOwner, toAccountNumber_, marketId_, amountWei_);
    }

    function withdrawWei(
        uint256 isolationModeMarketId_,
        uint256 fromAccountNumber_,
        uint256 marketId_,
        uint256 amountWei_,
        IDepositWithdrawalRouter.BalanceCheckFlag
    ) external {
        address accountOwner = msg.sender;
        if (isolationModeMarketId_ != 0) {
            MockIsolationFactory factory = MockIsolationFactory(MARGIN.getMarketTokenAddress(isolationModeMarketId_));
            accountOwner = factory.getVaultByAccount(msg.sender);
            require(accountOwner != address(0), "no vault");
        }
        // isolation-mode withdrawals of other tokens are paid back to the vault owner (msg.sender)
        MARGIN.debitAndPay(accountOwner, fromAccountNumber_, marketId_, amountWei_, msg.sender);
    }
}

/// @title DolomiteIsolationModeEnterTest: DolomiteSupplyFuse rejects a non-zero isolationModeMarketId (IL-8749)
contract DolomiteIsolationModeEnterTest is Test {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address private constant ATOMIST = TestAddresses.ATOMIST;
    address private constant ALPHA = TestAddresses.ALPHA;
    address private constant FUSE_MANAGER = TestAddresses.FUSE_MANAGER;
    address private constant USER = TestAddresses.USER;

    uint256 private constant FUSION_MARKET_ID = 46; // Fusion market id for Dolomite
    uint256 private constant DOLO_USDC_MARKET = 17; // Dolomite market id of USDC
    uint256 private constant DOLO_ISO_MARKET = 50; // a Dolomite isolation-mode market id

    MockUSDC internal usdc;
    MockDolomiteMargin internal margin;
    MockDepositWithdrawalRouter internal router;
    MockIsolationFactory internal isoFactory;

    PlasmaVault internal plasmaVault;
    DolomiteSupplyFuse internal supplyFuse;
    DolomiteBalanceFuse internal balanceFuse;

    function setUp() public {
        usdc = new MockUSDC();

        // ---- Dolomite stand-ins ----
        margin = new MockDolomiteMargin();
        router = new MockDepositWithdrawalRouter(margin);
        margin.setRouter(address(router));
        isoFactory = new MockIsolationFactory();
        margin.addMarket(DOLO_USDC_MARKET, address(usdc));
        margin.addMarket(DOLO_ISO_MARKET, address(isoFactory));

        // ---- Fuses under test (real) ----
        supplyFuse = new DolomiteSupplyFuse(FUSION_MARKET_ID, address(margin), address(router));
        balanceFuse = new DolomiteBalanceFuse(FUSION_MARKET_ID, address(margin));

        // ---- PlasmaVault harness (mirrors test/vaults/PlasmaVaultErc4626ComplianceTest.t.sol) ----
        IporFusionAccessManager accessManager = IporFusionAccessManager(
            deployCode("IporFusionAccessManager.sol:IporFusionAccessManager", abi.encode(ATOMIST, uint256(0)))
        );
        address plasmaVaultBase = deployCode("PlasmaVaultBase.sol:PlasmaVaultBase");
        address withdrawManager = deployCode("WithdrawManager.sol:WithdrawManager", abi.encode(address(accessManager)));

        address priceOracleImpl = deployCode("PriceOracleMiddleware.sol:PriceOracleMiddleware", abi.encode(address(0)));
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(new ERC1967Proxy(priceOracleImpl, abi.encodeWithSignature("initialize(address)", ATOMIST)))
        );
        address feed = address(new MockPriceFeed());
        vm.startPrank(ATOMIST);
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        address[] memory sources = new address[](1);
        sources[0] = feed;
        priceOracle.setAssetsPricesSources(assets, sources);
        vm.stopPrank();

        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();
        plasmaVault = PlasmaVaultCloneLib.clone(deployCode("PlasmaVault.sol:PlasmaVault"));

        vm.startPrank(ATOMIST);
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Dolomite Isolation Vault",
                assetSymbol: "DISO",
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(priceOracle),
                feeConfig: feeConfig,
                accessManager: address(accessManager),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        address rewardsClaimManager = deployCode(
            "RewardsClaimManager.sol:RewardsClaimManager",
            abi.encode(address(accessManager), address(plasmaVault))
        );
        accessManager.setupInitRoles(plasmaVault, withdrawManager, rewardsClaimManager);
        vm.stopPrank();

        // ---- Curator config: Dolomite fuses + a plain supply-only (USDC, subAccount 0) substrate ----
        vm.startPrank(FUSE_MANAGER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(FUSION_MARKET_ID, address(balanceFuse));
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: address(usdc), subAccountId: 0, canBorrow: false})
        );
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(FUSION_MARKET_ID, substrates);
        vm.stopPrank();

        // ---- An honest depositor funds the vault ----
        usdc.mint(USER, 10_000e6);
        vm.startPrank(USER);
        usdc.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(10_000e6, USER);
        vm.stopPrank();
    }

    /// @notice Control: the intended (isolationModeMarketId == 0) path keeps NAV intact.
    function test_control_normalEnterKeepsNav() public {
        uint256 navBefore = plasmaVault.totalAssets();
        _enter(10_000e6, 0);
        assertEq(usdc.balanceOf(address(plasmaVault)), 0, "idle moved to Dolomite");
        assertApproxEqAbs(plasmaVault.totalAssets(), navBefore, 1, "normal Dolomite supply is counted in NAV");
    }

    /// @notice Regression (IL-8749): a non-zero isolationModeMarketId is rejected, so the deposit can no longer be
    /// routed to the isolation-mode proxy account that DolomiteBalanceFuse does not read.
    function test_isolationModeEnter_reverts() public {
        uint256 userShares = plasmaVault.balanceOf(USER);
        uint256 navBefore = plasmaVault.totalAssets();
        uint256 userAssetsBefore = plasmaVault.convertToAssets(userShares);

        vm.expectRevert(
            abi.encodeWithSelector(
                DolomiteSupplyFuse.DolomiteSupplyFuseIsolationModeNotSupported.selector,
                DOLO_ISO_MARKET
            )
        );
        _enter(10_000e6, DOLO_ISO_MARKET);

        assertEq(usdc.balanceOf(address(plasmaVault)), 10_000e6, "vault idle USDC not spent");
        assertEq(isoFactory.getVaultByAccount(address(plasmaVault)), address(0), "no isolation proxy created");
        assertEq(margin.balances(address(plasmaVault), 0, DOLO_USDC_MARKET), 0, "no Dolomite balance created");
        assertEq(plasmaVault.totalAssets(), navBefore, "NAV unchanged");
        assertEq(plasmaVault.convertToAssets(userShares), userAssetsBefore, "depositor value unchanged");
    }

    /// @notice A non-zero id is also rejected on exit, while the normal (0) exit still recovers the position.
    function test_isolationModeExit_reverts_normalExitWorks() public {
        _enter(10_000e6, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                DolomiteSupplyFuse.DolomiteSupplyFuseIsolationModeNotSupported.selector,
                DOLO_ISO_MARKET
            )
        );
        _exit(type(uint256).max, DOLO_ISO_MARKET);
        assertEq(margin.balances(address(plasmaVault), 0, DOLO_USDC_MARKET), 10_000e6, "position untouched");

        _exit(type(uint256).max, 0);
        assertEq(usdc.balanceOf(address(plasmaVault)), 10_000e6, "normal exit recovers funds");
    }

    // ---------------------------------------------------------------------------------------------

    function _enter(uint256 amount_, uint256 isoMarketId_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.enter,
                (
                    DolomiteSupplyFuseEnterData({
                        asset: address(usdc),
                        amount: amount_,
                        minBalanceIncrease: 0,
                        subAccountId: 0,
                        isolationModeMarketId: isoMarketId_
                    })
                )
            )
        });
        vm.prank(ALPHA);
        plasmaVault.execute(actions);
    }

    function _exit(uint256 amount_, uint256 isoMarketId_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse),
            data: abi.encodeCall(
                supplyFuse.exit,
                (
                    DolomiteSupplyFuseExitData({
                        asset: address(usdc),
                        amount: amount_,
                        minAmountOut: 0,
                        subAccountId: 0,
                        isolationModeMarketId: isoMarketId_
                    })
                )
            )
        });
        vm.prank(ALPHA);
        plasmaVault.execute(actions);
    }
}
