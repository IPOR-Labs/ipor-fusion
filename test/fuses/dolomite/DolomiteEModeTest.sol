// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WETHPriceFeed} from "../../../contracts/price_oracle/price_feed/WETHPriceFeed.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {DolomiteEModeFuse, DolomiteEModeFuseEnterData, DolomiteEModeFuseExitData} from "../../../contracts/fuses/dolomite/DolomiteEModeFuse.sol";
import {DolomiteSupplyFuse} from "../../../contracts/fuses/dolomite/DolomiteSupplyFuse.sol";
import {DolomiteBalanceFuse} from "../../../contracts/fuses/dolomite/DolomiteBalanceFuse.sol";
import {DolomiteFuseLib, DolomiteSubstrate} from "../../../contracts/fuses/dolomite/DolomiteFuseLib.sol";
import {IDolomiteAccountRegistry} from "../../../contracts/fuses/dolomite/ext/IDolomiteAccountRegistry.sol";

/// @title MockEModeBalanceFuse
/// @notice Dummy balance fuse for E-mode market that always returns 0
contract MockEModeBalanceFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function balanceOf() external pure returns (uint256) {
        return 0;
    }
}

/// @title MockDolomiteAccountRegistry
/// @notice Mock implementation of DolomiteAccountRegistry for E-mode testing
contract MockDolomiteAccountRegistry is IDolomiteAccountRegistry {
    mapping(uint8 => EModeCategory) private _categories;
    mapping(address => mapping(uint256 => uint8)) private _accountEModes;
    uint8[] private _categoryIds;

    constructor() {
        // Setup stablecoin E-mode category (ID = 1)
        _categories[1] = EModeCategory({
            id: 1,
            ltv: 9700, // 97% LTV
            liquidationThreshold: 9750, // 97.5%
            liquidationBonus: 10100, // 1% bonus
            priceOracle: address(0),
            label: "Stablecoins"
        });
        _categoryIds.push(1);

        // Setup ETH correlated E-mode category (ID = 2)
        _categories[2] = EModeCategory({
            id: 2,
            ltv: 9300, // 93% LTV
            liquidationThreshold: 9500, // 95%
            liquidationBonus: 10200, // 2% bonus
            priceOracle: address(0),
            label: "ETH Correlated"
        });
        _categoryIds.push(2);
    }

    function getAccountEMode(address account_, uint256 accountNumber_) external view override returns (uint8) {
        return _accountEModes[account_][accountNumber_];
    }

    function setAccountEMode(uint256 accountNumber_, uint8 categoryId_) external override {
        _accountEModes[msg.sender][accountNumber_] = categoryId_;
    }

    function getEModeCategory(uint8 categoryId_) external view override returns (EModeCategory memory) {
        EModeCategory memory cat = _categories[categoryId_];
        if (cat.id == 0 && categoryId_ != 0) {
            revert("Invalid category");
        }
        return cat;
    }

    function getEModeCategoryIds() external view override returns (uint8[] memory) {
        return _categoryIds;
    }

    function isMarketInEModeCategory(uint256, uint8) external pure override returns (bool) {
        return true;
    }
}

