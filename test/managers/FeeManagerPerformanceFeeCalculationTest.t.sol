// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

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
        // IL-9601: the vault passes the rate and the HWM is stored per 10 ** decimals() shares times this scale
        assertEq(feeManager.HIGH_WATER_MARK_SCALE(), 1e12, "HWM scale");

        // Initial HWM = 1.0 (in asset units per share, scaled by decimals and the HWM scale)
        uint128 initialHWM = uint128(1 * decimalsScaler * 1e12);

        // Current Exchange Rate P = 2.0 (Price doubled)
        uint128 currentRate = uint128(2 * decimalsScaler * 1e12);

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

        // 2. Calculate Fee with new Rate (the FeeManager prices the share rate after the fee mint from the vault)
        _mockVault(uint8(shareDecimals), 2000 * 10 ** assetDecimals);
        vm.prank(plasmaVault);
        (address recipient2, uint256 feeShares2) = feeManager.calculateAndUpdatePerformanceFee(
            currentRate,
            totalSupply,
            performanceFee,
            assetDecimals
        );

        // Expected Correct Calculation (fee shares worth the fee after their own mint, IL-8870):
        // Gain = P - H = 2.0 - 1.0 = 1.0
        // Fee as a part of the vault value: x = Fee% * Gain / P = 0.20 * 1.0 / 2.0 = 0.1
        // Fee Shares = Total Supply * x / (1 - x) = 1000 * 0.1 / 0.9 = 111.11 shares
        // After the mint they are 111.11 / 1111.11 = 10% of the vault = 200 assets = 20% of the gain of 1000 assets.
        // 100 shares (Total Supply * x, priced before their own mint) would be worth 100 / 1100 * 2000 = 181.8 assets.
        uint256 expectedSharesCorrect = (1000 * 10 ** shareDecimals) / 9;

        // Current Incorrect Calculation:
        // Gain = P - H = 1.0
        // Normalized Gain (Current impl) = Gain / 10**decimals = 1.0 / 1.0 = 1.0
        // Shares to Harvest = Total Supply * Normalized Gain = 1000 * 1.0 = 1000
        // Fee Shares = Shares to Harvest * Fee% = 1000 * 0.20 = 200 shares
        uint256 expectedSharesIncorrect = 200 * 10 ** shareDecimals;

        // Assert that it matches the CORRECT expectation
        assertEq(feeShares2, expectedSharesCorrect, "Should match the fee shares sized on the post-mint price");
        assertApproxEqAbs(
            (feeShares2 * 2000 * 10 ** assetDecimals) / (totalSupply + feeShares2),
            200 * 10 ** assetDecimals,
            1,
            "After the mint the fee shares are worth 20% of the gain"
        );

        // Assert that it DOES NOT match the INCORRECT expectation
        assertTrue(feeShares2 != expectedSharesIncorrect, "Should not be over-minted anymore");

        // IL-8744: the HWM is the share price after the fee mint: (TA + 1) / (S + f + 1) per 1e18 shares times the HWM scale 1e12 (IL-9601)
        _assertPostMintHwm(feeShares2, totalSupply, currentRate);
    }

    function _mockVault(uint8 shareDecimals_, uint256 totalAssets_) private {
        vm.mockCall(plasmaVault, abi.encodeWithSignature("decimals()"), abi.encode(shareDecimals_));
        vm.mockCall(plasmaVault, abi.encodeWithSignature("totalAssets()"), abi.encode(totalAssets_));
    }

    function _assertPostMintHwm(uint256 feeShares_, uint256 totalSupply_, uint128 preMintRate_) private view {
        uint256 expectedHwm = (1e18 * 1e12 * (2000e18 + 1)) / (totalSupply_ + feeShares_ + 1);
        uint256 storedHwm = feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
        assertEq(storedHwm, expectedHwm, "HWM is the post-mint share price");
        assertLt(storedHwm, preMintRate_, "HWM is below the pre-mint rate");
    }
}
