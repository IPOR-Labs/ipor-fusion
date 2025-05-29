pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";

contract PlasmaVaultBasicTest is Test {
    address public plasmaVault = 0x85b7927B6d721638b575972111F4CE6DaCb7D33C;
    address public userOne;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 25946373);
        userOne = address(0x777);
    }

    function testShouldReadFeeConfiguration() public {
        PlasmaVaultGovernance gov = PlasmaVaultGovernance(plasmaVault);
        PlasmaVault vault = PlasmaVault(payable(plasmaVault));

        // Get performance fee data
        PlasmaVaultStorageLib.PerformanceFeeData memory perfFee = gov.getPerformanceFeeData();
        console2.log("Performance Fee Configuration:");
        console2.log("Fee Account:", perfFee.feeAccount);
        console2.log("Fee Percentage:", perfFee.feeInPercentage, "basis points (100 = 1%)");

        // Get management fee data
        PlasmaVaultStorageLib.ManagementFeeData memory mgmtFee = gov.getManagementFeeData();
        console2.log("\nManagement Fee Configuration:");
        console2.log("Fee Account:", mgmtFee.feeAccount);
        console2.log("Fee Percentage:", mgmtFee.feeInPercentage, "basis points (100 = 1%)");
        console2.log("Last Update Timestamp:", mgmtFee.lastUpdateTimestamp);

        // Get total assets

        // console2.log("Total assets in all markets:", PlasmaVaultLib.getTotalAssetsInAllMarkets());

        uint256 totalAssets = vault.totalAssets();
        console2.log("\nTotal Assets:", totalAssets);

        uint256 totalSupply = vault.totalSupply();
        console2.log("\nTotal Supply:", totalSupply);

        // uint256[] memory marketIds = gov.getActiveMarketsInBalanceFuses();
        // console2.log("\nActive Market IDs:");
        // for (uint256 i = 0; i < marketIds.length; i++) {
        //     console2.log("Market", i, ":", marketIds[i]);
        // }
        // vault.updateMarketsBalances(marketIds);
        // totalAssets = vault.totalAssets();
        // console2.log("\nTotal Assets after:", totalAssets);
    }
}
