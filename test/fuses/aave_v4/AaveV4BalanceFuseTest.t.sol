// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV4SubstrateLib} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";
import {AaveV4BalanceFuse} from "../../../contracts/fuses/aave_v4/AaveV4BalanceFuse.sol";
import {AaveV4SupplyFuse, AaveV4SupplyFuseEnterData} from "../../../contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {AaveV4BorrowFuse, AaveV4BorrowFuseEnterData} from "../../../contracts/fuses/aave_v4/AaveV4BorrowFuse.sol";
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

    AaveV4BalanceFuse public balanceFuse;
    AaveV4SupplyFuse public supplyFuse;
    AaveV4BorrowFuse public borrowFuse;
    PlasmaVaultMock public vaultMock;
    MockAaveV4Spoke public spoke;
    MockAaveV4Spoke public spoke2;
    MockPriceOracle public oracle;
    ERC20Mock public token; // 18 decimals, $1
    ERC20Mock public token2; // 8 decimals, $2000

    function setUp() public {
        // Deploy contracts
        oracle = new MockPriceOracle();
        balanceFuse = new AaveV4BalanceFuse(MARKET_ID);
        supplyFuse = new AaveV4SupplyFuse(MARKET_ID);
        borrowFuse = new AaveV4BorrowFuse(MARKET_ID);

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
        // given - supply 1000 tokens at $1, borrow 200 tokens at $1
        uint256 supplyAmount = 1_000e18;
        uint256 borrowAmount = 200e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);
        _borrow(address(spoke), address(token), RESERVE_ID_1, borrowAmount);

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - net = supply - debt = $1000 - $200 = $800 in WAD
        assertEq(balance, 800e18, "Balance should be $800 (supply - debt) in WAD");
    }

    function testShouldCountDebtEvenWhenGrantLacksCanBorrow() public {
        // given - supply 1000, borrow 200, then the atomist revokes canBorrow (plain grant)
        uint256 supplyAmount = 1_000e18;
        uint256 borrowAmount = 200e18;
        token.mint(address(vaultMock), supplyAmount);
        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);
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

    function testShouldRevertWhenDebtExceedsSupply() public {
        // given - supply 100 tokens at $1 = $100, borrow 500 tokens at $1 = $500
        // net = $100 - $500 = -$400, should revert with negative balance
        uint256 supplyAmount = 100e18;
        uint256 borrowAmount = 500e18;
        token.mint(address(vaultMock), supplyAmount);

        _supply(address(spoke), address(token), RESERVE_ID_1, supplyAmount);
        _borrow(address(spoke), address(token), RESERVE_ID_1, borrowAmount);

        // when/then - net is negative, should revert
        int256 expectedBalance = int256(supplyAmount) - int256(borrowAmount); // -400e18
        vm.expectRevert(
            abi.encodeWithSelector(AaveV4BalanceFuse.AaveV4BalanceFuseNegativeBalance.selector, expectedBalance)
        );
        vaultMock.balanceOf();
    }

    // ============ Helpers ============

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
