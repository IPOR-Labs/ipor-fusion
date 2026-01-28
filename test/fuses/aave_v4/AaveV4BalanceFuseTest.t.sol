// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
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
    uint256 public constant MARKET_ID = 43;
    uint256 public constant RESERVE_ID_1 = 1;
    uint256 public constant RESERVE_ID_2 = 2;

    // Prices in 8 decimals
    uint256 public constant TOKEN_PRICE = 1e8; // $1
    uint256 public constant TOKEN2_PRICE = 2000e8; // $2000

    AaveV4BalanceFuse public balanceFuse;
    AaveV4SupplyFuse public supplyFuse;
    AaveV4BorrowFuse public borrowFuse;
    PlasmaVaultMock public vaultMock;
    PlasmaVaultMock public supplyVaultMock;
    PlasmaVaultMock public borrowVaultMock;
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

        // Grant substrates
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = AaveV4SubstrateLib.encodeAsset(address(token));
        substrates[1] = AaveV4SubstrateLib.encodeAsset(address(token2));
        substrates[2] = AaveV4SubstrateLib.encodeSpoke(address(spoke));
        substrates[3] = AaveV4SubstrateLib.encodeSpoke(address(spoke2));
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

        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID_1,
                amount: supplyAmount,
                minShares: 0
            })
        );

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

        // Supply
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID_1,
                amount: supplyAmount,
                minShares: 0
            })
        );

        // Borrow via separate vault mock with borrow fuse
        borrowVaultMock = new PlasmaVaultMock(address(borrowFuse), address(balanceFuse));
        bytes32[] memory substrates = new bytes32[](4);
        substrates[0] = AaveV4SubstrateLib.encodeAsset(address(token));
        substrates[1] = AaveV4SubstrateLib.encodeAsset(address(token2));
        substrates[2] = AaveV4SubstrateLib.encodeSpoke(address(spoke));
        substrates[3] = AaveV4SubstrateLib.encodeSpoke(address(spoke2));
        borrowVaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // We need to borrow from same vault address, so use vaultMock.execute
        vaultMock.execute(
            address(borrowFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256))",
                AaveV4BorrowFuseEnterData({
                    spoke: address(spoke),
                    asset: address(token),
                    reserveId: RESERVE_ID_1,
                    amount: borrowAmount,
                    minShares: 0
                })
            )
        );

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - net = supply - debt = $1000 - $200 = $800 in WAD
        assertEq(balance, 800e18, "Balance should be $800 (supply - debt) in WAD");
    }

    function testShouldSkipReservesWithNoPosition() public {
        // given - spoke has reserve but no position for vault
        // (already configured in setUp, just no supply/borrow)

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - should return 0 (no positions)
        assertEq(balance, 0, "Balance should be 0 when no positions exist");
    }

    function testShouldRevertWhenPriceIsZero() public {
        // given - supply tokens, then set price to 0
        uint256 amount = 1_000e18;
        token.mint(address(vaultMock), amount);

        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID_1,
                amount: amount,
                minShares: 0
            })
        );

        oracle.setAssetPrice(address(token), 0);

        // when/then
        vm.expectRevert(Errors.UnsupportedQuoteCurrencyFromOracle.selector);
        vaultMock.balanceOf();
    }

    function testShouldConvertToCorrectDecimals() public {
        // given - supply 100 token2 (8 decimals) at $2000 each = $200,000
        uint256 supplyAmount = 100e8;
        token2.mint(address(vaultMock), supplyAmount);

        // Need a vault with spoke2 configured
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke2),
                asset: address(token2),
                reserveId: RESERVE_ID_2,
                amount: supplyAmount,
                minShares: 0
            })
        );

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

        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID_1,
                amount: amount1,
                minShares: 0
            })
        );

        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke2),
                asset: address(token2),
                reserveId: RESERVE_ID_2,
                amount: amount2,
                minShares: 0
            })
        );

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

        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID_1,
                amount: amount1,
                minShares: 0
            })
        );

        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke2),
                asset: address(token2),
                reserveId: RESERVE_ID_2,
                amount: amount2,
                minShares: 0
            })
        );

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

        // Re-grant substrates to include the new asset
        bytes32[] memory substrates = new bytes32[](5);
        substrates[0] = AaveV4SubstrateLib.encodeAsset(address(token));
        substrates[1] = AaveV4SubstrateLib.encodeAsset(address(token2));
        substrates[2] = AaveV4SubstrateLib.encodeAsset(address(token3));
        substrates[3] = AaveV4SubstrateLib.encodeSpoke(address(spoke));
        substrates[4] = AaveV4SubstrateLib.encodeSpoke(address(spoke2));
        vaultMock.grantMarketSubstrates(MARKET_ID, substrates);

        // Supply to both reserves in spoke1
        uint256 amount1 = 100e18; // 100 TK1 @ $1 = $100
        uint256 amount3 = 500e6; // 500 TK3 @ $1 = $500
        token.mint(address(vaultMock), amount1);
        token3.mint(address(vaultMock), amount3);

        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID_1,
                amount: amount1,
                minShares: 0
            })
        );

        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token3),
                reserveId: reserveId3,
                amount: amount3,
                minShares: 0
            })
        );

        // when
        uint256 balance = vaultMock.balanceOf();

        // then - $100 + $500 = $600
        assertEq(balance, 600e18, "Balance should aggregate multiple reserves in same Spoke");
    }

    function testShouldRevertWhenDebtExceedsSupply() public {
        // given - supply 100 tokens at $1 = $100, borrow 500 tokens at $1 = $500
        // net = $100 - $500 = -$400, should revert with negative balance
        uint256 supplyAmount = 100e18;
        uint256 borrowAmount = 500e18;
        token.mint(address(vaultMock), supplyAmount);

        // Supply
        vaultMock.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID_1,
                amount: supplyAmount,
                minShares: 0
            })
        );

        // Borrow via execute on borrow fuse
        vaultMock.execute(
            address(borrowFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256))",
                AaveV4BorrowFuseEnterData({
                    spoke: address(spoke),
                    asset: address(token),
                    reserveId: RESERVE_ID_1,
                    amount: borrowAmount,
                    minShares: 0
                })
            )
        );

        // when/then - net is negative, should revert
        int256 expectedBalance = int256(supplyAmount) - int256(borrowAmount); // -400e18
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveV4BalanceFuse.AaveV4BalanceFuseNegativeBalance.selector,
                expectedBalance
            )
        );
        vaultMock.balanceOf();
    }
}
