// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {ERC4626PriceFeedFactory} from "../../../../contracts/factory/price_feed/ERC4626PriceFeedFactory.sol";

import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {MockPriceOracle} from "test/fuses/aave_v4/MockPriceOracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract ERC4626PriceFeedFactoryTest is OlympixUnitTest("ERC4626PriceFeedFactory") {
    ERC4626PriceFeedFactory public eRC4626PriceFeedFactory;


    function setUp() public override {
        eRC4626PriceFeedFactory = new ERC4626PriceFeedFactory();
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(eRC4626PriceFeedFactory) != address(0), "Contract should be deployed");
    }

    function test_create_RevertsOnZeroAddressesAndSucceedsOnValidInput() public {
            // first hit the InvalidAddress branch (vaultAddress_ == address(0) || priceOracleMiddleware_ == address(0))
            vm.expectRevert(ERC4626PriceFeedFactory.InvalidAddress.selector);
            eRC4626PriceFeedFactory.create(address(0), address(1));
    
            vm.expectRevert(ERC4626PriceFeedFactory.InvalidAddress.selector);
            eRC4626PriceFeedFactory.create(address(1), address(0));
    
            // now provide valid, fully wired vault & oracle so the `if` condition is false and
            // the function continues without reverting on that branch
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            // mint some underlying to the test so vault has something to convert
            underlying.mint(address(this), 1_000e18);
    
            MockERC4626 vault = new MockERC4626(underlying, "Vault", "vTKN");
    
            // make sure convertToAssets(1e18) > 0 by depositing to the vault
            underlying.approve(address(vault), 1_000e18);
            vault.deposit(1_000e18, address(this));
    
            // set up price oracle so asset price and decimals are > 0
            MockPriceOracle oracle = new MockPriceOracle();
            oracle.setAssetPriceWithDecimals(address(underlying), 1e8, 8); // price = 1, decimals = 8
    
            // call create with valid, non‑zero addresses so the InvalidAddress branch is NOT taken
            address priceFeed = eRC4626PriceFeedFactory.create(address(vault), address(oracle));
    
            assertTrue(priceFeed != address(0), "price feed should be created");
        }
}