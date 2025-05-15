// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquityTroveFuse, LiquityTroveEnterData, LiquityTroveExitData} from "../../../contracts/fuses/liquity/ethereum/LiquityTroveFuse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LiquityBalanceFuse} from "../../../contracts/fuses/liquity/ethereum/LiquityBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {LiquityIndexesReader} from "../../../contracts/readers/LiquityIndexesReader.sol";

contract LiquityTroveFuseTest is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant BOLD = 0xb01dd87B29d187F3E3a4Bf6cdAebfb97F3D9aB98;

    address internal constant ETH_REGISTRY = 0x38e1F07b954cFaB7239D7acab49997FBaAD96476;
    address internal constant WSTETH_REGISTRY = 0x2D4ef56cb626E9a4C90c156018BA9CE269573c61;
    address internal constant RETH_REGISTRY = 0x3b48169809DD827F22C9e0F2d71ff12Ea7A94a2F;

    address private _plasmaVault;
    address private _accessManager;
    address private _priceOracle;
    address private _liquityBalanceFuse;
    LiquityTroveFuse private _liquityTroveFuse;

    LiquityIndexesReader private _reader;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22375819);
        _reader = new LiquityIndexesReader();
    }

    function testLiquityTroveShouldEnter() public {
        // Chainlink price oracle
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        address[] memory assets = new address[](1);
        address[] memory priceFeeds = new address[](1);
        assets[0] = WETH;
        priceFeeds[0] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        implementation.initialize(address(this));
        // _priceOracle = address(
        //     new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        // );

        implementation.setAssetsPricesSources(assets, priceFeeds);

        _priceOracle = address(implementation);

        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "pvWETH",
                    WETH,
                    _priceOracle,
                    _setupMarketConfigs(),
                    _setupFuses(),
                    _setupBalanceFuses(),
                    _setupFeeConfig(),
                    _createAccessManager(),
                    address(new PlasmaVaultBase()),
                    type(uint256).max,
                    address(0)
                )
            )
        );
        _setupRoles();

        LiquityTroveEnterData memory enterData = LiquityTroveEnterData({
            registry: 0x38e1F07b954cFaB7239D7acab49997FBaAD96476,
            collAmount: 2000 * 1e18,
            boldAmount: 2000 * 1e18,
            upperHint: 0,
            lowerHint: 0,
            annualInterestRate: 1e16,
            maxUpfrontFee: 3e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_liquityTroveFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        deal(WETH, address(this), 200000 * 1e18);
        ERC20(WETH).approve(_plasmaVault, 200000 * 1e18);
        PlasmaVault(_plasmaVault).deposit(200000 * 1e18, address(this));
        PlasmaVault(_plasmaVault).execute(enterCalls);
    }

    function testShouldReturnCorrectIndexesAfterEnter() public {
        testLiquityTroveShouldEnter();

        uint256 lastIndex = _reader.getLastIndex(_plasmaVault);
        assertEq(lastIndex, 1, "lastIndex should be 1 after one trove entry");

        uint256 troveId = _reader.getTroveId(_plasmaVault, address(this), 0);
        assertEq(troveId, 0, "Trove ID for index 0 should be 0 for msg.sender");
    }

    function testLiquityTroveShouldExit() public {
        testLiquityTroveShouldEnter();

        uint256[] memory ownerIndexes = new uint256[](1);
        ownerIndexes[0] = 1;
        LiquityTroveExitData memory exitData = LiquityTroveExitData(
            0x38e1F07b954cFaB7239D7acab49997FBaAD96476,
            ownerIndexes
        );
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(_liquityTroveFuse),
            abi.encodeWithSignature("exit((address,uint256[]))", exitData)
        );

        // deal enough BOLD to pay for the entire debt
        deal(BOLD, _plasmaVault, 3 * 1e22);
        PlasmaVault(_plasmaVault).execute(exitCalls);
    }

    function _setupMarketConfigs() private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory registries = new bytes32[](3);
        registries[0] = PlasmaVaultConfigLib.addressToBytes32(ETH_REGISTRY);
        registries[1] = PlasmaVaultConfigLib.addressToBytes32(WSTETH_REGISTRY);
        registries[2] = PlasmaVaultConfigLib.addressToBytes32(RETH_REGISTRY);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.LIQUITY_V2, registries);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _liquityTroveFuse = new LiquityTroveFuse(IporFusionMarkets.LIQUITY_V2);

        fuses = new address[](1);
        fuses[0] = address(_liquityTroveFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        LiquityBalanceFuse liquityBalanceFuse = new LiquityBalanceFuse(IporFusionMarkets.LIQUITY_V2);
        _liquityBalanceFuse = address(liquityBalanceFuse);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.LIQUITY_V2, address(liquityBalanceFuse));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager_ = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
        _accessManager = accessManager_;
    }

    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, _plasmaVault, IporFusionAccessManager(_accessManager));
    }
}
