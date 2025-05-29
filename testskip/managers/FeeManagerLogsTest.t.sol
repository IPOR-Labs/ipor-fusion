// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {FeeManagerStorageLib} from "../../contracts/managers/fee/FeeManagerStorageLib.sol";
import "forge-std/console2.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
contract FeeManagerLogsTest is Test {
    address constant FEE_MANAGER_ADDRESS = 0xb8f4F4e5337BF099d4B6D45A4428c2Fb405290e0;

    FeeManager public feeManager;
    address public plasmaVault;
    address public performanceFeeAccount;
    address public managementFeeAccount;
    address public withdrawManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22374570);
        // Load the deployed FeeManager contract
        feeManager = FeeManager(FEE_MANAGER_ADDRESS);

        // Get the fee accounts from the FeeManager
        performanceFeeAccount = feeManager.PERFORMANCE_FEE_ACCOUNT();
        managementFeeAccount = feeManager.MANAGEMENT_FEE_ACCOUNT();
        plasmaVault = feeManager.PLASMA_VAULT();
        withdrawManager = 0xf08CB48BFc705ffB4f2064c578987A27dAad1386;
    }

    function testFeeManagerConfiguration() public {
        console2.log("Plasma Vault Address", plasmaVault);
        // 1. Check Management Fee
        uint256 totalManagementFee = feeManager.getTotalManagementFee();

        console2.log("Total Management Fee (in basis points)", totalManagementFee);
        
        // 2. Check Performance Fee
        uint256 totalPerformanceFee = feeManager.getTotalPerformanceFee();
        console2.log("Total Performance Fee (in basis points)", totalPerformanceFee);

        // 3. Check DAO Fees
        console2.log("DAO Management Fee", feeManager.IPOR_DAO_MANAGEMENT_FEE());
        console2.log("DAO Performance Fee", feeManager.IPOR_DAO_PERFORMANCE_FEE());

        // 4. Check Fee Accounts
        console2.log("Management Fee Account", managementFeeAccount);
        console2.log("Performance Fee Account", performanceFeeAccount);
        
        // 5. Check Fee Account Balances
        uint256 managementFeeBalance = IERC4626(plasmaVault).balanceOf(managementFeeAccount);

        uint256 performanceFeeBalance = IERC4626(plasmaVault).balanceOf(performanceFeeAccount);
        
        console2.log("Management Fee Account Balance", managementFeeBalance);
        console2.log("Performance Fee Account Balance", performanceFeeBalance);

        address holder = 0xde0AEe03678b7B1b886c501A1B647C7cAf0Cd5e3;

        // uint256 timestamp = block.timestamp;

        // vm.warp(timestamp);

        // vm.prank(holder);
        // WithdrawManager(withdrawManager).requestShares(1e20);

        // vm.warp(timestamp + 1000);

        // vm.prank(0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6);
        // WithdrawManager(withdrawManager).releaseFunds(timestamp + 10, 1e20);

        // vm.warp(timestamp + 20);

        // vm.prank(holder);
        // PlasmaVault(plasmaVault).withdraw(1e20, holder, holder);

        vm.prank(0xf2C6a2225BE9829eD77263b032E3D92C52aE6694);
        PlasmaVaultGovernance(plasmaVault).setTotalSupplyCap(type(uint256).max/4);

        // Deposit from holder
        vm.startPrank(holder);
        IERC20(PlasmaVault(plasmaVault).asset()).approve(plasmaVault, 1e20);
        // PlasmaVault(plasmaVault).mint(1e6, holder);

        PlasmaVault(plasmaVault).deposit(1e6, holder);
        vm.stopPrank();


        // // 6. Harvest all fees and check balances after
        // console2.log("\n--- Harvesting All Fees ---");
        
        // // Store initial balances
        uint256 managementBalanceAfter = IERC4626(plasmaVault).balanceOf(managementFeeAccount);
        uint256 performanceBalanceAfter = IERC4626(plasmaVault).balanceOf(performanceFeeAccount);

        console2.log("Management Fee Account Balance After:", managementBalanceAfter);
        console2.log("Performance Fee Account Balance After:", performanceBalanceAfter);

        console2.log("\n--- Management Fee Recipients AFTER ---");
        RecipientFee[] memory managementRecipients = feeManager.getManagementFeeRecipients();
        for (uint256 i = 0; i < managementRecipients.length; i++) {
            
                console2.log("Recipient:", managementRecipients[i].recipient);
                console2.log("Fee Value:", managementRecipients[i].feeValue);
                console2.log("Balance:", IERC4626(plasmaVault).balanceOf(managementRecipients[i].recipient));
            
        }

        // Get and log performance fee recipients  
        console2.log("\n--- Performance Fee Recipients ---");
        RecipientFee[] memory performanceRecipients = feeManager.getPerformanceFeeRecipients();
        for (uint256 i = 0; i < performanceRecipients.length; i++) {
            console2.log(
                "Recipient:", performanceRecipients[i].recipient);
            console2.log("Fee Value:", performanceRecipients[i].feeValue);
            console2.log("Balance:", IERC4626(plasmaVault).balanceOf(performanceRecipients[i].recipient));
        }

        // Get DAO fee recipient address and check balance
        address daoFeeRecipient = feeManager.getIporDaoFeeRecipientAddress();
        console2.log("\n--- DAO Fee Recipient Balance BEFORE ---");
        console2.log("DAO Fee Recipient:", daoFeeRecipient);
        console2.log("DAO Balance:", IERC4626(plasmaVault).balanceOf(daoFeeRecipient));

        // // Harvest both types of fees
        feeManager.harvestAllFees();

        // // // Get balances after harvest
        // uint256 finalManagementBalance = IERC4626(plasmaVault).balanceOf(managementFeeAccount);
        // uint256 finalPerformanceBalance = IERC4626(plasmaVault).balanceOf(performanceFeeAccount);

        // console2.log("Management Fee Account Balance Before:", managementBalanceAfter);
        // console2.log("Management Fee Account Balance After:", finalManagementBalance);
        // console2.log("Management Fee Harvested:", managementBalanceAfter - finalManagementBalance);

        // console2.log("\nPerformance Fee Account Balance Before:", performanceBalanceAfter);
        // console2.log("Performance Fee Account Balance After:", finalPerformanceBalance);
        // console2.log("Performance Fee Harvested:", performanceBalanceAfter - finalPerformanceBalance);

        // // Check DAO and recipient balances
        // console2.log("\n--- Checking DAO and Recipient Balances ---");
        
        // // Get DAO fee recipient address
        // address daoFeeRecipient = feeManager.getIporDaoFeeRecipientAddress();
        // console2.log("DAO Fee Recipient:", daoFeeRecipient);
        // console2.log("DAO Balance:", IERC4626(plasmaVault).balanceOf(daoFeeRecipient));

        // Get and log management fee recipients
        console2.log("\n--- Management Fee Recipients AFTER ---");
        managementRecipients = feeManager.getManagementFeeRecipients();
        for (uint256 i = 0; i < managementRecipients.length; i++) {
            
                console2.log("Recipient:", managementRecipients[i].recipient);
                console2.log("Fee Value:", managementRecipients[i].feeValue);
                console2.log("Balance:", IERC4626(plasmaVault).balanceOf(managementRecipients[i].recipient));
            
        }

        // Get and log performance fee recipients  
        console2.log("\n--- Performance Fee Recipients ---");
        performanceRecipients = feeManager.getPerformanceFeeRecipients();
        for (uint256 i = 0; i < performanceRecipients.length; i++) {
            console2.log(
                "Recipient:", performanceRecipients[i].recipient);
            console2.log("Fee Value:", performanceRecipients[i].feeValue);
            console2.log("Balance:", IERC4626(plasmaVault).balanceOf(performanceRecipients[i].recipient));
        }

        console2.log("\n--- DAO Fee Recipient Balance AFTER ---");
        console2.log("DAO Fee Recipient:", daoFeeRecipient);
        console2.log("DAO Balance:", IERC4626(plasmaVault).balanceOf(daoFeeRecipient));
    }
}
