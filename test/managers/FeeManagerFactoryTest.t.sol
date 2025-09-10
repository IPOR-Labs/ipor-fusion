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

    address private constant EXPECTED_FEE_MANAGER_ADDRESS = 0x104fBc016F4bb334D775a19E8A6510109AC63E00;
    address private constant EXPECTED_PERFORMANCE_FEE_ACCOUNT_ADDRESS = 0x41C3c259514f88211c4CA2fd805A93F8F9A57504;
    address private constant EXPECTED_MANAGEMENT_FEE_ACCOUNT_ADDRESS = 0x0401911641c4781D93c41f9aa8094B171368E6a9;

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
        vm.expectEmit(true, true, true, true);
        emit FeeManagerFactory.FeeManagerDeployed(
            EXPECTED_FEE_MANAGER_ADDRESS, /// @dev feeManager address is precalculated
            FeeManagerData({
                feeManager: EXPECTED_FEE_MANAGER_ADDRESS, /// @dev feeManager address is precalculated
                plasmaVault: MOCK_PLASMA_VAULT,
                performanceFeeAccount: EXPECTED_PERFORMANCE_FEE_ACCOUNT_ADDRESS, /// @dev performanceFeeAccount address is precalculated
                managementFeeAccount: EXPECTED_MANAGEMENT_FEE_ACCOUNT_ADDRESS, /// @dev managementFeeAccount address is precalculated
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

    function testShouldEmitFeeAccountDeployedEvent() external {
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

        // when - expect the FeeAccountDeployed event to be emitted
        vm.expectEmit(true, true, true, true);
        emit FeeManager.FeeAccountDeployed(EXPECTED_PERFORMANCE_FEE_ACCOUNT_ADDRESS, EXPECTED_MANAGEMENT_FEE_ACCOUNT_ADDRESS);

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
