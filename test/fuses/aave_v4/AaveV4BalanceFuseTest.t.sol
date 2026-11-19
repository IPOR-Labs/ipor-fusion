// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {IporMath} from "../../../contracts/libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4BalanceFuse} from "../../../contracts/fuses/aave_v4/AaveV4BalanceFuse.sol";
import {AaveV4SupplyFuse, AaveV4SupplyFuseEnterData} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {AaveV4BorrowFuse, AaveV4BorrowFuseEnterData} from "../../../contracts/fuses/aave_v4/AaveV4BorrowFuse.sol";
import {
    AaveV4CollateralFuse,
    AaveV4CollateralFuseEnterData
} from "../../../contracts/fuses/aave_v4/AaveV4CollateralFuse.sol";
import {IAaveV4Spoke} from "../../../contracts/fuses/aave_v4/ext/IAaveV4Spoke.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockAaveV4Spoke} from "./MockAaveV4Spoke.sol";
import {MockPriceOracle} from "./MockPriceOracle.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

/// @title AaveV4BalanceFuseTest
/// @notice Tests for AaveV4BalanceFuse contract
contract AaveV4BalanceFuseTest is Test {
    uint256 public constant MARKET_ID = 49;
    uint256 public constant RESERVE_ID_1 = 1;
    uint256 public constant RESERVE_ID_2 = 2;

    // Prices in 8 decimals
    uint256 public constant TOKEN_PRICE = 1e8; // $1
    uint256 public constant TOKEN2_PRICE = 2000e8; // $2000

    // Per-spoke scenarios (IL-9552): spoke A = `spoke`, spoke B = `spoke2`
    uint256 private constant DEBT_RESERVE_ID = 3;
    uint256 private constant FREE_RESERVE_ID = 4;
    uint256 private constant COLLATERAL_AMOUNT = 400_000e18; // $400k at $1
    uint256 private constant REPRICED_COLLATERAL_PRICE = 0.625e8; // collateral worth $250k
    uint256 private constant DEBT_AMOUNT = 300_000e6; // $300k

    AaveV4BalanceFuse public balanceFuse;
    AaveV4SupplyFuse public supplyFuse;
    AaveV4BorrowFuse public borrowFuse;
    AaveV4CollateralFuse public collateralFuse;
    PlasmaVaultMock public vaultMock;
    MockAaveV4Spoke public spoke;
    MockAaveV4Spoke public spoke2;
    MockPriceOracle public oracle;
    ERC20Mock public token; // 18 decimals, $1
    ERC20Mock public token2; // 8 decimals, $2000
    ERC20Mock private debtToken; // 6 decimals, $1 (spoke A debt)
    ERC20Mock private freeToken; // 18 decimals, $1 (spoke A supply not enabled as collateral)

    function setUp() public {
        // Deploy contracts
        oracle = new MockPriceOracle();
        balanceFuse = new AaveV4BalanceFuse(MARKET_ID);
        supplyFuse = new AaveV4SupplyFuse(MARKET_ID);
        borrowFuse = new AaveV4BorrowFuse(MARKET_ID);
        collateralFuse = new AaveV4CollateralFuse(MARKET_ID);

        vaultMock = new PlasmaVaultMock(address(supplyFuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(oracle));

        token = new ERC20Mock("Token One", "TK1", 18);
        token2 = new ERC20Mock("Token Two", "TK2", 8);

        spoke = new MockAaveV4Spoke();
        spoke.addReserve(RESERVE_ID_1, address(token));

        spoke2 = new MockAaveV4Spoke();
        spoke2.addReserve(RESERVE_ID_2, address(token2));

        // Fund spokes
        token.mint(address(spoke), 100_000_000e18);
        token2.mint(address(spoke2), 100_000_000e8);

        // Set prices
        oracle.setAssetPrice(address(token), TOKEN_PRICE);
        oracle.setAssetPrice(address(token2), TOKEN2_PRICE);

        // Grant reserves: (spoke, 1) borrowable, (spoke2, 2) plain
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke2), RESERVE_ID_2, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // Label
        vm.label(address(balanceFuse), "AaveV4BalanceFuse");
        vm.label(address(vaultMock), "PlasmaVaultMock");
        vm.label(address(spoke), "MockSpoke1");
        vm.label(address(spoke2), "MockSpoke2");
    }

    // ============ Constructor Tests ============

    function testShouldDeployWithValidParameters() public view {
        assertEq(balanceFuse.VERSION(), address(balanceFuse));
        assertEq(balanceFuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldRevertWhenMarketIdIsZero() public {
        vm.expectRevert(AaveV4BalanceFuse.AaveV4BalanceFuseInvalidMarketId.selector);
        new AaveV4BalanceFuse(0);
    }

    // ============ Balance Tests ============

    function testShouldReturnZeroWhenNoSubstrates() public {
        // given - new vault with no substrates
        PlasmaVaultMock emptyVault = new PlasmaVaultMock(address(supplyFuse), address(balanceFuse));
        emptyVault.setPriceOracleMiddleware(address(oracle));

        // when/then
        uint256 balance = emptyVault.balanceOf();
        assertEq(balance, 0);
    }

    function testShouldCalculateBalanceAfterSupply() public {
        // given - supply 1000 tokens at $1 each = $1000
        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - $1000 in WAD (18 decimals)
        assertEq(balance, 1_000e18, "Balance should be $1000 in WAD");
    }

    function testShouldCalculateBalanceAfterSupplyAndBorrow() public {
        // given - supply 1000 tokens at $1 enabled as collateral, borrow 200 tokens at $1
        uint256 supplyAmount = 1_000e18;
        uint256 borrowAmount = 200e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);
        _enableCollateralOnSpoke(spoke, RESERVE_ID_1);
        _borrow(address(spoke), address(token), RESERVE_ID_1, borrowAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - net = supply - debt = $1000 - $200 = $800 in WAD
        assertEq(balance, 800e18, "Balance should be $800 (supply - debt) in WAD");
    }

    function testShouldCountDebtEvenWhenGrantLacksCanBorrow() public {
        // given - supply 1000 enabled as collateral, borrow 200, then the atomist revokes canBorrow (plain grant)
        uint256 supplyAmount = 1_000e18;
        uint256 borrowAmount = 200e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);
        _enableCollateralOnSpoke(spoke, RESERVE_ID_1);
        _borrow(address(spoke), address(token), RESERVE_ID_1, borrowAmount);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, false);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke2), RESERVE_ID_2, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - debt still subtracted
        assertEq(balance, 800e18, "Debt must be counted regardless of the canBorrow flag");
    }

    function testShouldNotDoubleCountDuplicateGrantVariants() public {
        // given - the same reserve granted twice with different flags
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, true, false);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        substrates[2] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, true, true);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - counted once
        assertEq(balance, 1_000e18, "Duplicate grant variants must be counted once");
    }

    function testShouldIgnoreNonReserveSubstrates() public {
        // given - a legacy address-style word mixed into the grant list
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(token));
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - no revert, only the reserve substrate counted
        assertEq(balance, 1_000e18);
    }

    function testShouldIgnoreNonCanonicalReserveWord() public {
        // given - a canonical grant plus the same pair with dirty reserved bits
        bytes32 canonical = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = bytes32(uint256(canonical) | 1);
        substrates[1] = canonical;
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);

        // when/then - counted exactly once, dirty word ignored
        assertEq(vaultMock.balanceOf(), 1_000e18);
    }

    function testShouldNotRevertWhenNonGrantedReserveHasOnlySupply() public {
        // given - supply on a reserve that is later revoked (assets hidden = conservative, no revert)
        uint256 reserveId3 = 3;
        ERC20Mock token3 = new ERC20Mock("Token Three", "TK3", 6);
        spoke.addReserve(reserveId3, address(token3));
        oracle.setAssetPrice(address(token3), 1e8);

        bytes32[] memory both = new bytes32[](2);
        both[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        both[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), reserveId3, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, both);
        token3.mint(address(vaultMock), 500e6);
        _supply(address(spoke), address(token3), reserveId3, 500e6);

        bytes32[] memory onlyOne = new bytes32[](1);
        onlyOne[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        vaultMock.grantMarketSubstrates(MARKET_ID, onlyOne);

        // when/then
        assertEq(vaultMock.balanceOf(), 0, "hidden supply is simply not counted");
    }

    function testShouldSkipGrantedReserveIdNotListedOnSpoke() public {
        // given - the atomist pre-granted reserve 9 which the spoke has not listed yet
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), 9, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);

        // when/then - no revert, the unlisted id contributes nothing
        assertEq(vaultMock.balanceOf(), 1_000e18);
    }

    function testShouldSkipReservesWithNoPosition() public {
        // given - spoke has reserve but no position for vault
        // (already configured in setUp, just no supply/borrow)

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - should return 0 (no positions)
        assertEq(balance, 0, "Balance should be 0 when no positions exist");
    }

    function testShouldNotQueryPriceForReservesWithoutPosition() public {
        // given - token2 has no price (would revert if queried), vault only has a position in token
        oracle.setAssetPrice(address(token2), 0);
        uint256 supplyAmount = 1_000e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);

        // when/then - no revert
        uint256 balance = vaultMock.balanceOf();
        assertEq(balance, 1_000e18);
    }

    function testShouldRevertWhenPriceIsZero() public {
        // given - supply tokens, then set price to 0
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);
        _supply(address(spoke), address(token), RESERVE_ID_1, amount);

        oracle.setAssetPrice(address(token), 0);

        // when/then
        vm.expectRevert(Errors.UnsupportedQuoteCurrencyFromOracle.selector);
        vaultMock.balanceOf();
    }

    function testShouldConvertToCorrectDecimals() public {
        // given - supply 100 token2 (8 decimals) at $2000 each = $200,000
        uint256 supplyAmount = 100e8;
        token2.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke2), address(token2), RESERVE_ID_2, supplyAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - $200,000 in WAD (18 decimals)
        assertEq(balance, 200_000e18, "Balance should be $200,000 in WAD for 8-decimal token");
    }

    function testShouldHandleDifferentTokenDecimals() public {
        // given - supply both tokens
        uint256 amount1 = 1_000e18; // 1000 TK1 @ $1 = $1000
        uint256 amount2 = 5e8; // 5 TK2 @ $2000 = $10,000
        token.mint(address(vaultMock), amount1);
        token2.mint(address(vaultMock), amount2);

        _supply(address(spoke), address(token), RESERVE_ID_1, amount1);
        _supply(address(spoke2), address(token2), RESERVE_ID_2, amount2);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - $1,000 + $10,000 = $11,000
        assertEq(balance, 11_000e18, "Balance should sum both token values correctly");
    }

    function testShouldCalculateBalanceForMultipleSpokes() public {
        // given - supply to both spokes
        uint256 amount1 = 500e18; // 500 @ $1 = $500
        uint256 amount2 = 2e8; // 2 @ $2000 = $4000
        token.mint(address(vaultMock), amount1);
        token2.mint(address(vaultMock), amount2);

        _supply(address(spoke), address(token), RESERVE_ID_1, amount1);
        _supply(address(spoke2), address(token2), RESERVE_ID_2, amount2);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - $500 + $4000 = $4500
        assertEq(balance, 4_500e18, "Balance should aggregate across multiple Spokes");
    }

    function testShouldCalculateBalanceForMultipleReservesInSpoke() public {
        // given - add a second reserve to spoke1
        uint256 reserveId3 = 3;
        ERC20Mock token3 = new ERC20Mock("Token Three", "TK3", 6);
        spoke.addReserve(reserveId3, address(token3));
        token3.mint(address(spoke), 100_000_000e6);
        oracle.setAssetPrice(address(token3), 1e8); // $1

        // Re-grant substrates to include the new reserve
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke2), RESERVE_ID_2, false, false);
        substrates[2] = AaveV4SubstrateLib.encodeReserve(address(spoke), reserveId3, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // Supply to both reserves in spoke1
        uint256 amount1 = 100e18; // 100 TK1 @ $1 = $100
        uint256 amount3 = 500e6; // 500 TK3 @ $1 = $500
        token.mint(address(vaultMock), amount1);
        token3.mint(address(vaultMock), amount3);

        _supply(address(spoke), address(token), RESERVE_ID_1, amount1);
        _supply(address(spoke), address(token3), reserveId3, amount3);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - $100 + $500 = $600
        assertEq(balance, 600e18, "Balance should aggregate multiple reserves in same Spoke");
    }

    function testShouldOnlyCountGrantedReserveOfDuplicateAsset() public {
        // given - the same underlying listed twice on spoke1; both hold positions, only reserve 1 granted
        uint256 duplicateReserveId = 4;
        spoke.addReserve(duplicateReserveId, address(token));
        token.mint(address(vaultMock), 300e18);
        _supply(address(spoke), address(token), RESERVE_ID_1, 100e18);

        bytes32[] memory both = new bytes32[](2);
        both[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        both[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), duplicateReserveId, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, both);
        _supply(address(spoke), address(token), duplicateReserveId, 200e18);
        assertEq(vaultMock.balanceOf(), 300e18, "Both granted reserves counted");

        // when - revoke reserve 4
        bytes32[] memory onlyOne = new bytes32[](1);
        onlyOne[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, true);
        vaultMock.grantMarketSubstrates(MARKET_ID, onlyOne);

        // then - position on the revoked reserve is not visible (documented behaviour)
        assertEq(vaultMock.balanceOf(), 100e18, "Only the granted reserve is counted");
    }

    function testShouldValueNonCollateralSupplyWhenDebtExceedsSupply() public {
        // given - supply 100 tokens at $1 = $100 (not enabled as collateral), borrow 500 tokens at $1 = $500
        uint256 supplyAmount = 100e18;
        uint256 borrowAmount = 500e18;
        token.mint(address(vaultMock), supplyAmount);

        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);
        _borrow(address(spoke), address(token), RESERVE_ID_1, borrowAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - no revert; supply that is not collateral is never seized, so it counts in full: 100 + max(0, 0 - 500)
        assertEq(balance, 100e18, "non-collateral supply survives a liquidation");
    }

    // ============ Per-spoke valuation (IL-9552) ============

    function testShouldNotLetUnderwaterSpokeFreezeTheMarket() public {
        // given - spoke A: $250k collateral, $300k debt; spoke B: $40k supply (net of the whole market: -$10k)
        _openUnderwaterSpokeA();
        _supplyToSpokeB(20e8);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - no revert; spoke A is floored at zero and does not lower spoke B
        assertEq(balance, 40_000e18, "only spoke B counts");
    }

    function testShouldNotChargeUnderwaterSpokeShortfallToHealthySpoke() public {
        // given - spoke A: $250k collateral, $300k debt; spoke B: $1.0M supply
        _openUnderwaterSpokeA();
        _supplyToSpokeB(500e8);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - $1.0M, not $950k: the $50k shortfall of spoke A is not charged to spoke B
        assertEq(balance, 1_000_000e18, "spoke B in full");
    }

    function testShouldCountNonCollateralSupplyOfUnderwaterSpokeInFull() public {
        // given - spoke A: $250k collateral, $300k debt and $100k of supply not enabled as collateral
        _openUnderwaterSpokeA();
        uint256 freeAmount = 100_000e18;
        freeToken.mint(address(vaultMock), freeAmount);
        _supply(address(spoke), address(freeToken), FREE_RESERVE_ID, freeAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - F + max(0, C - D) = $100k + max(0, $250k - $300k) = $100k, not $50k
        assertEq(balance, 100_000e18, "free supply is not netted against the shortfall");
    }

    function testShouldReturnZeroWhenOnlySpokeIsUnderwater() public {
        // given - spoke A alone: $250k collateral, $300k debt
        _openUnderwaterSpokeA();

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - no revert, the spoke is floored at zero
        assertEq(balance, 0, "underwater spoke contributes zero");
    }

    function testShouldValueHealthySpokeNextToAnotherSpoke() public {
        // given - spoke A healthy: $400k collateral, $300k debt, $100k free supply; spoke B: $40k supply
        _setUpSpokeA();
        _openSpokeAPosition();
        uint256 freeAmount = 100_000e18;
        freeToken.mint(address(vaultMock), freeAmount);
        _supply(address(spoke), address(freeToken), FREE_RESERVE_ID, freeAmount);
        _supplyToSpokeB(20e8);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - unchanged net value: $100k + ($400k - $300k) + $40k
        assertEq(balance, 240_000e18, "healthy spokes keep their net value");
    }

    function testShouldValueSpokeAtFreeSupplyWhenCollateralGrantRevoked() public {
        // given - healthy spoke A ($400k collateral, $300k debt) and spoke B ($40k supply)
        _setUpSpokeA();
        _openSpokeAPosition();
        _supplyToSpokeB(20e8);
        assertEq(vaultMock.balanceOf(), 140_000e18, "before the revoke");

        // when - the atomist revokes the collateral reserve of spoke A; its debt stays visible
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke2), RESERVE_ID_2, false, false);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), DEBT_RESERVE_ID, false, true);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // then - no revert; spoke A shows only debt and is floored at zero (understated, never overstated)
        assertEq(vaultMock.balanceOf(), 40_000e18, "spoke A without visible collateral counts zero");
    }

    function testShouldNotDoubleCountDuplicateGrantsWithinSpoke() public {
        // given - healthy spoke A with its collateral and debt reserves granted twice and an unlisted reserve id
        _setUpSpokeA();
        _openSpokeAPosition();
        bytes32[] memory substrates = new bytes32[](6);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, true, false);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke), DEBT_RESERVE_ID, false, true);
        substrates[2] = AaveV4SubstrateLib.encodeReserve(address(spoke), 9, false, false);
        substrates[3] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, false, false);
        substrates[4] = AaveV4SubstrateLib.encodeReserve(address(spoke), DEBT_RESERVE_ID, true, true);
        substrates[5] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, true, true);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - each reserve counted once ($400k - $300k), the unlisted id contributes nothing
        assertEq(balance, 100_000e18, "duplicates counted once");
    }

    function testShouldReadCollateralStatusOnlyForSuppliedReserves() public {
        // given - healthy spoke A: collateral reserve with supply, debt reserve without supply
        _setUpSpokeA();
        _openSpokeAPosition();

        // then - the collateral flag is read for the supplied reserve only
        vm.expectCall(
            address(spoke),
            abi.encodeCall(IAaveV4Spoke.getUserReserveStatus, (RESERVE_ID_1, address(vaultMock))),
            1
        );
        vm.expectCall(
            address(spoke),
            abi.encodeCall(IAaveV4Spoke.getUserReserveStatus, (DEBT_RESERVE_ID, address(vaultMock))),
            0
        );

        // when
        assertEq(vaultMock.balanceOf(), 100_000e18);
    }

    function testShouldRoundSupplyDownAndDebtUpAtFractionalPrice() public {
        // given - collateral supply and debt on one reserve at $1.23456789; both amounts leave a remainder
        uint256 price = 123_456_789;
        oracle.setAssetPrice(address(token), price);
        uint256 supplyAmount = 1_000e18 + 3;
        uint256 borrowAmount = 200e18 + 5;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);
        _enableCollateralOnSpoke(spoke, RESERVE_ID_1);
        _borrow(address(spoke), address(token), RESERVE_ID_1, borrowAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - supply value rounded down, debt value rounded up (18 + 8 price decimals -> divide by 1e8)
        uint256 supplyValueDown = (supplyAmount * price) / 1e8; // ...890000000000000000003.70 -> ...003
        uint256 debtValueUp = Math.ceilDiv(borrowAmount * price, 1e8); // ...578000000000000000006.17 -> ...007
        assertEq(balance, supplyValueDown - debtValueUp, "directional rounding");
        assertEq(balance, 987_654_311_999_999_999_996, "exact value");

        // and - the nearest rounding of the net (...997.53 -> ...998) is at most 2 wei higher, never lower
        uint256 nearestNet = uint256(
            IporMath.convertToWadInt((int256(supplyAmount) - int256(borrowAmount)) * int256(price), 18 + 8)
        );
        assertEq(nearestNet - balance, 2, "2 wei WAD below the nearest rounding of the net");
    }

    function testFuzzShouldNeverValueHealthyReserveAboveNearestRoundedNet(
        uint256 supplyAmount_,
        uint256 borrowAmount_,
        uint256 price_
    ) public {
        // given - collateral supply and debt (debt <= supply) on one reserve at an arbitrary 8-decimal price
        supplyAmount_ = bound(supplyAmount_, 1, 50_000_000e18);
        borrowAmount_ = bound(borrowAmount_, 0, supplyAmount_);
        price_ = bound(price_, 1, 1_000_000e8);
        oracle.setAssetPrice(address(token), price_);
        token.mint(address(vaultMock), supplyAmount_);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount_);
        _enableCollateralOnSpoke(spoke, RESERVE_ID_1);
        if (borrowAmount_ > 0) {
            _borrow(address(spoke), address(token), RESERVE_ID_1, borrowAmount_);
        }

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - never above the nearest rounding of the net, at most 2 wei WAD below it
        uint256 nearestNet = uint256(
            IporMath.convertToWadInt((int256(supplyAmount_) - int256(borrowAmount_)) * int256(price_), 18 + 8)
        );
        assertLe(balance, nearestNet, "never above the nearest rounding");
        assertLe(nearestNet - balance, 2, "at most 2 wei WAD below");
    }

    // ============ Helpers ============

    /// @dev Spoke A (`spoke`): collateral reserve 1 (token), debt reserve 3 (debtToken, 6 decimals) and free-supply
    ///      reserve 4 (freeToken); spoke B (`spoke2`): reserve 2 (token2). The grants interleave the spokes, so the
    ///      per-spoke grouping has to collect substrates that are not adjacent.
    function _setUpSpokeA() private {
        debtToken = new ERC20Mock("Debt Token", "DBT", 6);
        freeToken = new ERC20Mock("Free Token", "FRE", 18);
        spoke.addReserve(DEBT_RESERVE_ID, address(debtToken));
        spoke.addReserve(FREE_RESERVE_ID, address(freeToken));
        debtToken.mint(address(spoke), 100_000_000e6);
        oracle.setAssetPrice(address(debtToken), 1e8);
        oracle.setAssetPrice(address(freeToken), 1e8);

        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(address(spoke), RESERVE_ID_1, true, false);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(address(spoke2), RESERVE_ID_2, false, false);
        substrates[2] = AaveV4SubstrateLib.encodeReserve(address(spoke), DEBT_RESERVE_ID, false, true);
        substrates[3] = AaveV4SubstrateLib.encodeReserve(address(spoke), FREE_RESERVE_ID, false, false);
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);
    }

    /// @dev Spoke A: $400k of token supplied and enabled as collateral through AaveV4CollateralFuse, $300k borrowed
    function _openSpokeAPosition() private {
        token.mint(address(vaultMock), COLLATERAL_AMOUNT);
        _supply(address(spoke), address(token), RESERVE_ID_1, COLLATERAL_AMOUNT);
        _enableCollateral(address(spoke), RESERVE_ID_1);
        _borrow(address(spoke), address(debtToken), DEBT_RESERVE_ID, DEBT_AMOUNT);
    }

    /// @dev Spoke A healthy ($400k collateral, $300k debt), then the collateral is repriced to $250k (net -$50k)
    function _openUnderwaterSpokeA() private {
        _setUpSpokeA();
        _openSpokeAPosition();
        assertEq(vaultMock.balanceOf(), 100_000e18, "spoke A healthy before the reprice");
        oracle.setAssetPrice(address(token), REPRICED_COLLATERAL_PRICE);
    }

    /// @dev Spoke B: plain supply of token2 ($2000 each)
    function _supplyToSpokeB(uint256 amount_) private {
        token2.mint(address(vaultMock), amount_);
        _supply(address(spoke2), address(token2), RESERVE_ID_2, amount_);
    }

    /// @dev Enables collateral through AaveV4CollateralFuse (the reserve must be granted with isCollateral)
    function _enableCollateral(address spoke_, uint256 reserveId_) private {
        vaultMock.execute(
            address(collateralFuse),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                AaveV4CollateralFuseEnterData({spoke: spoke_, reserveId: reserveId_})
            )
        );
    }

    /// @dev Enables collateral with the grant left as it is: the vault calls the Spoke itself, as
    ///      AaveV4CollateralFuse does under delegatecall
    function _enableCollateralOnSpoke(MockAaveV4Spoke spoke_, uint256 reserveId_) private {
        vm.prank(address(vaultMock));
        spoke_.setUsingAsCollateral(reserveId_, true, address(vaultMock));
    }

    function _supply(address spoke_, address asset_, uint256 reserveId_, uint256 amount_) private {
        vaultMock.execute(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256))",
                AaveV4SupplyFuseEnterData({
                    spoke: spoke_,
                    asset: asset_,
                    reserveId: reserveId_,
                    amount: amount_,
                    minShares: 0
                })
            )
        );
    }

    function _borrow(address spoke_, address asset_, uint256 reserveId_, uint256 amount_) private {
        vaultMock.execute(
            address(borrowFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256))",
                AaveV4BorrowFuseEnterData({
                    spoke: spoke_,
                    asset: asset_,
                    reserveId: reserveId_,
                    amount: amount_,
                    minShares: 0
                })
            )
        );
    }
}
