// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {TransientStorageLib} from "../../../contracts/transient_storage/TransientStorageLib.sol";
import {ReserveVaultStorageLib} from "../../../contracts/fuses/reserve_vault/lib/ReserveVaultStorageLib.sol";
import {ReserveVaultBoostLib} from "../../../contracts/fuses/reserve_vault/lib/ReserveVaultBoostLib.sol";

/// @dev Exposes the internal functions of both libraries. The harness runs them in its own storage and transient
///      storage, as a reserve vault does when it delegatecalls a fuse.
contract ReserveVaultLibsHarness {
    function principalSlot() external pure returns (bytes32) {
        return ReserveVaultStorageLib.PRINCIPAL_SLOT;
    }

    function boostBaseSlot() external pure returns (bytes32) {
        return ReserveVaultBoostLib.BOOST_SLOT;
    }

    function getPrincipal(address vault_) external view returns (uint256) {
        return ReserveVaultStorageLib.getPrincipal(vault_);
    }

    function increasePrincipal(address vault_, uint256 amount_) external returns (uint256) {
        return ReserveVaultStorageLib.increasePrincipal(vault_, amount_);
    }

    function decreasePrincipal(address vault_, uint256 amount_) external returns (uint256) {
        return ReserveVaultStorageLib.decreasePrincipal(vault_, amount_);
    }

    function boostSlot(address memberVault_) external pure returns (bytes32) {
        return ReserveVaultBoostLib.boostSlot(memberVault_);
    }

    function setBoost(address memberVault_, uint256 boost_) external {
        ReserveVaultBoostLib.setBoost(memberVault_, boost_);
    }

    function clearBoost(address memberVault_) external {
        ReserveVaultBoostLib.clearBoost(memberVault_);
    }

    function getBoost(address memberVault_) external view returns (uint256) {
        return ReserveVaultBoostLib.getBoost(memberVault_);
    }

    function rawTload(bytes32 slot_) external view returns (bytes32) {
        return TransientStorageLib.tload(slot_);
    }

    function computeBoost(
        uint256 principal_,
        uint256 shares_,
        uint256 totalAssets_,
        uint256 virtualSupply_
    ) external pure returns (uint256) {
        return ReserveVaultBoostLib.computeBoost(principal_, shares_, totalAssets_, virtualSupply_);
    }

    function convertToUsdWadRoundUp(
        uint256 amount_,
        uint256 price_,
        uint256 priceDecimals_,
        uint256 assetDecimals_
    ) external pure returns (uint256) {
        return ReserveVaultBoostLib.convertToUsdWadRoundUp(amount_, price_, priceDecimals_, assetDecimals_);
    }
}

