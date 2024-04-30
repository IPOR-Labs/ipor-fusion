// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {console2} from "forge-std/Test.sol";

import {TestAccountSetup} from "./TestAccountSetup.sol";
import {TestPriceOracleSetup} from "./TestPriceOracleSetup.sol";
import {TestVaultSetup} from "./TestVaultSetup.sol";
import {PlazmaVault} from "../../../contracts/vaults/PlazmaVault.sol";
import {FoundryRandom} from "foundry-random/FoundryRandom.sol";

abstract contract SupplyTest is TestAccountSetup, TestPriceOracleSetup, TestVaultSetup {
    function init() public {
        initStorage();
        initAccount();
        initPriceOracle();
        initPlasmaVault();
        initApprove();
    }

    function dealAssets(address account, uint256 amount) public virtual override;

    function setupAsset() public virtual override;

    function setupPriceOracle() public virtual override returns (address[] memory assets, address[] memory sources);

    function setupMarketConfigs()
        public
        virtual
        override
        returns (PlazmaVault.MarketSubstratesConfig[] memory marketConfigs);

    function setupFuses() public virtual override returns (address[] memory fuses);

    function setupBalanceFuses()
        public
        virtual
        override
        returns (PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses);

    function testShouldDepositRandomAmount() external {
        // given
        uint256 sum;

        // when
        for (uint256 i; i < 5; i++) {
            uint256 amount = FoundryRandom.randomUint256();
            dealAssets(accounts[i], amount);
        }
    }

    function testShouldWork2() external {
        assertTrue(true, "It should work 1");
    }

    // tools
    function shouldBeZeroShares(address plasmaVault_, address[] accounts_) public {
        for (uint256 i; i < 5; i++) {}
    }
}
