// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreValuationLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreValuationLib.sol";
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
