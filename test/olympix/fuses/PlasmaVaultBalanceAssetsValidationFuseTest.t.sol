// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/PlasmaVaultBalanceAssetsValidationFuse.sol

import {PlasmaVaultBalanceAssetsValidationFuse, PlasmaVaultBalanceAssetsValidationFuseEnterData} from "contracts/fuses/PlasmaVaultBalanceAssetsValidationFuse.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
contract PlasmaVaultBalanceAssetsValidationFuseTest is OlympixUnitTest("PlasmaVaultBalanceAssetsValidationFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_RevertWhenBalanceOutsideRange() public {
            // set up market and fuse
            uint256 marketId = 1;
            PlasmaVaultBalanceAssetsValidationFuse fuse = new PlasmaVaultBalanceAssetsValidationFuse(marketId);
    
            // deploy PlasmaVaultMock so that PlasmaVaultConfigLib storage and balances are in same context
            PlasmaVaultMock vault = new PlasmaVaultMock(address(0), address(0));
    
            // create and grant mock asset as substrate for given market
            MockERC20 token = new MockERC20("Mock", "MOCK", 18);
            address[] memory assetsToGrant = new address[](1);
            assetsToGrant[0] = address(token);
            // grant substrate in vault storage
            vault.grantAssetsToMarket(marketId, assetsToGrant);
    
            // give vault some balance of the token
            token.mint(address(vault), 100 ether);
    
            // prepare data with min > actual balance to violate lower bound
            PlasmaVaultBalanceAssetsValidationFuseEnterData memory data_;
            data_.assets = new address[](1);
            data_.minBalanceValues = new uint256[](1);
            data_.maxBalanceValues = new uint256[](1);
    
            data_.assets[0] = address(token);
            data_.minBalanceValues[0] = 200 ether; // greater than 100 ether in vault
            data_.maxBalanceValues[0] = 1_000 ether;
    
            // expect custom balance error when called from vault context via delegatecall
            vm.expectRevert();
            vault.execute(address(fuse), abi.encodeWithSelector(PlasmaVaultBalanceAssetsValidationFuse.enter.selector, data_));
        }

    function test_enter_RevertWhenAssetNotGranted_triggersTargetBranch105True() public {
        uint256 marketId = 1;
        PlasmaVaultBalanceAssetsValidationFuse fuse = new PlasmaVaultBalanceAssetsValidationFuse(marketId);
    
        // vault used as context for PlasmaVaultConfigLib + balances
        PlasmaVaultMock vault = new PlasmaVaultMock(address(0), address(0));
    
        // deploy token but DO NOT grant it as substrate -> isSubstrateAsAssetGranted == false
        MockERC20 token = new MockERC20("Mock", "MOCK", 18);
    
        // mint some balance to vault so that balance checks would pass if reached
        token.mint(address(vault), 100 ether);
    
        PlasmaVaultBalanceAssetsValidationFuseEnterData memory data_;
        data_.assets = new address[](1);
        data_.minBalanceValues = new uint256[](1);
        data_.maxBalanceValues = new uint256[](1);
    
        data_.assets[0] = address(token);
        data_.minBalanceValues[0] = 0; // any range, won't be reached
        data_.maxBalanceValues[0] = type(uint256).max;
    
        // Expect revert with Errors.WrongValue from the `!isSubstrateAsAssetGranted` branch
        vm.expectRevert(Errors.WrongValue.selector);
        vault.execute(
            address(fuse),
            abi.encodeWithSelector(PlasmaVaultBalanceAssetsValidationFuse.enter.selector, data_)
        );
    }

    function test_enter_SucceedsWhenBalanceWithinRange_triggersTargetBranch117Else() public {
            uint256 marketId = 1;
            PlasmaVaultBalanceAssetsValidationFuse fuse = new PlasmaVaultBalanceAssetsValidationFuse(marketId);
    
            // vault provides the storage context for PlasmaVaultConfigLib and holds the tokens
            PlasmaVaultMock vault = new PlasmaVaultMock(address(0), address(0));
    
            // mock ERC20 asset and grant it as a substrate for the market
            MockERC20 token = new MockERC20("Mock", "MOCK", 18);
            address[] memory assetsToGrant = new address[](1);
            assetsToGrant[0] = address(token);
            vault.grantAssetsToMarket(marketId, assetsToGrant);
    
            // mint balance to the vault so it is within the configured min/max range
            uint256 balance = 100 ether;
            token.mint(address(vault), balance);
    
            PlasmaVaultBalanceAssetsValidationFuseEnterData memory data_;
            data_.assets = new address[](1);
            data_.minBalanceValues = new uint256[](1);
            data_.maxBalanceValues = new uint256[](1);
    
            data_.assets[0] = address(token);
            data_.minBalanceValues[0] = 50 ether;      // less than actual balance
            data_.maxBalanceValues[0] = 150 ether;     // greater than actual balance
    
            // Call fuse via delegatecall from vault so that `address(this)` inside fuse is the vault
            // Balance is within [min,max], so the if(condition) is false and the else-branch is taken
            vault.execute(
                address(fuse),
                abi.encodeWithSelector(PlasmaVaultBalanceAssetsValidationFuse.enter.selector, data_)
            );
        }
}