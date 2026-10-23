// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreOrderFuse,
    HyperCoreOrderFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";
import {UniversalReader, ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";

import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";

import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @dev Minimal `IPriceOracleMiddleware` test double whose `QUOTE_CURRENCY` matches the real
///      deployed `PriceOracleMiddleware` (`0x...0348`) so it is accepted as a drop-in replacement
///      by `PlasmaVaultGovernance.setPriceOracleMiddleware`. Mirrors the fixture used by the other
///      HyperCore fuse tests.
contract HyperCorePendingReaderTestOracle is IPriceOracleMiddleware {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public priceDecimals;

    function setAssetPriceWithDecimals(address asset_, uint256 price_, uint256 decimals_) external {
        prices[asset_] = price_;
        priceDecimals[asset_] = decimals_;
    }

    function getAssetPrice(address asset_) external view returns (uint256 assetPrice, uint256 decimals) {
        assetPrice = prices[asset_];
        decimals = priceDecimals[asset_];
    }

    function getAssetsPrices(
        address[] calldata assets_
    ) external view returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        assetPrices = new uint256[](assets_.length);
        decimalsList = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            assetPrices[i] = prices[assets_[i]];
            decimalsList[i] = priceDecimals[assets_[i]];
        }
    }

    function getSourceOfAssetPrice(address) external pure returns (address) {
        return address(0);
    }

    function setAssetsPricesSources(address[] calldata, address[] calldata) external {}

    // solhint-disable-next-line func-name-mixedcase
    function QUOTE_CURRENCY() external pure returns (address) {
        return address(0x0000000000000000000000000000000000000348);
    }

    // solhint-disable-next-line func-name-mixedcase
    function QUOTE_CURRENCY_DECIMALS() external pure returns (uint256) {
        return 18;
    }
}