/// @title DolomiteEModeTest
/// @notice Tests for DolomiteEModeFuse using mocked DolomiteAccountRegistry
contract DolomiteEModeTest is Test {
    // ============ Arbitrum Addresses ============
    address public constant DOLOMITE_MARGIN = 0x6Bd780E7fDf01D77e4d475c821f1e7AE05409072;
    address public constant DEPOSIT_WITHDRAWAL_ROUTER = 0xf8b2c637A68cF6A17b1DF9F8992EeBeFf63d2dFf;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant BASE_CURRENCY_PRICE_SOURCE = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    uint256 public constant DOLOMITE_MARKET_ID = 50;
    uint256 public constant DOLOMITE_EMODE_MARKET_ID = 51; // Separate market for E-mode categories

    // ============ Contract Instances ============
    address public plasmaVault;
    address public priceOracle;
    address public accessManager;

    MockDolomiteAccountRegistry public mockRegistry;
    MockEModeBalanceFuse public emodeBalanceFuse;
    DolomiteEModeFuse public emodeFuse;
    DolomiteSupplyFuse public supplyFuse;
    DolomiteBalanceFuse public balanceFuse;

    // ============ Test Accounts ============
    address public admin;
    address public alpha;

    bytes32[] internal _currentSubstrates;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 420000000);

        admin = vm.addr(1001);
        alpha = vm.addr(1002);

        // Deploy mock registry
        mockRegistry = new MockDolomiteAccountRegistry();

        _deployFuses();
        _setupPriceOracle();
        _setupAccessManager();
        _deployPlasmaVault();
    }

    // ============================================================================
    // CONSTRUCTOR TESTS
    // ============================================================================

    function test_EModeFuse_Constructor_InvalidMarketId() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteEModeFuseInvalidMarketId()"));
        new DolomiteEModeFuse(0, DOLOMITE_MARGIN, address(mockRegistry));
    }

    function test_EModeFuse_Constructor_InvalidDolomiteMargin() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteEModeFuseInvalidDolomiteMargin()"));
        new DolomiteEModeFuse(DOLOMITE_MARKET_ID, address(0), address(mockRegistry));
    }

    function test_EModeFuse_Constructor_InvalidAccountRegistry() public {
        vm.expectRevert(abi.encodeWithSignature("DolomiteEModeFuseInvalidAccountRegistry()"));
        new DolomiteEModeFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN, address(0));
    }

    // ============================================================================
    // ENTER (ENABLE E-MODE) TESTS
    // ============================================================================

    function test_EModeFuse_Enter_EnableStablecoinEMode() public {
        // Grant E-mode category 1 as substrate
        _grantEModeCategory(1);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);

        // Verify E-mode is enabled
        uint8 currentEMode = mockRegistry.getAccountEMode(plasmaVault, 0);
        assertEq(currentEMode, 1, "Should be in stablecoin E-mode");
    }

    function test_EModeFuse_Enter_EnableETHEMode() public {
        // Grant E-mode category 2 as substrate
        _grantEModeCategory(2);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 2})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions);

        uint8 currentEMode = mockRegistry.getAccountEMode(plasmaVault, 0);
        assertEq(currentEMode, 2, "Should be in ETH E-mode");
    }

    function test_EModeFuse_Enter_InvalidCategoryZero() public {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 0})))
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_EModeFuse_Enter_UnsupportedCategory() public {
        // Don't grant category 1 as substrate
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    function test_EModeFuse_Enter_AlreadyInSameMode() public {
        _grantEModeCategory(1);

        // Enable E-mode first
        FuseAction[] memory actions1 = new FuseAction[](1);
        actions1[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions1);

        // Try to enable same E-mode again
        FuseAction[] memory actions2 = new FuseAction[](1);
        actions2[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions2);
    }

    function test_EModeFuse_Enter_SwitchEModeCategory() public {
        _grantEModeCategory(1);
        _grantEModeCategory(2);

        // Enable stablecoin E-mode
        FuseAction[] memory actions1 = new FuseAction[](1);
        actions1[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions1);

        assertEq(mockRegistry.getAccountEMode(plasmaVault, 0), 1);

        // Switch to ETH E-mode
        FuseAction[] memory actions2 = new FuseAction[](1);
        actions2[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 2})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions2);

        assertEq(mockRegistry.getAccountEMode(plasmaVault, 0), 2, "Should be in ETH E-mode now");
    }

    function test_EModeFuse_Enter_DifferentSubAccounts() public {
        _grantEModeCategory(1);
        _grantEModeCategory(2);

        // Enable stablecoin E-mode on sub-account 0
        FuseAction[] memory actions1 = new FuseAction[](1);
        actions1[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions1);

        // Enable ETH E-mode on sub-account 1
        FuseAction[] memory actions2 = new FuseAction[](1);
        actions2[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 1, categoryId: 2})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions2);

        assertEq(mockRegistry.getAccountEMode(plasmaVault, 0), 1, "Sub-account 0 in stablecoin E-mode");
        assertEq(mockRegistry.getAccountEMode(plasmaVault, 1), 2, "Sub-account 1 in ETH E-mode");
    }

    // ============================================================================
    // EXIT (DISABLE E-MODE) TESTS
    // ============================================================================

    function test_EModeFuse_Exit_DisableEMode() public {
        _grantEModeCategory(1);

        // Enable E-mode first
        FuseAction[] memory actions1 = new FuseAction[](1);
        actions1[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.enter, (DolomiteEModeFuseEnterData({subAccountId: 0, categoryId: 1})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions1);

        assertEq(mockRegistry.getAccountEMode(plasmaVault, 0), 1);

        // Disable E-mode
        FuseAction[] memory actions2 = new FuseAction[](1);
        actions2[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.exit, (DolomiteEModeFuseExitData({subAccountId: 0})))
        });

        vm.prank(alpha);
        PlasmaVault(plasmaVault).execute(actions2);

        assertEq(mockRegistry.getAccountEMode(plasmaVault, 0), 0, "E-mode should be disabled");
    }

    function test_EModeFuse_Exit_NotInEMode() public {
        // Try to disable E-mode without enabling it first
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(emodeFuse),
            data: abi.encodeCall(emodeFuse.exit, (DolomiteEModeFuseExitData({subAccountId: 0})))
        });

        vm.prank(alpha);
        vm.expectRevert();
        PlasmaVault(plasmaVault).execute(actions);
    }

    // ============================================================================
    // E-MODE CATEGORY INFO TESTS
    // ============================================================================

    function test_EModeFuse_GetCategoryInfo() public {
        IDolomiteAccountRegistry.EModeCategory memory stablecoinCat = mockRegistry.getEModeCategory(1);
        assertEq(stablecoinCat.id, 1);
        assertEq(stablecoinCat.ltv, 9700);
        assertEq(stablecoinCat.liquidationThreshold, 9750);
        assertEq(keccak256(bytes(stablecoinCat.label)), keccak256(bytes("Stablecoins")));

        IDolomiteAccountRegistry.EModeCategory memory ethCat = mockRegistry.getEModeCategory(2);
        assertEq(ethCat.id, 2);
        assertEq(ethCat.ltv, 9300);
        assertEq(ethCat.liquidationThreshold, 9500);
        assertEq(keccak256(bytes(ethCat.label)), keccak256(bytes("ETH Correlated")));
    }

    function test_EModeFuse_GetCategoryIds() public {
        uint8[] memory categoryIds = mockRegistry.getEModeCategoryIds();
        assertEq(categoryIds.length, 2);
        assertEq(categoryIds[0], 1);
        assertEq(categoryIds[1], 2);
    }

    // ============================================================================
    // DEPLOYMENT HELPERS
    // ============================================================================

    function _deployFuses() internal {
        supplyFuse = new DolomiteSupplyFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN, DEPOSIT_WITHDRAWAL_ROUTER);
        balanceFuse = new DolomiteBalanceFuse(DOLOMITE_MARKET_ID, DOLOMITE_MARGIN);
        // E-mode fuse uses separate market ID to avoid substrate conflicts with BalanceFuse
        emodeFuse = new DolomiteEModeFuse(DOLOMITE_EMODE_MARKET_ID, DOLOMITE_MARGIN, address(mockRegistry));
        // Dummy balance fuse for E-mode market (always returns 0)
        emodeBalanceFuse = new MockEModeBalanceFuse(DOLOMITE_EMODE_MARKET_ID);
    }

    function _setupPriceOracle() internal {
        vm.startPrank(admin);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(BASE_CURRENCY_PRICE_SOURCE);
        priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin))
        );

        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);

        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;

        assets[1] = WETH;
        sources[1] = address(new WETHPriceFeed(CHAINLINK_ETH_USD));

        PriceOracleMiddleware(priceOracle).setAssetsPricesSources(assets, sources);

        vm.stopPrank();
    }

    function _setupAccessManager() internal {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = admin;
        usersToRoles.atomist = admin;

        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;

        accessManager = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
    }

    function _deployPlasmaVault() internal {
        vm.startPrank(admin);

        address withdrawManager = address(new WithdrawManager(accessManager));

        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();

        plasmaVault = address(new PlasmaVault());
        PlasmaVault(plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Dolomite EMode Test Vault",
                assetSymbol: "DEMTVault",
                underlyingToken: USDC,
                priceOracleMiddleware: priceOracle,
                feeConfig: feeConfig,
                accessManager: accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );

        vm.stopPrank();

        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = admin;
        usersToRoles.atomist = admin;
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            plasmaVault,
            IporFusionAccessManager(accessManager),
            withdrawManager
        );

        vm.startPrank(admin);

        address[] memory fusesToAdd = new address[](2);
        fusesToAdd[0] = address(supplyFuse);
        fusesToAdd[1] = address(emodeFuse);
        PlasmaVaultGovernance(plasmaVault).addFuses(fusesToAdd);

        // Add BalanceFuse for the asset market (DOLOMITE_MARKET_ID)
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(DOLOMITE_MARKET_ID, address(balanceFuse));
        // Add dummy BalanceFuse for the E-mode market (DOLOMITE_EMODE_MARKET_ID)
        PlasmaVaultGovernance(plasmaVault).addBalanceFuse(DOLOMITE_EMODE_MARKET_ID, address(emodeBalanceFuse));

        // Initial substrates for asset market: USDC only
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = DolomiteFuseLib.substrateToBytes32(
            DolomiteSubstrate({asset: USDC, subAccountId: 0, canBorrow: false})
        );
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(DOLOMITE_MARKET_ID, substrates);

        _currentSubstrates = substrates;

        vm.stopPrank();
    }

    bytes32[] internal _emodeSubstrates;

    function _grantEModeCategory(uint8 categoryId_) internal {
        bytes32 newSubstrate = bytes32(uint256(categoryId_));

        bool found = false;
        for (uint256 i = 0; i < _emodeSubstrates.length; i++) {
            if (_emodeSubstrates[i] == newSubstrate) {
                found = true;
                break;
            }
        }

        if (!found) {
            bytes32[] memory newArray = new bytes32[](_emodeSubstrates.length + 1);
            for (uint256 i = 0; i < _emodeSubstrates.length; i++) {
                newArray[i] = _emodeSubstrates[i];
            }
            newArray[_emodeSubstrates.length] = newSubstrate;
            _emodeSubstrates = newArray;
        }

        vm.prank(admin);
        PlasmaVaultGovernance(plasmaVault).grantMarketSubstrates(DOLOMITE_EMODE_MARKET_ID, _emodeSubstrates);
    }

    receive() external payable {}
}
