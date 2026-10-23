// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

import {
    HyperCoreMarginFuse,
    HyperCoreMarginFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";

import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";

import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @dev Minimal IPriceOracleMiddleware test double whose QUOTE_CURRENCY matches the real deployed
///      PriceOracleMiddleware (0x...0348) so it is accepted as a drop-in replacement.
contract HyperCoreTestPriceOracle is IPriceOracleMiddleware {
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

contract HyperCoreMarginFuseTest is Test {
    uint256 private constant MARKET_ID = 55;
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCoreTestPriceOracle private oracle;
    HyperCoreMarginFuse private marginFuse;
    HyperCoreBalanceFuse private balanceFuse;

    function setUp() public {
        core = HyperCoreTestHelper.etchPrecompiles(vm);
        coreWriter = HyperCoreTestHelper.etchCoreWriter(vm);

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

        oracle = new HyperCoreTestPriceOracle();
        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPriceOracleMiddleware(address(oracle));
        oracle.setAssetPriceWithDecimals(address(usdc), 1e8, 8);

        marginFuse = new HyperCoreMarginFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(marginFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();

        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );

        core.setCoreUserExists(address(vault), true);
        _grantUsdcAndCap(100_000e6);
    }

    function testEnterToPerpSendsExactPayloadAndEnqueuesLiveSnapshot() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );

        vm.expectEmit(true, true, true, true, address(vault));
        emit HyperCoreMarginFuse.HyperCoreMarginFuseEnter(address(marginFuse), 500e6, true);
        _execute(500e6, true);

        bytes memory expected = _expectPayload(HyperCoreLib.ACTION_USD_CLASS_TRANSFER, abi.encode(uint64(500e6), true));
        assertEq(coreWriter.lastAction(), expected, "CoreWriter payload mismatch");

        (uint64 pendingUntil, , , uint8 actionClass, , , bytes32 payloadHash, uint256 cachedValueWad) = _readPending();
        assertTrue(pendingUntil > 0);
        assertEq(actionClass, uint8(HyperCorePendingLib.ActionClass.Transfer));
        assertEq(payloadHash, keccak256(HyperCoreLib.encodeUsdClassTransfer(500e6, true)));
        // Live spot balance 1000 USDC @ $1 => S = 1000e18.
        assertEq(cachedValueWad, 1_000e18);
    }

    function testEnterToSpotUsesWithdrawableAndSendsPayload() public {
        core.setWithdrawable(address(vault), 500e6);
        _execute(300e6, false);

        bytes memory expected = _expectPayload(HyperCoreLib.ACTION_USD_CLASS_TRANSFER, abi.encode(uint64(300e6), false));
        assertEq(coreWriter.lastAction(), expected);
    }

    function testEnterRevertsWhenAccountNotActivated() public {
        core.setCoreUserExists(address(vault), false);
        vm.expectRevert(HyperCoreMarginFuse.HyperCoreMarginFuseAccountNotActivated.selector);
        _execute(1e6, true);
    }

    function testEnterRevertsOnZeroAmount() public {
        vm.expectRevert(HyperCoreMarginFuse.HyperCoreMarginFuseZeroAmount.selector);
        _execute(0, true);
    }

    function testEnterRevertsWhenUsdcNotGranted() public {
        // Overwrite the grant set in setUp with only the cap (no SpotToken grant).
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6, uint240(100_000e6)
        );
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(HyperCoreMarginFuse.HyperCoreMarginFuseUsdcNotGranted.selector);
        _execute(1e6, true);
    }

    function testEnterRevertsOnUsdcTokenMismatch() public {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, makeAddr("wrongUsdc"));
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6, uint240(100_000e6)
        );
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(HyperCoreMarginFuse.HyperCoreMarginFuseUsdcTokenMismatch.selector);
        _execute(1e6, true);
    }

    /// @dev Hyperliquid routes HyperCore token 0 (USDC) through a CoreDepositWallet on mainnet, so
    ///      `tokenInfo(0).evmContract` may be that wallet's address rather than the USDC ERC20 itself.
    ///      The fuse must accept the grant when `wallet.token() == grantedEvmAsset`, without requiring
    ///      plain address equality.
    function testEnterAcceptsUsdcViaDepositWallet() public {
        MockCoreDepositWallet wallet = new MockCoreDepositWallet(address(usdc));
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(wallet),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );

        core.setWithdrawable(address(vault), 500e6);
        _execute(300e6, false);

        bytes memory expected = _expectPayload(HyperCoreLib.ACTION_USD_CLASS_TRANSFER, abi.encode(uint64(300e6), false));
        assertEq(coreWriter.lastAction(), expected, "margin transfer still proceeds via the wallet-backed grant");
    }

    function testEnterRevertsWhenCapUnset() public {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(HyperCoreMarginFuse.HyperCoreMarginFuseCapUnset.selector);
        _execute(1e6, true);
    }

    function testEnterRevertsWhenCapZero() public {
        _grantUsdcAndCap(0);
        vm.expectRevert(HyperCoreMarginFuse.HyperCoreMarginFuseCapUnset.selector);
        _execute(1e6, true);
    }

    function testEnterRevertsWhenExceedingCap() public {
        _grantUsdcAndCap(1_000e6);
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000_000e8, hold: 0, entryNtl: 0})
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreMarginFuse.HyperCoreMarginFuseExceedsCap.selector, uint64(2_000e6), uint240(1_000e6)
            )
        );
        _execute(2_000e6, true);
    }

    function testEnterRevertsWhenSpotBalanceInsufficient() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 10e8, hold: 0, entryNtl: 0})
        );

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreMarginFuse.HyperCoreMarginFuseInsufficientSpotBalance.selector, 10e8, 500e8)
        );
        _execute(500e6, true);
    }

    function testEnterRevertsWhenWithdrawableInsufficient() public {
        core.setWithdrawable(address(vault), 10e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreMarginFuse.HyperCoreMarginFuseInsufficientWithdrawable.selector, uint64(10e6), uint64(500e6)
            )
        );
        _execute(500e6, false);
    }

    function testEnterRevertsOnZeroWindowConfig() public {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6, uint240(100_000e6)
        );
        substrates[2] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 0);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
        core.setWithdrawable(address(vault), 500e6);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreMarginFuse.HyperCoreMarginFuseInvalidWindow.selector, uint240(0))
        );
        _execute(100e6, false);
    }

    function testSecondMarginActionInSameExecuteReverts() public {
        core.setWithdrawable(address(vault), 500e6);
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(marginFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,bool))", HyperCoreMarginFuseEnterData({usd6: 100e6, toPerp: false})
            )
        });
        actions[1] = FuseAction({
            fuse: address(marginFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,bool))", HyperCoreMarginFuseEnterData({usd6: 100e6, toPerp: false})
            )
        });

        vm.expectRevert(
            abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, uint64(block.timestamp + 2))
        );
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    /// @dev C = S here (margin transfers stay on Core, no in-transit credit/debit), so totalAssets()
    ///      and the share supply must be unchanged across the execute() that performs the transfer.
    function testMarginTransferIsNavNeutralAcrossExecute() public {
        core.setWithdrawable(address(vault), 500e6);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();

        _execute(200e6, false);

        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 1, "margin transfer must be NAV-neutral (C = S)");
        assertEq(vault.totalSupply(), totalSupplyBefore, "no shares minted by execute()");
    }

    /// @dev Regression (IL-8915): a USDC `weiDecimals` outside [6, 18] must fail closed instead of mis-scaling.
    function testEnterToPerpRevertsOnUnexpectedUsdcScale() public {
        core.setSpotBalance(
            address(vault),
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 5,
                evmExtraWeiDecimals: -2
            })
        );

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreMarginFuse.HyperCoreMarginFuseUnexpectedUsdcScale.selector, uint8(5))
        );
        _execute(100e6, true);

        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 19,
                evmExtraWeiDecimals: -2
            })
        );

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreMarginFuse.HyperCoreMarginFuseUnexpectedUsdcScale.selector, uint8(19))
        );
        _execute(100e6, true);
    }

    /// @dev Boundary: `weiDecimals == 6` is accepted (factor 1).
    function testEnterToPerpAcceptsUsdcScaleSix() public {
        core.setSpotBalance(
            address(vault),
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.SpotBalance({total: 1e6, hold: 0, entryNtl: 0})
        );
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 6,
                evmExtraWeiDecimals: -2
            })
        );

        _execute(1e6, true);

        assertEq(
            coreWriter.lastAction(),
            _expectPayload(HyperCoreLib.ACTION_USD_CLASS_TRANSFER, abi.encode(uint64(1e6), true))
        );
    }

    /// @dev Boundary: `weiDecimals == 18` is accepted (factor 1e12).
    function testEnterToPerpAcceptsUsdcScaleEighteen() public {
        core.setSpotBalance(
            address(vault),
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.SpotBalance({total: 1e18, hold: 0, entryNtl: 0})
        );
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(usdc),
                szDecimals: 8,
                weiDecimals: 18,
                evmExtraWeiDecimals: -2
            })
        );

        _execute(1e6, true);

        assertEq(
            coreWriter.lastAction(),
            _expectPayload(HyperCoreLib.ACTION_USD_CLASS_TRANSFER, abi.encode(uint64(1e6), true))
        );
    }

    /// @dev Regression (IL-8526): margin moves (spot <-> perp) are atomic inside Core, so they carry no
    ///      cross-domain effect and keep settling purely by time + L1 block.
    function testMarginTransferHasNoEffectAndSettlesByTime() public {
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        _execute(500e6, true);

        assertEq(uint8(uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 6)))), 0, "no effect kind");
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 8))), 0, "no expected balance");

        (uint64 pendingUntil, , , , , , , ) = _readPending();
        vm.warp(pendingUntil);
        core.setL1BlockNumber(core.getL1BlockNumber() + 1);
        // Time + L1 gates alone open the gate: a follow-up margin action is accepted.
        _execute(100e6, true);
    }

    function _grantUsdcAndCap(uint256 capUsd6_) private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6, uint240(capUsd6_)
        );
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
    }

    function _execute(uint64 usd6_, bool toPerp_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(marginFuse),
            data: abi.encodeWithSignature(
                "enter((uint64,bool))", HyperCoreMarginFuseEnterData({usd6: usd6_, toPerp: toPerp_})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _expectPayload(uint24 actionId_, bytes memory fields_) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(1)), bytes3(actionId_), fields_);
    }

    function _readPending()
        private
        view
        returns (
            uint64 pendingUntil,
            uint64 enqueuedL1Block,
            uint64 enqueuedEvmBlock,
            uint8 actionClass,
            uint8 settlementMode,
            uint24 actionId,
            bytes32 payloadHash,
            uint256 cachedValueWad
        )
    {
        bytes32 slot0 = vm.load(address(vault), PENDING_SLOT);
        pendingUntil = uint64(uint256(slot0));
        enqueuedL1Block = uint64(uint256(slot0) >> 64);
        enqueuedEvmBlock = uint64(uint256(slot0) >> 128);
        actionClass = uint8(uint256(slot0) >> 192);
        settlementMode = uint8(uint256(slot0) >> 200);

        bytes32 slot1 = vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 1));
        actionId = uint24(uint256(slot1) >> 64);

        payloadHash = vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 2));

        cachedValueWad = uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 4)));
    }
}
