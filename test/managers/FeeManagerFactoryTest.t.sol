// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeManagerFactory, FeeManagerData, RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager, FeeManagerInitData} from "../../contracts/managers/fee/FeeManager.sol";

contract FeeManagerFactoryTest is Test {
    FeeManagerFactory private feeManagerFactory;

    address private constant MOCK_PLASMA_VAULT = address(0x123);
    address private constant MOCK_AUTHORITY = address(0x456);
    address private constant MOCK_FEE_RECIPIENT = address(0x789);
    address private constant MOCK_DAO_RECIPIENT = address(0xABC);

    uint256 private constant MANAGEMENT_FEE = 200; // 2%
    uint256 private constant PERFORMANCE_FEE = 1000; // 10%
    uint256 private constant DAO_MANAGEMENT_FEE = 300; // 3%
    uint256 private constant DAO_PERFORMANCE_FEE = 1000; // 10%

    function setUp() public {
        feeManagerFactory = new FeeManagerFactory();
    }

    function testShouldEmitFeeManagerDeployedEvent() external {
        // given
        RecipientFee[] memory performanceFees = new RecipientFee[](1);
        performanceFees[0] = RecipientFee({recipient: MOCK_FEE_RECIPIENT, feeValue: PERFORMANCE_FEE});

        RecipientFee[] memory managementFees = new RecipientFee[](1);
        managementFees[0] = RecipientFee({recipient: MOCK_FEE_RECIPIENT, feeValue: MANAGEMENT_FEE});

        FeeManagerInitData memory initData = FeeManagerInitData({
            initialAuthority: MOCK_AUTHORITY,
            plasmaVault: MOCK_PLASMA_VAULT,
            iporDaoManagementFee: DAO_MANAGEMENT_FEE,
            iporDaoPerformanceFee: DAO_PERFORMANCE_FEE,
            iporDaoFeeRecipientAddress: MOCK_DAO_RECIPIENT,
            recipientManagementFees: managementFees,
            recipientPerformanceFees: performanceFees
        });

        // when - expect the FeeManagerDeployed event to be emitted
        vm.expectEmit(false, true, false, true);
        emit FeeManagerFactory.FeeManagerDeployed(
            address(0), // feeManager address (will be different in actual call)
            FeeManagerData({
                feeManager: address(0), // feeManager address (will be different in actual call)
                plasmaVault: MOCK_PLASMA_VAULT,
                performanceFeeAccount: address(0), // will be different in actual call
                managementFeeAccount: address(0), // will be different in actual call
                managementFee: MANAGEMENT_FEE + DAO_MANAGEMENT_FEE,
                performanceFee: PERFORMANCE_FEE + DAO_PERFORMANCE_FEE
            })
        );

        FeeManagerData memory feeManagerData = feeManagerFactory.deployFeeManager(initData);

        // then - verify the deployment was successful
        assertTrue(feeManagerData.feeManager != address(0), "Fee manager should be deployed");
        assertEq(feeManagerData.plasmaVault, MOCK_PLASMA_VAULT, "Plasma vault should match");
        assertTrue(feeManagerData.performanceFeeAccount != address(0), "Performance fee account should be set");
        assertTrue(feeManagerData.managementFeeAccount != address(0), "Management fee account should be set");
        assertEq(feeManagerData.managementFee, MANAGEMENT_FEE + DAO_MANAGEMENT_FEE, "Management fee should match");
        assertEq(feeManagerData.performanceFee, PERFORMANCE_FEE + DAO_PERFORMANCE_FEE, "Performance fee should match");
    }
}
