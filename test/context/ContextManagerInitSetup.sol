// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVault, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../test_helpers/PlasmaVaultHelper.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PriceOracleMiddlewareHelper} from "../test_helpers/PriceOracleMiddlewareHelper.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {MoonwellHelper} from "../test_helpers/MoonwellHelper.sol";
import {MoonwellSupplyFuseEnterData} from "../../contracts/fuses/moonwell/MoonwellSupplyFuse.sol";
import {MoonwellEnableMarketFuseEnterData, MoonwellEnableMarketFuseExitData} from "../../contracts/fuses/moonwell/MoonwellEnableMarketFuse.sol";
import {MoonwellBorrowFuseEnterData, MoonwellBorrowFuseExitData} from "../../contracts/fuses/moonwell/MoonwellBorrowFuse.sol";
import {MoonWellAddresses} from "../test_helpers/MoonwellHelper.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";

abstract contract ContextManagerInitSetup is Test {
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    address internal constant _UNDERLYING_TOKEN = TestAddresses.BASE_WSTETH;
    string internal constant _UNDERLYING_TOKEN_NAME = "WSTETH";
    address internal constant _USER = TestAddresses.USER;
    uint256 internal constant ERROR_DELTA = 100;

    PlasmaVault internal _plasmaVault;
    PriceOracleMiddleware internal _priceOracleMiddleware;
    IporFusionAccessManager internal _accessManager;
    MoonWellAddresses internal _moonwellAddresses;
    ContextManager internal _contextManager;

    function initSetup() internal {
        // Fork Base network
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 22136992);

        // Deploy price oracle middleware
        vm.startPrank(TestAddresses.ATOMIST);
        _priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            TestAddresses.ATOMIST,
            address(0)
        );
        vm.stopPrank();

        // Deploy minimal plasma vault
        DeployMinimalPlasmaVaultParams memory params = DeployMinimalPlasmaVaultParams({
            underlyingToken: _UNDERLYING_TOKEN,
            underlyingTokenName: _UNDERLYING_TOKEN_NAME,
            priceOracleMiddleware: _priceOracleMiddleware.addressOf(),
            atomist: TestAddresses.ATOMIST
        });

        vm.startPrank(TestAddresses.ATOMIST);
        _plasmaVault = PlasmaVaultHelper.deployMinimalPlasmaVault(params);

        _accessManager = _plasmaVault.accessManagerOf();
        _contextManager = _accessManager.setupInitRoles(_plasmaVault);

        address[] memory mTokens = new address[](3);
        mTokens[0] = TestAddresses.BASE_M_WSTETH;
        mTokens[1] = TestAddresses.BASE_M_CBBTC;
        mTokens[2] = TestAddresses.BASE_M_CBETH;

        vm.stopPrank();
        // Use addFullMarket instead of addSupplyToMarket
        _moonwellAddresses = MoonwellHelper.addFullMarket(
            _plasmaVault,
            mTokens,
            TestAddresses.BASE_MOONWELL_COMPTROLLER,
            vm
        );

        // Deploy and add wstETH price feed
        vm.startPrank(TestAddresses.ATOMIST);
        address wstEthPriceFeed = PriceOracleMiddlewareHelper.deployWstEthPriceFeedOnBase();
        _priceOracleMiddleware.addSource(TestAddresses.BASE_WSTETH, wstEthPriceFeed);
        _priceOracleMiddleware.addSource(TestAddresses.BASE_CBBTC, TestAddresses.BASE_CHAINLINK_CBBTC_PRICE);
        _priceOracleMiddleware.addSource(TestAddresses.BASE_CBETH, TestAddresses.BASE_CHAINLINK_CBETH_PRICE);
        vm.stopPrank();

        deal(_UNDERLYING_TOKEN, _USER, 100e18); // Note: wstETH uses 18 decimals

        vm.startPrank(_USER);
        IERC20(_UNDERLYING_TOKEN).approve(address(_plasmaVault), 100e18);
        _plasmaVault.deposit(100e18, _USER);
        vm.stopPrank();
    }
}