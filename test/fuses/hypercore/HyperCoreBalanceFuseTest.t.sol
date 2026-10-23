// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreValuationLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreValuationLib.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {HyperCoreTestHelper} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockPriceOracle} from "../aave_v4/MockPriceOracle.sol";

/// @dev The balance fuse is delegatecalled by PlasmaVaultMock, so this helper writes the same
///      namespaced pending slot in that vault's storage context via its generic enter(bytes) path.
contract HyperCorePendingStateSetter {
    function enter(bytes calldata params) external {
        (bool active, uint256 cachedValue, uint8 actionClass) = abi.decode(params, (bool, uint256, uint8));

        HyperCorePendingLib.PendingAction storage pending = HyperCorePendingLib.get();
        if (!active) {
            delete pending.pendingUntil;
            delete pending.enqueuedL1Block;
            delete pending.enqueuedEvmBlock;
            delete pending.actionClass;
            delete pending.actionId;
            delete pending.payloadHash;
            delete pending.cachedValueWad;
            delete pending.actionNonce;
            return;
        }

        pending.pendingUntil = uint64(block.timestamp + 100);
        pending.enqueuedL1Block = 0;
        pending.enqueuedEvmBlock = uint64(block.number);
        pending.actionClass = actionClass;
        pending.actionId = 1;
        pending.payloadHash = bytes32(uint256(1));
        pending.cachedValueWad = cachedValue;
        pending.actionNonce = 1;
    }
}