/// @dev Unit and fuzz tests of the principal ledger, the boost slot, the boost formula and the USD conversion.
///      foundry.toml keeps `isolate = false`: a test function is one transaction, so a transient value written by one
///      harness call is visible to the next call in the same test, and every test starts with empty transient storage.
contract ReserveVaultLibsTest is Test {
    string private constant PRINCIPAL_NAMESPACE = "io.ipor.reserveVault.Principal";
    string private constant BOOST_NAMESPACE = "io.ipor.reserveVault.Boost";

    address private constant VAULT_A = address(0xA11CE);
    address private constant VAULT_B = address(0xB0B);

    /// @dev 10 ** decimals offset of a PlasmaVault (offset 2)
    uint256 private constant SHARE_SCALE = 100;

    /// @dev 0.999873211457913207 USD in 18 decimals: a price off the 1e6 grid of a 6-decimal asset
    uint256 private constant OFF_GRID_PRICE = 999_873_211_457_913_207;

    ReserveVaultLibsHarness private _harness;

    function setUp() public {
        _harness = new ReserveVaultLibsHarness();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Slot constants and derivation
    // ---------------------------------------------------------------------------------------------------------------

    function testPrincipalSlotMatchesErc7201Formula() public view {
        assertEq(_harness.principalSlot(), _erc7201(PRINCIPAL_NAMESPACE));
    }

    function testBoostBaseSlotMatchesErc7201Formula() public view {
        assertEq(_harness.boostBaseSlot(), _erc7201(BOOST_NAMESPACE));
    }

    function testFuzzBoostSlotMatchesDerivationFormula(address memberVault_) public view {
        assertEq(_harness.boostSlot(memberVault_), keccak256(abi.encode(memberVault_, _erc7201(BOOST_NAMESPACE))));
    }

    function testFuzzBoostSlotsDifferPerMemberVault(address vaultA_, address vaultB_) public view {
        vm.assume(vaultA_ != vaultB_);

        assertNotEq(_harness.boostSlot(vaultA_), _harness.boostSlot(vaultB_));
    }

    function testBoostSlotDoesNotOverlapFuseInputsAndOutputs() public view {
        bytes32 fuseInputsSlot = keccak256(abi.encode(VAULT_A, TransientStorageLib.TRANSIENT_STORAGE_SLOT));
        bytes32 fuseOutputsSlot = bytes32(uint256(fuseInputsSlot) + 1);

        assertNotEq(_harness.boostSlot(VAULT_A), fuseInputsSlot);
        assertNotEq(_harness.boostSlot(VAULT_A), fuseOutputsSlot);
        assertNotEq(_harness.boostSlot(VAULT_A), _harness.boostSlot(VAULT_B));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Principal ledger
    // ---------------------------------------------------------------------------------------------------------------

    function testIncreasePrincipalAccumulatesPerVault() public {
        assertEq(_harness.getPrincipal(VAULT_A), 0);

        assertEq(_harness.increasePrincipal(VAULT_A, 100_000_000), 100_000_000);
        assertEq(_harness.increasePrincipal(VAULT_A, 50_000_000), 150_000_000);
        assertEq(_harness.increasePrincipal(VAULT_B, 7), 7);

        assertEq(_harness.getPrincipal(VAULT_A), 150_000_000);
        assertEq(_harness.getPrincipal(VAULT_B), 7);
    }

    function testDecreasePrincipalPartialThenFull() public {
        _harness.increasePrincipal(VAULT_A, 100_000_000);
        _harness.increasePrincipal(VAULT_B, 1);

        assertEq(_harness.decreasePrincipal(VAULT_A, 40_000_000), 60_000_000);
        assertEq(_harness.getPrincipal(VAULT_A), 60_000_000);

        assertEq(_harness.decreasePrincipal(VAULT_A, 60_000_000), 0);
        assertEq(_harness.getPrincipal(VAULT_A), 0);
        assertEq(_harness.getPrincipal(VAULT_B), 1);
    }

    function testDecreasePrincipalAboveRecordedReverts() public {
        _harness.increasePrincipal(VAULT_A, 100_000_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultStorageLib.ReserveVaultPrincipalUnderflow.selector,
                VAULT_A,
                100_000_001,
                100_000_000
            )
        );
        _harness.decreasePrincipal(VAULT_A, 100_000_001);

        assertEq(_harness.getPrincipal(VAULT_A), 100_000_000);
    }

    function testDecreasePrincipalOfEmptyVaultReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ReserveVaultStorageLib.ReserveVaultPrincipalUnderflow.selector, VAULT_B, 1, 0)
        );
        _harness.decreasePrincipal(VAULT_B, 1);
    }

    function testDecreasePrincipalByZeroKeepsPrincipal() public {
        _harness.increasePrincipal(VAULT_A, 5);

        assertEq(_harness.decreasePrincipal(VAULT_A, 0), 5);
        assertEq(_harness.decreasePrincipal(VAULT_B, 0), 0);
    }

    function testPrincipalIsStoredAtErc7201MappingSlot() public {
        _harness.increasePrincipal(VAULT_A, 123_456_789);

        bytes32 slot = keccak256(abi.encode(VAULT_A, _erc7201(PRINCIPAL_NAMESPACE)));

        assertEq(uint256(vm.load(address(_harness), slot)), 123_456_789);
        assertEq(uint256(vm.load(address(_harness), _erc7201(PRINCIPAL_NAMESPACE))), 0);
    }

    function testFuzzPrincipalLedgerNeverGoesBelowZero(uint256 first_, uint256 second_, uint256 withdrawn_) public {
        uint256 first = bound(first_, 0, 1e36);
        uint256 second = bound(second_, 0, 1e36);
        uint256 total = first + second;
        uint256 withdrawn = bound(withdrawn_, 0, total);

        _harness.increasePrincipal(VAULT_A, first);
        _harness.increasePrincipal(VAULT_A, second);
        assertEq(_harness.decreasePrincipal(VAULT_A, withdrawn), total - withdrawn);

        uint256 remaining = total - withdrawn;
        vm.expectRevert(
            abi.encodeWithSelector(
                ReserveVaultStorageLib.ReserveVaultPrincipalUnderflow.selector,
                VAULT_A,
                remaining + 1,
                remaining
            )
        );
        _harness.decreasePrincipal(VAULT_A, remaining + 1);

        assertEq(_harness.getPrincipal(VAULT_A), remaining);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Boost in transient storage
    // ---------------------------------------------------------------------------------------------------------------

    function testBoostWriteReadClear() public {
        bytes32 slotA = keccak256(abi.encode(VAULT_A, _erc7201(BOOST_NAMESPACE)));

        assertEq(_harness.getBoost(VAULT_A), 0);

        _harness.setBoost(VAULT_A, 111_111_111);

        assertEq(_harness.getBoost(VAULT_A), 111_111_111);
        assertEq(uint256(_harness.rawTload(slotA)), 111_111_111);
        assertEq(_harness.getBoost(VAULT_B), 0);
        assertEq(uint256(vm.load(address(_harness), slotA)), 0, "boost must not touch persistent storage");

        _harness.clearBoost(VAULT_A);

        assertEq(_harness.getBoost(VAULT_A), 0);
        assertEq(uint256(_harness.rawTload(slotA)), 0);
    }

    function testBoostOverwriteKeepsOtherVaults() public {
        _harness.setBoost(VAULT_A, 1);
        _harness.setBoost(VAULT_B, 2);
        _harness.setBoost(VAULT_A, 3);

        assertEq(_harness.getBoost(VAULT_A), 3);
        assertEq(_harness.getBoost(VAULT_B), 2);

        _harness.clearBoost(VAULT_A);

        assertEq(_harness.getBoost(VAULT_A), 0);
        assertEq(_harness.getBoost(VAULT_B), 2);
    }

    function testBoostIsVisibleOnlyInTheWriterContext() public {
        ReserveVaultLibsHarness otherContext = new ReserveVaultLibsHarness();

        _harness.setBoost(VAULT_A, 111_111_111);

        assertEq(otherContext.getBoost(VAULT_A), 0);
        assertEq(_harness.getBoost(VAULT_A), 111_111_111);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Boost formula
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Integer model of the member vault (PlasmaVault conversions, decimals offset 2, one virtual asset, zero fees):
    ///      users deposit 1 011.111111 USDC, the reserve vault deposits 100 USDC, then the member vault loses
    ///      111.111111 USDC and holds 1 000 USDC of real assets; the reserve vault's shares are worth 90 USDC.
    function testComputeBoostBriefLossCase() public view {
        uint256 supply;
        uint256 totalAssets;

        uint256 userShares = _toShares(1_011_111_111, supply, totalAssets, Math.Rounding.Floor);
        supply += userShares;
        totalAssets += 1_011_111_111;

        uint256 reserveShares = _toShares(100_000_000, supply, totalAssets, Math.Rounding.Floor);
        supply += reserveShares;
        totalAssets += 100_000_000;
        assertEq(reserveShares, 10_000_000_000, "reserve vault shares");

        totalAssets -= 111_111_111;
        assertEq(totalAssets, 1_000_000_000, "real assets after the loss");
        assertEq(_toAssets(1e8, supply, totalAssets, Math.Rounding.Floor), 900_000, "share price before the boost");
        assertEq(_toAssets(reserveShares, supply, totalAssets, Math.Rounding.Floor), 90_000_000, "reserve position");
        assertEq(_toAssets(userShares, supply, totalAssets, Math.Rounding.Floor), 910_000_000, "other holders");

        uint256 principal = 100_000_000;
        uint256 virtualSupply = _toShares(totalAssets + 1, supply, totalAssets, Math.Rounding.Floor);
        assertEq(virtualSupply, supply + SHARE_SCALE, "D = supply + virtual shares");

        uint256 boost = _harness.computeBoost(principal, reserveShares, totalAssets, virtualSupply);

        assertEq(boost, 111_111_111, "boost");
        assertEq(_toAssets(reserveShares, supply, totalAssets + boost, Math.Rounding.Floor), 100_000_000);
        assertEq(_toAssets(reserveShares, supply, totalAssets + boost - 1, Math.Rounding.Floor), 99_999_999);
        assertEq(_toAssets(1e8, supply, totalAssets + boost, Math.Rounding.Floor), 1_000_000, "share price in window");

        // the member vault books exactly the boost back from USD, at a price on and off the 1e6 grid
        assertEq(_bookedByVault(_harness.convertToUsdWadRoundUp(boost, 1e8, 8, 6), 1e8, 8, 6), boost);
        assertEq(
            _bookedByVault(_harness.convertToUsdWadRoundUp(boost, OFF_GRID_PRICE, 18, 6), OFF_GRID_PRICE, 18, 6),
            boost
        );

        // withdrawing the principal in the window burns every reserve share (previewWithdraw rounds up)
        uint256 burned = _toShares(principal, supply, totalAssets + boost, Math.Rounding.Ceil);
        assertEq(burned, reserveShares, "burned shares");

        supply -= burned;
        totalAssets -= principal;
        assertEq(totalAssets, 900_000_000, "real assets after the exit");
        assertEq(_toAssets(1e8, supply, totalAssets, Math.Rounding.Floor), 890_109, "share price after the exit");
        assertEq(_toAssets(userShares, supply, totalAssets, Math.Rounding.Floor), 900_000_000, "other holders after");
    }

    function testFuzzComputeBoostIsTightForLoss(
        uint256 shares_,
        uint256 otherShares_,
        uint256 totalAssets_,
        uint256 shortfall_
    ) public view {
        uint256 shares = bound(shares_, 1, 1e36);
        uint256 virtualSupply = shares + bound(otherShares_, 1, 1e38);
        uint256 totalAssets = bound(totalAssets_, 0, 1e30);
        uint256 value = _valueOf(shares, totalAssets, virtualSupply);
        uint256 principal = value + bound(shortfall_, 1, 1e30);

        uint256 boost = _harness.computeBoost(principal, shares, totalAssets, virtualSupply);

        assertGe(boost, 1, "a loss always needs a boost");
        assertGe(_valueOf(shares, totalAssets + boost, virtualSupply), principal, "boost covers the principal");
        assertLt(_valueOf(shares, totalAssets + boost - 1, virtualSupply), principal, "boost - 1 does not");
    }

    function testFuzzComputeBoostIsZeroWithoutLoss(
        uint256 shares_,
        uint256 otherShares_,
        uint256 totalAssets_,
        uint256 principal_
    ) public view {
        uint256 shares = bound(shares_, 1, 1e36);
        uint256 virtualSupply = shares + bound(otherShares_, 1, 1e38);
        uint256 totalAssets = bound(totalAssets_, 0, 1e30);
        uint256 value = _valueOf(shares, totalAssets, virtualSupply);
        uint256 principal = bound(principal_, 0, value);

        assertEq(_harness.computeBoost(principal, shares, totalAssets, virtualSupply), 0);
    }

    function testComputeBoostAtTheLossBoundary() public view {
        // 1e10 of 111 111 111 200 virtual shares at 1 000 000 000 total assets are worth 90 000 000
        assertEq(_harness.computeBoost(90_000_000, 10_000_000_000, 1_000_000_000, 111_111_111_200), 0);
        assertEq(_harness.computeBoost(90_000_001, 10_000_000_000, 1_000_000_000, 111_111_111_200), 11);
        assertEq(_harness.computeBoost(0, 1, 0, 100), 0);
    }

    function testComputeBoostZeroSharesReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReserveVaultBoostLib.ReserveVaultBoostZeroShares.selector));
        _harness.computeBoost(100_000_000, 0, 1_000_000_000, 111_111_111_200);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // USD conversion rounded up
    // ---------------------------------------------------------------------------------------------------------------

    function testFuzzUsdRoundUpBoundsUpTo18Decimals(
        uint256 amount_,
        uint256 priceMantissa_,
        uint256 priceExponent_
    ) public view {
        uint256 amount = bound(amount_, 1, 1e30);
        uint256[3] memory assetDecimalsList = [uint256(6), 8, 18];
        uint256[2] memory priceDecimalsList = [uint256(8), 18];

        for (uint256 i; i < assetDecimalsList.length; ++i) {
            for (uint256 j; j < priceDecimalsList.length; ++j) {
                uint256 priceDecimals = priceDecimalsList[j];
                _assertUsdBoundsUpTo18Decimals(
                    amount,
                    _price(priceMantissa_, priceExponent_, priceDecimals),
                    priceDecimals,
                    assetDecimalsList[i]
                );
            }
        }
    }

    function testFuzzUsdRoundUpBoundsAbove18Decimals(
        uint256 amount_,
        uint256 priceMantissa_,
        uint256 priceExponent_
    ) public view {
        uint256 amount = bound(amount_, 1, 1e36);
        uint256[3] memory assetDecimalsList = [uint256(19), 24, 27];
        uint256[2] memory priceDecimalsList = [uint256(8), 18];

        for (uint256 i; i < assetDecimalsList.length; ++i) {
            for (uint256 j; j < priceDecimalsList.length; ++j) {
                uint256 priceDecimals = priceDecimalsList[j];
                _assertUsdBoundsAbove18Decimals(
                    amount,
                    _price(priceMantissa_, priceExponent_, priceDecimals),
                    priceDecimals,
                    assetDecimalsList[i]
                );
            }
        }
    }

    function testUsdRoundUpOutsidePrecisionDomainBooksTen() public view {
        // 18-decimal asset, 1 wei, price 0.1 USD: one asset wei is worth 0.1 USD WAD units
        uint256 usdPrice8 = _harness.convertToUsdWadRoundUp(1, 1e7, 8, 18);
        assertEq(usdPrice8, 1);
        assertEq(_bookedByVault(usdPrice8, 1e7, 8, 18), 10);

        uint256 usdPrice18 = _harness.convertToUsdWadRoundUp(1, 1e17, 18, 18);
        assertEq(usdPrice18, 1);
        assertEq(_bookedByVault(usdPrice18, 1e17, 18, 18), 10);

        // the stated upper bound amount + ceil(10^pd / q) - 1 = 1 + 10 - 1 is reached
        assertEq(1 + Math.ceilDiv(1e8, 1e7) - 1, 10);
    }

    function testUsdRoundUpOffGridPriceBooksFullAmountWhereFloorLosesOneWei() public view {
        uint256 amount = 100_000_001;

        uint256 usd = _harness.convertToUsdWadRoundUp(amount, OFF_GRID_PRICE, 18, 6);
        assertEq(usd, 99_987_322_145_664_532_158);
        assertEq(_bookedByVault(usd, OFF_GRID_PRICE, 18, 6), 100_000_001);

        // the floor conversion of Erc4626BalanceFuse loses the last wei on the way back
        uint256 usdFloor = IporMath.convertToWad(amount * OFF_GRID_PRICE, 6 + 18);
        assertEq(usdFloor, 99_987_322_145_664_532_157);
        assertEq(_bookedByVault(usdFloor, OFF_GRID_PRICE, 18, 6), 100_000_000);
    }

    function testUsdRoundUpOfSummedAmountsStaysExact() public view {
        // principals of two member vaults in the same asset, converted once as a sum
        uint256 usd = _harness.convertToUsdWadRoundUp(100_000_001 + 33_333_333, OFF_GRID_PRICE, 18, 6);
        assertEq(_bookedByVault(usd, OFF_GRID_PRICE, 18, 6), 133_333_334);

        // near the edge of the precision domain separately rounded-up values over-book by one wei, the sum does not
        uint256 edgePrice = 1_365_206_019_907_135_093;
        uint256 first = 462_428_005;
        uint256 second = 685_553_380;
        uint256 separately = _harness.convertToUsdWadRoundUp(first, edgePrice, 18, 18) +
            _harness.convertToUsdWadRoundUp(second, edgePrice, 18, 18);
        uint256 once = _harness.convertToUsdWadRoundUp(first + second, edgePrice, 18, 18);

        assertEq(_bookedByVault(separately, edgePrice, 18, 18), first + second + 1);
        assertEq(_bookedByVault(once, edgePrice, 18, 18), first + second);
    }

    function testUsdRoundUpSixDecimalsIsExactDownTo1e12Usd() public view {
        // price 1e-12 USD in 18 decimals: one wei of a 6-decimal asset is worth exactly one USD WAD unit
        uint256 usd = _harness.convertToUsdWadRoundUp(100_000_001, 1e6, 18, 6);
        assertEq(usd, 100_000_001);
        assertEq(_bookedByVault(usd, 1e6, 18, 6), 100_000_001);

        // price 1e-8 USD in 8 decimals
        uint256 usdPrice8 = _harness.convertToUsdWadRoundUp(111_111_111, 1, 8, 6);
        assertEq(_bookedByVault(usdPrice8, 1, 8, 6), 111_111_111);
    }

    function testUsdRoundUpAbove18DecimalsRoundsToWadGrainFirst() public view {
        // 24-decimal asset (grain 1e6 wei), 1.5e6 wei, price 3 USD in 8 decimals
        uint256 usd = _harness.convertToUsdWadRoundUp(1_500_000, 3e8, 8, 24);
        assertEq(usd, 6);
        assertEq(_bookedByVault(usd, 3e8, 8, 24), 2_000_000);

        // one rounding of the unscaled amount is not enough: it books less than the amount
        uint256 singleRounding = Math.mulDiv(1_500_000, 3e8, 10 ** (24 + 8 - 18), Math.Rounding.Ceil);
        assertEq(singleRounding, 5);
        assertEq(_bookedByVault(singleRounding, 3e8, 8, 24), 1_000_000);

        // an amount on the grain is booked exactly
        uint256 usdOnGrain = _harness.convertToUsdWadRoundUp(7_000_000, 3e8, 8, 24);
        assertEq(_bookedByVault(usdOnGrain, 3e8, 8, 24), 7_000_000);
    }

    function testUsdRoundUpZeroAmountIsZero() public view {
        assertEq(_harness.convertToUsdWadRoundUp(0, 0, 8, 6), 0);
        assertEq(_harness.convertToUsdWadRoundUp(0, 1e8, 8, 6), 0);
        assertEq(_harness.convertToUsdWadRoundUp(0, 1e8, 8, 24), 0);
    }

    function testUsdRoundUpZeroPriceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ReserveVaultBoostLib.ReserveVaultUsdConversionZeroPrice.selector));
        _harness.convertToUsdWadRoundUp(1, 0, 8, 6);

        vm.expectRevert(abi.encodeWithSelector(ReserveVaultBoostLib.ReserveVaultUsdConversionZeroPrice.selector));
        _harness.convertToUsdWadRoundUp(1, 0, 18, 24);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _assertUsdBoundsUpTo18Decimals(
        uint256 amount_,
        uint256 price_,
        uint256 priceDecimals_,
        uint256 assetDecimals_
    ) private view {
        uint256 booked = _bookedByVault(
            _harness.convertToUsdWadRoundUp(amount_, price_, priceDecimals_, assetDecimals_),
            price_,
            priceDecimals_,
            assetDecimals_
        );

        // value of one asset wei in USD WAD units, multiplied by 10^priceDecimals
        uint256 assetWeiValue = price_ * 10 ** (18 - assetDecimals_);
        uint256 priceScale = 10 ** priceDecimals_;
        uint256 maxExcess = (priceScale + assetWeiValue - 1) / assetWeiValue - 1;

        assertGe(booked, amount_, "booked below the amount");
        assertLe(booked, amount_ + maxExcess, "booked above the stated upper bound");
        if (assetWeiValue >= priceScale) {
            assertEq(booked, amount_, "not exact inside the precision domain");
        }
    }

    function _assertUsdBoundsAbove18Decimals(
        uint256 amount_,
        uint256 price_,
        uint256 priceDecimals_,
        uint256 assetDecimals_
    ) private view {
        uint256 booked = _bookedByVault(
            _harness.convertToUsdWadRoundUp(amount_, price_, priceDecimals_, assetDecimals_),
            price_,
            priceDecimals_,
            assetDecimals_
        );

        uint256 grain = 10 ** (assetDecimals_ - 18);
        uint256 amountOnGrain = ((amount_ + grain - 1) / grain) * grain;
        uint256 priceScale = 10 ** priceDecimals_;
        uint256 maxExcessUnits = (priceScale + price_ - 1) / price_ - 1;

        assertGe(booked, amount_, "booked below the amount");
        assertLe(booked, amountOnGrain + maxExcessUnits * grain, "booked above the stated upper bound");
        if (price_ >= priceScale) {
            assertEq(booked, amountOnGrain, "not exact to the grain inside the precision domain");
        }
    }

    /// @dev Reproduces the conversion back to the underlying in PlasmaVaultMarketsLib.updateMarketsBalances
    function _bookedByVault(
        uint256 wadBalanceAmountInUsd_,
        uint256 price_,
        uint256 priceDecimals_,
        uint256 assetDecimals_
    ) private pure returns (uint256) {
        return
            IporMath.convertWadToAssetDecimals(
                IporMath.division(wadBalanceAmountInUsd_ * IporMath.BASIS_OF_POWER ** priceDecimals_, price_),
                assetDecimals_
            );
    }

    /// @dev Spreads prices over orders of magnitude, from 10^-priceDecimals USD to about 10^13 USD
    function _price(uint256 mantissa_, uint256 exponent_, uint256 priceDecimals_) private pure returns (uint256) {
        return bound(mantissa_, 1, 1e9) * 10 ** bound(exponent_, 0, priceDecimals_ + 4);
    }

    /// @dev floor(shares * (totalAssets + 1) / virtualSupply): the member vault's value of the shares (maxWithdraw)
    function _valueOf(uint256 shares_, uint256 totalAssets_, uint256 virtualSupply_) private pure returns (uint256) {
        return (shares_ * (totalAssets_ + 1)) / virtualSupply_;
    }

    /// @dev PlasmaVault conversion of assets to shares with decimals offset 2 and zero fees
    function _toShares(
        uint256 assets_,
        uint256 supply_,
        uint256 totalAssets_,
        Math.Rounding rounding_
    ) private pure returns (uint256) {
        return
            supply_ == 0
                ? assets_ * SHARE_SCALE
                : Math.mulDiv(assets_, supply_ + SHARE_SCALE, totalAssets_ + 1, rounding_);
    }

    /// @dev PlasmaVault conversion of shares to assets with decimals offset 2 and zero fees
    function _toAssets(
        uint256 shares_,
        uint256 supply_,
        uint256 totalAssets_,
        Math.Rounding rounding_
    ) private pure returns (uint256) {
        return
            supply_ == 0
                ? Math.mulDiv(shares_, 1, SHARE_SCALE, rounding_)
                : Math.mulDiv(shares_, totalAssets_ + 1, supply_ + SHARE_SCALE, rounding_);
    }

    function _erc7201(string memory namespace_) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace_))) - 1)) & ~bytes32(uint256(0xff));
    }
}