/// @dev `HyperCorePendingReader` is exercised through `PlasmaVault.read()` (the `UniversalReader`
///      delegatecall pattern) against a real minimal `PlasmaVault` wired with the HyperCore market,
///      mirroring the setup used by `HyperCoreDepositFuseTest`/`HyperCoreOrderFuseTest`, since the
///      reader inspects `HyperCorePendingLib`'s namespaced vault storage.
contract HyperCorePendingReaderTest is Test {
    uint256 private constant MARKET_ID = 55;
    uint32 private constant PERP_ASSET = 0;
    address private constant L1_BLOCK_NUMBER_PRECOMPILE = address(0x809);

    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCorePendingReaderTestOracle private oracle;
    HyperCoreDepositFuse private depositFuse;
    HyperCoreOrderFuse private orderFuse;
    HyperCoreBalanceFuse private balanceFuse;
    MockCoreDepositWallet private depositWallet;
    HyperCorePendingReader private reader;

    function setUp() public {
        core = HyperCoreTestHelper.etchPrecompiles(vm);
        coreWriter = HyperCoreTestHelper.etchCoreWriter(vm);
        core.setL1BlockNumber(100);

        vm.startPrank(TestAddresses.ATOMIST);
        address withdrawManager;
        (vault, withdrawManager, usdc, ) = HyperCoreTestHelper.deployVaultWithHyperCoreMarket(TestAddresses.ATOMIST);
        IporFusionAccessManager accessManager = PlasmaVaultHelper.accessManagerOf(vault);
        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            vault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(vault)))
        );
        vm.stopPrank();

        oracle = new HyperCorePendingReaderTestOracle();
        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPriceOracleMiddleware(address(oracle));
        oracle.setAssetPriceWithDecimals(address(usdc), 1e8, 8);

        depositFuse = new HyperCoreDepositFuse(MARKET_ID);
        orderFuse = new HyperCoreOrderFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);
        reader = new HyperCorePendingReader();

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](2);
        fuses[0] = address(depositFuse);
        fuses[1] = address(orderFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();

        // Token 0 (USDC) is routed through the CoreDepositWallet on Hyperliquid mainnet.
        depositWallet = new MockCoreDepositWallet(address(usdc));
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(depositWallet),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );

        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        usdc.mint(address(vault), 1_000_000e6);
    }

    // ------------------------------------------------------------------
    // No action ever enqueued
    // ------------------------------------------------------------------

    function testPendingStateReturnsFalseAndZeroNonceWhenNoActionEverEnqueued() public {
        HyperCorePendingReader.PendingStateResult memory result = _readPendingState();

        assertFalse(result.actionPending, "nothing enqueued yet");
        assertTrue(result.actionSettled, "None class is vacuously settled");
        assertEq(result.state.actionNonce, 0, "nonce starts at zero");
        assertEq(result.state.actionClass, uint8(HyperCorePendingLib.ActionClass.None));
        assertTrue(result.l1BlockAvailable, "mock precompile is etched in setUp");
        assertEq(result.currentL1Block, 100);
        assertEq(result.currentTimestamp, uint64(block.timestamp));

        assertFalse(_readIsPending());
    }

    // ------------------------------------------------------------------
    // TIMING (transfer-class) action: pending -> settled, raw slot untouched
    // ------------------------------------------------------------------

    function testPendingStateReflectsTimingActionAfterDeposit() public {
        uint256 depositAmount = 1_000e6;
        _executeDeposit(depositAmount);

        HyperCorePendingReader.PendingStateResult memory result = _readPendingState();

        assertTrue(result.actionPending, "TIMING action still inside its window");
        assertFalse(result.actionSettled);
        assertEq(result.state.actionNonce, 1);
        assertEq(result.state.actionClass, uint8(HyperCorePendingLib.ActionClass.Transfer));
        assertEq(result.state.actionId, 0, "deposit fuse enqueues with actionId 0");
        assertEq(result.state.payloadHash, keccak256(abi.encode(HyperCoreLib.USDC_TOKEN, depositAmount)));

        assertTrue(_readIsPending());
    }

    function testPendingStateSettlesAfterWindowAndL1BlockAdvanceWhileRawSlotStaysNonZero() public {
        _executeDeposit(1_000e6);

        uint64 pendingUntil = _readPendingState().state.pendingUntil;

        vm.warp(pendingUntil);
        core.setL1BlockNumber(101);
        // The deposit settles only once its Core credit has landed (effect-based settlement).
        core.setCoreUserExists(address(vault), true);
        core.setSpotBalance(
            address(vault),
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );

        HyperCorePendingReader.PendingStateResult memory result = _readPendingState();

        assertFalse(result.actionPending, "window elapsed and L1 block advanced");
        assertTrue(result.actionSettled);
        // The raw ERC-7201 slot is only zeroed by the pre-hooks' settleIfReady()/clear(),
        // never by a read-only settlement check: inspecting actionClass alone would wrongly read this as pending.
        assertEq(
            result.state.actionClass,
            uint8(HyperCorePendingLib.ActionClass.Transfer),
            "raw slot not cleared by settlement"
        );
        assertEq(result.state.actionNonce, 1);

        assertFalse(_readIsPending());
    }

    // ------------------------------------------------------------------
    // Order action (TIMING-only since IL-8543): no pending record, only the mini-gate
    // ------------------------------------------------------------------

    function testPendingStateShowsNoRecordButOrderInFlightAfterOrder() public {
        core.setCoreUserExists(address(vault), true);
        _grantOrderMarket();
        _executeOrder();

        HyperCorePendingReader.PendingStateResult memory result = _readPendingState();

        assertFalse(result.actionPending, "orders create no pending record");
        assertTrue(result.actionSettled);
        assertEq(result.state.actionClass, uint8(HyperCorePendingLib.ActionClass.None));
        assertEq(result.state.actionNonce, 0);
        assertEq(result.state.lastOrderL1Block, 100, "mini-gate records the order's L1 block");
        assertFalse(_readIsPending());
        assertTrue(_readIsOrderInFlight(), "order is in flight until the next L1 block");

        core.setL1BlockNumber(101);
        assertFalse(_readIsOrderInFlight(), "mini-gate opens once a later L1 block is observed");
    }

    // ------------------------------------------------------------------
    // L1 block precompile unavailable (reader called directly, not through the vault)
    // ------------------------------------------------------------------

    function testPendingStateReportsL1BlockUnavailableWhenPrecompileNotEtched() public {
        // Etched only in setUp for this test's own reasoning: deploy a bare precompile-less
        // reader and call it directly (fresh, empty storage; no vault delegatecall involved) to
        // isolate the low-level staticcall fallback from the mock precompile infrastructure.
        vm.etch(L1_BLOCK_NUMBER_PRECOMPILE, "");

        HyperCorePendingReader standaloneReader = new HyperCorePendingReader();
        HyperCorePendingReader.PendingStateResult memory result = standaloneReader.pendingState();

        assertFalse(result.l1BlockAvailable, "precompile code removed");
        assertEq(result.currentL1Block, 0);
        assertFalse(result.actionPending, "fresh storage, nothing enqueued");
        assertTrue(result.actionSettled);
        assertEq(result.state.actionNonce, 0);
    }

    function testPendingStateFailsClosedWhenL1BlockProbeFailsWithRecord() public {
        _executeDeposit(1_000e6);
        HyperCorePendingReader.PendingStateResult memory beforeProbe = _readPendingState();
        vm.warp(beforeProbe.state.pendingUntil);
        vm.etch(L1_BLOCK_NUMBER_PRECOMPILE, "");

        HyperCorePendingReader.PendingStateResult memory result = _readPendingState();

        assertFalse(result.l1BlockAvailable, "probe failed");
        assertEq(result.currentL1Block, 0);
        assertTrue(result.actionPending, "record + failed probe fails closed");
        assertFalse(result.actionSettled);
        assertEq(result.state.actionNonce, 1);
        assertEq(result.state.actionClass, uint8(HyperCorePendingLib.ActionClass.Transfer));

        vm.expectRevert(abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, address(0x809)));
        this.readIsPendingExternal();
    }

    /// @dev External wrapper so `vm.expectRevert` observes the revert at a call boundary.
    function readIsPendingExternal() external view returns (bool) {
        return _readIsPending();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _executeDeposit(uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,uint256))",
                HyperCoreDepositFuseEnterData({tokenIndex: HyperCoreLib.USDC_TOKEN, amount: amount_})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _grantOrderMarket() private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodePerpMarket(PERP_ASSET, 10_000, false);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
    }

    function _executeOrder() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(orderFuse),
            data: abi.encodeWithSignature(
                "enter((uint32,bool,uint64,uint64,bool,uint8,uint128))",
                HyperCoreOrderFuseEnterData({
                    asset: PERP_ASSET,
                    isBuy: true,
                    limitPx: 100e8,
                    sz: 1000,
                    reduceOnly: false,
                    tif: 2,
                    cloid: 1
                })
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _readPendingState() private view returns (HyperCorePendingReader.PendingStateResult memory) {
        ReadResult memory readResult = UniversalReader(address(vault)).read(
            address(reader),
            abi.encodeCall(HyperCorePendingReader.pendingState, ())
        );
        return abi.decode(readResult.data, (HyperCorePendingReader.PendingStateResult));
    }

    function _readIsOrderInFlight() private view returns (bool) {
        ReadResult memory result = UniversalReader(address(vault)).read(
            address(reader),
            abi.encodeCall(HyperCorePendingReader.isOrderInFlight, ())
        );
        return abi.decode(result.data, (bool));
    }

    function _readIsPending() private view returns (bool) {
        ReadResult memory result = UniversalReader(address(vault)).read(
            address(reader),
            abi.encodeCall(HyperCorePendingReader.isActionPending, ())
        );
        return abi.decode(result.data, (bool));
    }
}