contract HyperCoreBalanceFuseTest is Test {
    uint256 private constant MARKET_ID = 55;
    uint64 private constant USDC_INDEX = 0;
    address private constant SPOT_BALANCE_PRECOMPILE = address(0x801);
    address private constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE = address(0x80F);

    HyperCoreMockState private core;
    MockPriceOracle private oracle;
    HyperCoreBalanceFuse private balanceFuse;
    HyperCorePendingStateSetter private pendingSetter;
    PlasmaVaultMock private vault;
    address private spotAsset;

    function setUp() public {
        core = HyperCoreTestHelper.etchPrecompiles(vm);
        oracle = new MockPriceOracle();
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);
        pendingSetter = new HyperCorePendingStateSetter();
        vault = new PlasmaVaultMock(address(pendingSetter), address(balanceFuse));
        vault.setPriceOracleMiddleware(address(oracle));
        spotAsset = makeAddr("spotAsset");
    }

    function testUnactivatedVaultHasZeroValueWithoutReadingBalances() public {
        // The mock's default account-existence value is false.
        vm.expectCall(address(0x810), abi.encode(address(vault)));
        assertEq(vault.balanceOf(), 0);
    }

    function testSpotValueUsesTotalIncludingHeldAmountAndEightDecimalOraclePrice() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        _setSpotBalance(2e8, 15e7);
        oracle.setAssetPriceWithDecimals(spotAsset, 15e7, 8); // $1.50

        assertEq(vault.balanceOf(), 3e18);
    }

    function testSpotValueNormalizesEighteenDecimalOraclePrice() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        _setSpotBalance(125e6, 0); // 1.25 Core units at weiDecimals=8
        oracle.setAssetPriceWithDecimals(spotAsset, 2e18, 18); // $2.00

        assertEq(vault.balanceOf(), 2_500_000_000_000_000_000);
    }

    function testSignedPerpAccountValueOffsetsSpotValue() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        _setSpotBalance(3e8, 0);
        oracle.setAssetPriceWithDecimals(spotAsset, 1e8, 8);
        _setAccountValue(-1_250_000); // -$1.25 in USD6

        assertEq(vault.balanceOf(), 1_750_000_000_000_000_000);
    }

    function testNegativeCombinedValueRevertsWithSignedWadAmount() public {
        _activate();
        // IL-8923: perp equity is counted only with the SpotToken(0) grant and is priced with its oracle price.
        // Granting it at $1 keeps the expected signed amount of this test unchanged.
        _grantSpotToken(USDC_INDEX, spotAsset);
        oracle.setAssetPriceWithDecimals(spotAsset, 1e8, 8);
        _setAccountValue(-1_250_000);

        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreValuationLib.HyperCoreNegativeBalance.selector, int256(-1_250_000_000_000_000_000)
            )
        );
        vault.balanceOf();
    }

    function testPendingReturnsCachedConfirmedValue() public {
        _activate();
        _setPending(true, 9e18, 1);
        _setAccountValue(50_000_000); // Current live value is $50.

        assertEq(vault.balanceOf(), 9e18);
    }

    function testGrantedAssetRemainsPricingKeyWhenCoreMetadataDiffers() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        _setSpotBalance(1e8, 0);
        oracle.setAssetPriceWithDecimals(spotAsset, 3e8, 8);

        HyperCoreMockState.TokenInfo memory token = core.getTokenInfo(USDC_INDEX);
        token.evmContract = makeAddr("differentCoreAsset");
        core.setTokenInfo(USDC_INDEX, token);

        // Atomist's granted oracle key controls valuation; the fuse does not police mutable
        // grant/metadata consequences. This remains an operator configuration risk.
        assertEq(vault.balanceOf(), 3e18);
    }

    function testDuplicateSpotTokenSubstrateIsCountedOnlyOnce() public {
        _activate();
        bytes32 substrate = HyperCoreSubstrateLib.encodeSpotToken(USDC_INDEX, spotAsset);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = substrate;
        substrates[1] = substrate;
        vault.grantMarketSubstrates(MARKET_ID, substrates);
        _setSpotBalance(1e8, 0);
        oracle.setAssetPriceWithDecimals(spotAsset, 1e8, 8);

        assertEq(vault.balanceOf(), 1e18);
    }

    function testSpotPrecompileFailureUsesTypedError() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        _setSpotBalance(1e8, 0);
        core.setFail(SPOT_BALANCE_PRECOMPILE, true);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, SPOT_BALANCE_PRECOMPILE)
        );
        vault.balanceOf();
    }

    // IL-8923 (C-002): 0x80F accountValue is an amount of USDC, so perp equity is priced with the USDC oracle price.
    function testPerpEquityIsPricedWithUsdcOraclePrice() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        oracle.setAssetPriceWithDecimals(spotAsset, 9e7, 8); // USDC at $0.90
        _setAccountValue(100_000_000); // 100 USDC of perp equity

        assertEq(vault.balanceOf(), 90e18, "100 USDC of perp equity is worth $90 at $0.90");
    }

    // IL-8923 (C-002): spot USDC and perp USDC use one price, so a spot <-> perp move cannot change NAV in a depeg.
    function testSpotAndPerpUsdcShareOnePriceInDepeg() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        oracle.setAssetPriceWithDecimals(spotAsset, 9e7, 8); // USDC at $0.90
        _setSpotBalance(100e8, 0); // 100 USDC on spot (weiDecimals = 8)
        _setAccountValue(100_000_000); // 100 USDC of perp equity

        assertEq(vault.balanceOf(), 180e18, "200 USDC (spot + perp) at $0.90");
    }

    // IL-8923 (C-002), Pete D-009: without the SpotToken(0) grant perp equity (a donation or a revoked grant) is
    // left out of NAV and does not revert. The 0x80F read still happens; a granted non-USDC token is not a key.
    function testPerpEquityWithoutUsdcGrantIsNotCountedAndDoesNotRevert() public {
        _activate();
        _setAccountValue(50_000_000); // 50 USDC donated to the native perp account

        vm.expectCall(ACCOUNT_MARGIN_SUMMARY_PRECOMPILE, abi.encode(uint32(0), address(vault)));
        assertEq(vault.balanceOf(), 0, "no grant: perp equity not counted");

        address otherAsset = makeAddr("otherAsset");
        _grantSpotToken(1, otherAsset);
        oracle.setAssetPriceWithDecimals(otherAsset, 2e8, 8);
        assertEq(vault.balanceOf(), 0, "only the SpotToken(0) grant prices perp equity");
    }

    // IL-8923 (C-002): the perp pricing key is the SpotToken(0) grant wherever it sits in the substrate list, not
    // the first granted spot token. Spot balances stay 0, so only the perp leg reads a price.
    function testPerpEquityIsPricedWithSpotToken0KeyWhenNotFirstGrant() public {
        _activate();
        address otherAsset = makeAddr("otherAsset");
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(1, otherAsset);
        substrates[1] = HyperCoreSubstrateLib.encodeSpotToken(USDC_INDEX, spotAsset);
        vault.grantMarketSubstrates(MARKET_ID, substrates);
        oracle.setAssetPriceWithDecimals(otherAsset, 2e8, 8); // $2.00: must not price perp equity
        oracle.setAssetPriceWithDecimals(spotAsset, 9e7, 8); // USDC at $0.90
        _setAccountValue(100_000_000); // 100 USDC of perp equity

        assertEq(vault.balanceOf(), 90e18, "perp equity priced with the SpotToken(0) key granted second");
    }

    // IL-8923 (C-002): with the grant and non-zero perp equity a missing USDC price fails closed, like the spot leg.
    function testPerpEquityWithUsdcGrantAndZeroPriceReverts() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset); // the oracle has no price for spotAsset
        _setAccountValue(1_000_000);

        vm.expectRevert(Errors.UnsupportedQuoteCurrencyFromOracle.selector);
        vault.balanceOf();
    }

    // IL-8923 (C-002): with zero perp equity the USDC price is never read, so a vault without a USDC feed still values.
    function testZeroPerpEquityNeedsNoUsdcPrice() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset); // the oracle has no price for spotAsset
        _setAccountValue(0);

        vm.expectCall(address(oracle), abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector), 0);
        assertEq(vault.balanceOf(), 0);
    }

    // IL-8923 (C-002): negative perp equity is priced too, and the negative total still reverts with the priced amount.
    function testNegativePerpEquityIsScaledByUsdcPrice() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        oracle.setAssetPriceWithDecimals(spotAsset, 9e7, 8); // USDC at $0.90
        _setAccountValue(-1_250_000); // -1.25 USDC

        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreValuationLib.HyperCoreNegativeBalance.selector,
                int256(-1_125_000_000_000_000_000)
            )
        );
        vault.balanceOf();
    }

    // IL-8923 (C-002): |perp equity| * USDC price above int256 range reverts with the typed overflow error for token 0.
    function testPerpPriceOverflowReverts() public {
        _activate();
        _grantSpotToken(USDC_INDEX, spotAsset);
        int64 equity = type(int64).max;
        uint256 smallestOverflowingPrice = uint256(type(int256).max) / uint256(int256(equity)) + 1;
        oracle.setAssetPriceWithDecimals(spotAsset, smallestOverflowingPrice, 8);
        _setAccountValue(equity);

        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCorePriceOverflow.selector, uint64(0)));
        vault.balanceOf();
    }

    function _activate() private {
        core.setCoreUserExists(address(vault), true);
    }

    function _grantSpotToken(uint64 tokenIndex, address evmAsset) private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(tokenIndex, evmAsset);
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _setSpotBalance(uint64 total, uint64 hold) private {
        core.setSpotBalance(
            address(vault),
            USDC_INDEX,
            HyperCoreMockState.SpotBalance({total: total, hold: hold, entryNtl: 0})
        );
    }

    function _setAccountValue(int64 accountValue) private {
        core.setAccountMarginSummary(
            0,
            address(vault),
            HyperCoreMockState.AccountMarginSummary({
                accountValue: accountValue,
                marginUsed: 0,
                ntlPos: 0,
                rawUsd: accountValue
            })
        );
    }

    function _setPending(bool active, uint256 cachedValue, uint8 actionClass) private {
        vault.enter(abi.encode(active, cachedValue, actionClass));
    }

}
