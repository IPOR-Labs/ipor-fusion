// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketSubstratesConfig, 
    MarketBalanceFuseConfig, 
    FeeConfig, 
    FuseAction, 
    PlasmaVault, 
    PlasmaVaultInitData
    } from "../../../contracts/vaults/PlasmaVault.sol";
import {LiquityStabilityPoolFuse} from "../../../contracts/fuses/chains/ethereum/liquity/LiquityStabilityPoolFuse.sol";
import {LiquityBalanceFuse} from "../../../contracts/fuses/chains/ethereum/liquity/LiquityBalanceFuse.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquityStabilityPoolFuseTest is Test {
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address internal constant ETH_REGISTRY = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    address internal constant WSTETH_REGISTRY = 0x8d733F7ea7c23Cbea7C613B6eBd845d46d3aAc54;
    address internal constant RETH_REGISTRY = 0x6106046F031a22713697e04C08B330dDaf3e8789;

    PlasmaVault private plasmaVault;
    LiquityStabilityPoolFuse private sbFuse;
    LiquityBalanceFuse private balanceFuse;
    address private accessManager;
    address private priceOracle;
    
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22631293);
        address[] memory assets = new address[](1);
        assets[0] = BOLD;
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        implementation.initialize(address(this));
        address[] memory priceFeeds = new address[](1);
        priceFeeds[0] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        implementation.setAssetsPricesSources(assets, priceFeeds);
        priceOracle = address(implementation);
        
        plasmaVault = 
            new PlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "pvBOLD",
                    BOLD,
                    priceOracle,
                    _setupMarketConfigs(),
                    _setupFuses(),
                    _setupBalanceFuses(),
                    _setupFeeConfig(),
                    _createAccessManager(),
                    address(new PlasmaVaultBase()),
                    type(uint256).max,
                    address(0)
                )
            );
    }

    function testLiquityEnterToSB() public {
        LiquityStabilityPoolFuse.LiquitySPData memory enterData = LiquityStabilityPoolFuse.LiquitySPData({
            amount: 200000 * 1e18,
            doClaim: false
        });
        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(sbFuse),
            abi.encodeWithSignature("enter((uint256,bool))", enterData)
        );
        deal(BOLD, address(this), 200000 * 1e18);
        ERC20(BOLD).approve(address(plasmaVault), 200000 * 1e18);
        plasmaVault.deposit(200000 * 1e18, address(this));
        plasmaVault.execute(enterCalls);
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
        sbFuse = new LiquityStabilityPoolFuse(IporFusionMarkets.LIQUITY_V2, ETH_REGISTRY);
        fuses = new address[](1);
        fuses[0] = address(sbFuse);
    }
    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = new LiquityBalanceFuse(IporFusionMarkets.LIQUITY_V2, ETH_REGISTRY);
        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.LIQUITY_V2, address(balanceFuse));
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
        accessManager = accessManager_;
    }
    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), IporFusionAccessManager(accessManager));
    }
}