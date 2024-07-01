// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PriceOracleMiddleware} from "../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {DataForInitialization} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

contract IporPlasmaVaultRolesTest is Test {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    address private _deployer = vm.rememberKey(1);
    address private _priceOracle;
    DataForInitialization private _data;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
        _generateDataForInitialization();
        _setupPriceOracleMiddleware();
    }

    function _generateDataForInitialization() private {
        _data.admins = new address[](0);
        _data.owners = new address[](1);
        _data.owners[0] = vm.rememberKey(2);
        _data.atomists = new address[](1);
        _data.atomists[0] = vm.rememberKey(3);
        _data.alphas = new address[](1);
        _data.alphas[0] = vm.rememberKey(4);
        _data.whitelist = new address[](1);
        _data.whitelist[0] = vm.rememberKey(5);
        _data.guardians = new address[](1);
        _data.guardians[0] = vm.rememberKey(6);
        _data.fuseManagers = new address[](1);
        _data.fuseManagers[0] = vm.rememberKey(7);
        _data.performanceFeeManagers = new address[](1);
        _data.performanceFeeManagers[0] = vm.rememberKey(8);
        _data.managementFeeManagers = new address[](1);
        _data.managementFeeManagers[0] = vm.rememberKey(9);
        _data.claimRewards = new address[](1);
        _data.claimRewards[0] = vm.rememberKey(10);
        _data.transferRewardsManagers = new address[](1);
        _data.transferRewardsManagers[0] = vm.rememberKey(11);
        _data.configInstantWithdrawalFusesManagers = new address[](1);
        _data.configInstantWithdrawalFusesManagers[0] = vm.rememberKey(12);
    }

    function _setupPriceOracleMiddleware() private {
        vm.startPrank(_data_owners[0]);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            0x000
        );

        priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", _data_owners[0]))
        );

        address[] memory assets = new address[](1);
        assets[0] = USDC;
        address[] memory sources = new address[](1);
        sources[0] = CHAINLINK_USDC;

        PriceOracleMiddleware(priceOracle).setAssetSources(assets, sources);
        vm.stopPrank();
    }
}
