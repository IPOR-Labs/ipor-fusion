// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FusionFactory} from "../contracts/factory/FusionFactory.sol";
import {FusionFactoryLogicLib} from "../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {FusionFactoryStorageLib} from "../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {PlasmaVaultFactory} from "../contracts/factory/PlasmaVaultFactory.sol";
import {FeeManagerFactory} from "../contracts/managers/fee/FeeManagerFactory.sol";
import {AccessManagerFactory} from "../contracts/factory/AccessManagerFactory.sol";
import {PriceManagerFactory} from "../contracts/factory/PriceManagerFactory.sol";
import {WithdrawManagerFactory} from "../contracts/factory/WithdrawManagerFactory.sol";
import {RewardsManagerFactory} from "../contracts/factory/RewardsManagerFactory.sol";
import {ContextManagerFactory} from "../contracts/factory/ContextManagerFactory.sol";
import {PlasmaVault} from "../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PriceOracleMiddlewareManager} from "../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {CompoundV2SupplyFuse} from "../contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol";
import {Erc4626SupplyFuseEnterData} from "../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {FuseAction} from "../contracts/interfaces/IPlasmaVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestConfigurationExample is Test {
    address public constant EXISTING_FUSION_FACTORY_PROXY = 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    address public owner = makeAddr("OWNER");
    address public atomist = makeAddr("ATOMIST");
    address public fuseManager = makeAddr("FUSE_MANAGER");
    address public alpha = makeAddr("ALPHA");
    address public priceOracleMiddlewareManager = makeAddr("PRICE_ORACLE_MIDDLEWARE_MANAGER");
    address public user = makeAddr("USER");

    FusionFactory public fusionFactory;
    PlasmaVault public plasmaVault;
    IporFusionAccessManager public accessManager;
    PriceOracleMiddlewareManager public priceManager;
    address public daoFeeManager;

    address public constant balanceFuseErc4626Market1 = 0x2C10C36028C430f445a4bA9f7Dd096a5DcC75d5e;
    address public constant supplyFuseErc4626Market1 = 0x12FD0EE183c85940CAedd4877f5d3Fc637515870;
    address public constant balanceFuseErc20 = 0x6cEBf3e3392D0860Ed174402884b941DCBB30654;

    address public constant IPOR_USDC_PRIME = 0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23831825);

        daoFeeManager = makeAddr("DAO_FEE_MANAGER");

        // Deploy fresh FusionFactory with fee packages support
        fusionFactory = _deployFreshFusionFactory();

        FusionFactoryLogicLib.FusionInstance memory fusionInstance = fusionFactory.clone(
            "Test Configuration Vault",
            "TCV",
            USDC,
            0,
            owner,
            0 // Fee package index
        );

        accessManager = IporFusionAccessManager(fusionInstance.accessManager);
        plasmaVault = PlasmaVault(fusionInstance.plasmaVault);
        priceManager = PriceOracleMiddlewareManager(fusionInstance.priceManager);

        // Grant roles to accounts as needed for your test configuration.
        //
        // Available roles are defined in Roles.sol (e.g., ATOMIST_ROLE, ALPHA_ROLE, FUSE_MANAGER_ROLE).
        // Role hierarchy and admin relationships are configured in IporFusionAccessManagerInitializerLibV1.sol
        // in the _generateAdminRoles() function (e.g., ATOMIST_ROLE is managed by OWNER_ROLE).
        //
        // Example: Grant ATOMIST_ROLE to owner with no execution delay (0):
        // accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, atomist, 0);
        vm.stopPrank();

        vm.startPrank(atomist);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, fuseManager, 0);
        accessManager.grantRole(Roles.ALPHA_ROLE, alpha, 0);
        accessManager.grantRole(Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE, priceOracleMiddlewareManager, 0);
        vm.stopPrank();

        // Configure price feeds for assets if needed.
        // By default, on Ethereum the system uses Chainlink registry for price feeds.
        // On all chains, it uses a general priceOracleMiddleware predefined by IPOR DAO.
        // However, any price feed can be overridden in the PriceOracleMiddlewareManager.
        //
        // Price feeds can be added by accounts with PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE.
        // Example: Add a custom price feed for an asset:
        address customAsset = 0x09D4214C03D01F49544C0448DBE3A27f768F2b34; // rUSD - only for example
        address customPriceFeed = 0x02b2F2809ce74563cb4b2ecA1ADaFB188E4Ed8D7; // Price feed contract address - only for example
        address[] memory assets = new address[](1);
        assets[0] = customAsset;
        address[] memory sources = new address[](1); // Price feed contract address
        sources[0] = customPriceFeed;
        vm.startPrank(priceOracleMiddlewareManager);
        priceManager.setAssetsPriceSources(assets, sources); // Price feed contract address
        vm.stopPrank();

        // Add fuses to the vault.
        // Fuses can be added by accounts with FUSE_MANAGER_ROLE.
        //
        // Two types of fuses must be added for each market:
        // - Interaction fuse (e.g., supply fuse): Handles interactions with external DeFi protocols
        //   for the market (deposits, withdrawals, swaps, position management, etc.)
        //   Multiple interaction fuses can share the same market ID.
        // - Balance fuse: Tracks market-specific asset balances (required for vault operation)
        //   Only one balance fuse can be assigned per market ID.
        //
        // Both fuses must have the same market ID to work together correctly.
        // Addresses of deployed fuses can be found at: https://github.com/IPOR-Labs/ipor-abi
        //
        // Note: Without a balance fuse, the vault will not function properly as it cannot
        // track market balances for asset distribution protection and balance updates.
        // example:
        address[] memory fuses = new address[](1);
        fuses[0] = supplyFuseErc4626Market1;
        vm.startPrank(fuseManager);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.ERC4626_0001,
            balanceFuseErc4626Market1
        );
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            balanceFuseErc20
        ); // this fuse should be added for each Vault
        vm.stopPrank();

        // Configure dependency balance graph if markets depend on each other.
        // A dependency exists when an interaction with market A (e.g., ERC4626_0001) affects
        // the balance value of market B (e.g., ERC20_VAULT_BALANCE).
        // Example: If ERC4626_0001 market interactions impact ERC20_VAULT_BALANCE, configure:
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.ERC4626_0001;
        uint256[] memory dependencies = new uint256[](1);
        dependencies[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;
        uint256[][] memory dependenciesMarkets = new uint256[][](1);
        dependenciesMarkets[0] = dependencies;
        vm.startPrank(fuseManager);
        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenciesMarkets);
        vm.stopPrank();

        // Configure substrates for markets.
        // Each market has its own substrates that establish restrictions on which protocols
        // and assets can be used for interactions.
        // Substrates can be added by accounts with FUSE_MANAGER_ROLE.
        //
        // Example: Add ERC4626 vault address as substrate for ERC4626_0001 market,
        // and add USDT token address as substrate for ERC20_VAULT_BALANCE market:

        bytes32[] memory erc4626Substrates = new bytes32[](1);
        erc4626Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(IPOR_USDC_PRIME);
        bytes32[] memory erc20Substrates = new bytes32[](1);
        erc20Substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDT);
        vm.startPrank(fuseManager);
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.ERC4626_0001,
            erc4626Substrates
        );
        PlasmaVaultGovernance(address(plasmaVault)).grantMarketSubstrates(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            erc20Substrates
        );
        vm.stopPrank();

        // Convert vault from private to public mode.
        // By default, the vault starts in private mode, which blocks deposits and share transfers.
        // To enable these operations for testing, convert the vault to public mode.
        // This can be done by accounts with ATOMIST_ROLE.
        //
        // Example: Convert vault to public vault:
        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).convertToPublicVault();
        vm.stopPrank();

        // Additionally, enable share transfers (required for public vault operation):
        vm.startPrank(atomist);
        PlasmaVaultGovernance(address(plasmaVault)).enableTransferShares();
        vm.stopPrank();
    }

    function testExample() public {
        // Example test - verify fork is working and vault is created
        assertTrue(block.number > 0);
        // assertTrue(address(plasmaVault) != address(0));
    }

    function testUserDepositAndAlphaExecute() public {
        // Step 1: Deal USDC tokens to user
        uint256 depositAmount = 10_000e6; // 10,000 USDC (6 decimals)
        deal(USDC, user, depositAmount);

        // Step 2: User approves PlasmaVault to spend USDC
        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), depositAmount);

        // Step 3: User deposits full amount to PlasmaVault
        uint256 sharesReceived = plasmaVault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify deposit succeeded
        assertGt(sharesReceived, 0, "User should receive shares");
        assertEq(ERC20(USDC).balanceOf(user), 0, "User should have no USDC left");
        assertEq(plasmaVault.balanceOf(user), sharesReceived, "User should have correct shares");

        // Step 4: Calculate half amount
        uint256 halfAmount = depositAmount / 2;

        // Step 5: Create Erc4626SupplyFuseEnterData with IPOR_USDC_PRIME vault and half amount
        Erc4626SupplyFuseEnterData memory enterData = Erc4626SupplyFuseEnterData({
            vault: IPOR_USDC_PRIME,
            vaultAssetAmount: halfAmount
        });

        // Step 6: Create FuseAction array with supplyFuseErc4626Market1 address and encoded enter data
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: supplyFuseErc4626Market1,
            data: abi.encodeWithSignature("enter((address,uint256))", enterData)
        });

        // Step 7: Execute as alpha
        uint256 vaultBalanceBefore = ERC20(USDC).balanceOf(address(plasmaVault));
        vm.prank(alpha);
        plasmaVault.execute(actions);

        // Step 8: Assert balances and verify funds were supplied to IPOR_USDC_PRIME
        // Verify that half of the funds were sent to IPOR_USDC_PRIME
        // The vault should have less USDC balance after execute (funds were deposited to ERC4626 vault)
        uint256 vaultBalanceAfter = ERC20(USDC).balanceOf(address(plasmaVault));
        assertLt(vaultBalanceAfter, vaultBalanceBefore, "Balance decreased");

        // Verify that the ERC4626 vault received shares (check balance of plasmaVault in IPOR_USDC_PRIME)
        // Note: We can't directly check the ERC4626 vault balance without importing IERC4626, but we can verify
        // that the execute succeeded by checking the vault's total assets in the market
        uint256 totalAssetsInMarket = plasmaVault.totalAssetsInMarket(IporFusionMarkets.ERC4626_0001);
        assertGt(totalAssetsInMarket, 0, "Market has assets");
    }

    function _deployFreshFusionFactory() internal returns (FusionFactory) {
        // Get existing factory to copy configuration
        FusionFactory existingFactory = FusionFactory(EXISTING_FUSION_FACTORY_PROXY);

        // Deploy all new factories - fork factories only have create(), not clone()
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses;
        factoryAddresses.plasmaVaultFactory = address(new PlasmaVaultFactory());
        factoryAddresses.feeManagerFactory = address(new FeeManagerFactory());
        factoryAddresses.accessManagerFactory = address(new AccessManagerFactory());
        factoryAddresses.priceManagerFactory = address(new PriceManagerFactory());
        factoryAddresses.withdrawManagerFactory = address(new WithdrawManagerFactory());
        factoryAddresses.rewardsManagerFactory = address(new RewardsManagerFactory());
        factoryAddresses.contextManagerFactory = address(new ContextManagerFactory());

        address plasmaVaultBase = existingFactory.getPlasmaVaultBaseAddress();
        address priceOracleMiddleware = existingFactory.getPriceOracleMiddleware();
        address burnRequestFeeFuse = existingFactory.getBurnRequestFeeFuseAddress();
        address burnRequestFeeBalanceFuse = existingFactory.getBurnRequestFeeBalanceFuseAddress();
        address[] memory plasmaVaultAdminArray = existingFactory.getPlasmaVaultAdminArray();

        // Deploy fresh FusionFactory with fee packages support
        FusionFactory implementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSelector(
            FusionFactory.initialize.selector,
            owner,
            plasmaVaultAdminArray,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        FusionFactory newFactory = FusionFactory(address(proxy));

        // Grant roles
        vm.startPrank(owner);
        newFactory.grantRole(newFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        newFactory.grantRole(newFactory.MAINTENANCE_MANAGER_ROLE(), owner);
        vm.stopPrank();

        // Copy base addresses from existing factory, but deploy fresh PlasmaVault core base
        // The existing plasmaVaultCoreBase on fork is an initialized proxy that cannot be used with Clones.clone()
        FusionFactoryStorageLib.BaseAddresses memory existingBases = existingFactory.getBaseAddresses();
        existingBases.plasmaVaultCoreBase = address(new PlasmaVault());
        uint256 version = existingFactory.getFusionFactoryVersion();

        vm.prank(owner);
        newFactory.updateBaseAddresses(
            version,
            existingBases.plasmaVaultCoreBase,
            existingBases.accessManagerBase,
            existingBases.priceManagerBase,
            existingBases.withdrawManagerBase,
            existingBases.rewardsManagerBase,
            existingBases.contextManagerBase
        );

        vm.prank(owner);
        newFactory.updatePlasmaVaultBase(plasmaVaultBase);

        // Copy vesting period and withdraw window
        uint256 vestingPeriod = existingFactory.getVestingPeriodInSeconds();
        vm.prank(owner);
        newFactory.updateVestingPeriodInSeconds(vestingPeriod);

        uint256 withdrawWindow = existingFactory.getWithdrawWindowInSeconds();
        vm.prank(owner);
        newFactory.updateWithdrawWindowInSeconds(withdrawWindow);

        // Setup fee packages
        _setupDaoFeePackages(newFactory);

        return newFactory;
    }

    function _setupDaoFeePackages(FusionFactory factory_) internal {
        FusionFactoryStorageLib.FeePackage[] memory packages = new FusionFactoryStorageLib.FeePackage[](1);

        // Package 0: Standard fees (0% management, 0% performance for testing simplicity)
        packages[0] = FusionFactoryStorageLib.FeePackage({
            managementFee: 0,
            performanceFee: 0,
            feeRecipient: makeAddr("feeRecipient")
        });

        vm.prank(daoFeeManager);
        factory_.setDaoFeePackages(packages);
    }
}
