// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquityBalanceFuse} from "../../../contracts/fuses/chains/ethereum/liquity/LiquityBalanceFuse.sol";
import {LiquityStabilityPoolFuse} from "../../../contracts/fuses/chains/ethereum/liquity/LiquityStabilityPoolFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

contract LiquityBalanceFuseTest is Test {
    struct Asset {
        address token;
        string name;
    }

    address internal constant BOLD = 0xb01dd87B29d187F3E3a4Bf6cdAebfb97F3D9aB98;
    address internal constant ETH_REGISTRY = 0x38e1F07b954cFaB7239D7acab49997FBaAD96476;
    address internal constant WSTETH_REGISTRY = 0x2D4ef56cb626E9a4C90c156018BA9CE269573c61;
    address internal constant RETH_REGISTRY = 0x3b48169809DD827F22C9e0F2d71ff12Ea7A94a2F;
    PlasmaVault private plasmaVault;
    LiquityStabilityPoolFuse private liquityStabilityPoolFuse;
    LiquityBalanceFuse private liquityBalanceFuse;
    address private accessManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22375819);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        implementation.initialize(address(this));
        address priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );
        plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "Test Liquity Balance Fuse Vault",
                "TLBFV",
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

    function testLiquityBalance() external {
        uint256 initialAmount = 1000 * 1e18;
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
        liquityStabilityPoolFuse = new LiquityStabilityPoolFuse(IporFusionMarkets.LIQUITY_V2, ETH_REGISTRY);

        fuses = new address[](1);
        fuses[0] = address(liquityStabilityPoolFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        liquityBalanceFuse = new LiquityBalanceFuse(IporFusionMarkets.LIQUITY_V2, ETH_REGISTRY);

        balanceFuses_ = new MarketBalanceFuseConfig[](1);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.LIQUITY_V2, address(liquityBalanceFuse));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
        return accessManager;
    }

    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), IporFusionAccessManager(accessManager));
    }
}
