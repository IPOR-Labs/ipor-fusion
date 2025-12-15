// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeeManager, FeeManagerInitData} from "../../contracts/managers/fee/FeeManager.sol";
import {RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";

contract FeeManagerPerformanceFeeCalculationTest is Test {
    FeeManager public feeManager;
    address public plasmaVault;
    address public authority;
    address public daoRecipient;

    function setUp() public {
        plasmaVault = makeAddr("plasmaVault");
        authority = makeAddr("authority");
        daoRecipient = makeAddr("daoRecipient");

        // Mock authority to have code so setAuthority doesn't fail if called (it checks code length)
        vm.etch(authority, hex"00");

        RecipientFee[] memory emptyFees = new RecipientFee[](0);

        FeeManagerInitData memory initData = FeeManagerInitData({
            initialAuthority: authority,
            plasmaVault: plasmaVault,
            iporDaoManagementFee: 0,
            iporDaoPerformanceFee: 0,
            iporDaoFeeRecipientAddress: daoRecipient,
            recipientManagementFees: emptyFees,
            recipientPerformanceFees: emptyFees
        });

        // We need to mock FeeAccount deployment or accept it will happen.
        // FeeManager constructor deploys FeeAccount which takes address(this) (the FeeManager) in constructor.
        // It should be fine.
        feeManager = new FeeManager(initData);
    }

    function testReproduction_OverMintingPerformanceFee() public {
        // Setup parameters
        uint128 assetDecimals = 18;
        uint128 shareDecimals = 18;
        uint256 decimalsScaler = 10 ** assetDecimals;

        // Initial HWM = 1.0 (in asset units per share, scaled by decimals)
        uint128 initialHWM = uint128(1 * decimalsScaler);

        // Current Exchange Rate P = 2.0 (Price doubled)
        uint128 currentRate = uint128(2 * decimalsScaler);

        // Total Supply = 1000 shares
        uint256 totalSupply = 1000 * 10 ** shareDecimals;

        // Performance Fee = 20% (2000 bps)
        uint256 performanceFee = 2000;

        // 1. Set Initial HWM
        vm.prank(plasmaVault);
        (address recipient1, uint256 feeShares1) = feeManager.calculateAndUpdatePerformanceFee(
            initialHWM,
            totalSupply,
            performanceFee,
            assetDecimals
        );

        assertEq(feeShares1, 0, "First call should return 0 fees and set HWM");

        // 2. Calculate Fee with new Rate
        vm.prank(plasmaVault);
        (address recipient2, uint256 feeShares2) = feeManager.calculateAndUpdatePerformanceFee(
            currentRate,
            totalSupply,
            performanceFee,
            assetDecimals
        );

        // Expected Correct Calculation (Dilution based):
        // Gain = P - H = 2.0 - 1.0 = 1.0
        // Dilution Ratio = Gain / P = 1.0 / 2.0 = 0.5
        // Fee Shares = Total Supply * Fee% * Dilution Ratio
        // Fee Shares = 1000 * 0.20 * 0.5 = 100 shares
        uint256 expectedSharesCorrect = 100 * 10 ** shareDecimals;

        // Current Incorrect Calculation:
        // Gain = P - H = 1.0
        // Normalized Gain (Current impl) = Gain / 10**decimals = 1.0 / 1.0 = 1.0
        // Shares to Harvest = Total Supply * Normalized Gain = 1000 * 1.0 = 1000
        // Fee Shares = Shares to Harvest * Fee% = 1000 * 0.20 = 200 shares
        uint256 expectedSharesIncorrect = 200 * 10 ** shareDecimals;

        // Assert that it matches the CORRECT expectation
        assertEq(feeShares2, expectedSharesCorrect, "Should match the correct dilution-based fee");

        // Assert that it DOES NOT match the INCORRECT expectation
        assertTrue(feeShares2 != expectedSharesIncorrect, "Should not be over-minted anymore");
    }
}
