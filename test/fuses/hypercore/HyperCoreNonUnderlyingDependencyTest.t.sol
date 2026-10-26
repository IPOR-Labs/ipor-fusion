// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {HyperCoreEffectSettlementBase, MockEffectSettlementChainlinkFeed} from "./HyperCoreEffectSettlementBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {FeeManager} from "../../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {RecipientFee} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";
import {ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";
import {PrecompileLib} from "./simulation/src/PrecompileLib.sol";

/// @dev 8-decimal ERC20 standing in for a Core-linked token that is NOT the vault's underlying.
contract HyperCoreNonUnderlyingMockToken is ERC20 {
    constructor() ERC20("Non Underlying", "NUT") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }
}

/// @title HyperCoreNonUnderlyingDependencyTest
/// @notice IL-8937 (C-016): the market 55 -> market 7 dependency for a non-underlying Core-linked token.
///         After such a token returns from Core, only market 55 is refreshed by the capital-flow hook; market 7
///         (the EVM balance of the token) is refreshed in the same call only through the dependency graph.
///         The positive test proves the graph prices the next deposit on the full NAV, the negative twin
///         documents the NAV understatement when the graph is missing (README requirement).
///         IL-9199 (O-003): the opposite direction. An EVM -> Core deposit of the same token with the 55 -> 7 edge keeps
///         NAV flat and mints no performance fee; without the edge market 7 keeps the cached EVM balance, NAV is
///         overstated by exactly the in-transit credit (40 USDC), a performance fee is minted on that phantom gain and
///         the next depositor overpays until `updateMarketsBalances([7])`.
/// @dev Numbers: setUp holds 1,000,000 USDC. Token 9 (8 decimals) is priced at $2; Core holds 100 tokens,
///      20 are bridged back to the vault, so market 55 = 80 x $2 = 160 USDC and market 7 = 20 x $2 = 40 USDC.
contract HyperCoreNonUnderlyingDependencyTest is HyperCoreEffectSettlementBase {
    uint64 internal constant TOKEN = 9;
    uint256 internal constant ERC20_MARKET = UNDERLYING_MARKET_ID; // market 7
    uint64 internal constant CORE_BALANCE_WEI = 100e8;
    uint64 internal constant BRIDGED_WEI = 20e8;
    uint256 internal constant DEPOSIT = 100e6;
    /// @dev IL-9199: 20 tokens (8 decimals) deposited to Core = 40 USDC at $2
    uint64 internal constant DEPOSIT_WEI = 20e8;
    /// @dev 20% performance fee (`FeeManager` percentages use two decimals, 10000 = 100%)
    uint256 internal constant PERFORMANCE_FEE = 2000;
    /// @dev Vault shares have 8 decimals over the 6-decimals USDC
    uint256 internal constant ONE_SHARE = 1e8;
    uint256 internal constant SHARE_SCALE = 100;

    HyperCoreNonUnderlyingMockToken internal _token;
    FeeManager internal _feeManager;
    address internal _feeAccount;

    function testBridgedNonUnderlyingTokenIsPricedThroughDependency() public {
        _prepare(true);

        uint256 usdcIdle = _usdc.balanceOf(address(_vault));
        uint256 supplyBefore = _vault.totalSupply();
        // Independent NAV: idle USDC + 80 Core tokens x $2 + 20 EVM tokens x $2 (6-decimal USDC units).
        uint256 expectedNav = usdcIdle + 160e6 + 40e6;
        assertEq(expectedNav, 1_000_200e6, "independent NAV");

        uint256 shares = _userDeposit();

        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 160e6, "market 55 = 80 tokens x $2");
        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 40e6, "market 7 refreshed by the 55 -> 7 dependency");
        assertEq(shares, _sharesFor(DEPOSIT, supplyBefore, expectedNav), "shares priced on the full NAV");
    }

    function testWithoutDependencyMarketSevenStaysStale() public {
        _prepare(false);

        uint256 usdcIdle = _usdc.balanceOf(address(_vault));
        uint256 supplyBefore = _vault.totalSupply();
        // The tokens that returned to the EVM side are invisible: market 7 keeps its old cached value (0).
        uint256 understatedNav = usdcIdle + 160e6;
        assertEq(understatedNav, 1_000_160e6, "NAV understated by exactly the 40 USDC of bridged tokens");

        uint256 shares = _userDeposit();

        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 160e6, "market 55 refreshed by the hook");
        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 0, "market 7 is stale without the dependency");
        assertEq(_token.balanceOf(address(_vault)), BRIDGED_WEI, "the tokens are on the vault");
        assertEq(shares, _sharesFor(DEPOSIT, supplyBefore, understatedNav), "shares priced on the understated NAV");
        // The depositor received more shares than on the correct NAV (1,000,200e6): the understatement is the cost.
        assertGt(shares, _sharesFor(DEPOSIT, supplyBefore, usdcIdle + 200e6), "depositor buys cheap shares");
    }

    /// @notice IL-9199, with the 55 -> 7 edge: depositing 20 tokens (40 USDC) to Core keeps NAV flat and mints no fee.
    /// @dev Numbers: before the deposit market 55 = 100 x $2 = 200 USDC and market 7 = 20 x $2 = 40 USDC. `enter` moves
    ///      the 20 tokens to Core: market 55 caches 200 + 40 = 240 USDC while the credit is in transit, and the edge
    ///      refreshes market 7 to 0 in the same `execute`. NAV is unchanged, so no performance fee is minted.
    function testNonUnderlyingDepositWithDependencyKeepsNav() public {
        _prepareDeposit(true);
        uint256 navBefore = _vault.totalAssets();
        uint256 feeSharesBefore = _vault.balanceOf(_feeAccount);
        uint256 hwmBefore = _hwm();
        assertEq(hwmBefore, _vault.convertToAssets(10 ** _vault.decimals()), "precondition: HWM is the share price");

        _enterDeposit();

        assertTrue(_isPending(), "the deposit is pending");
        assertEq(_token.balanceOf(address(_vault)), 0, "the tokens left the vault");
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 240e6, "market 55 = 200 live + 40 in transit");
        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 0, "market 7 refreshed by the 55 -> 7 dependency");
        assertEq(_vault.totalAssets(), navBefore, "NAV unchanged");
        assertEq(_vault.balanceOf(_feeAccount), feeSharesBefore, "no performance fee");
        assertEq(_hwm(), hwmBefore, "HWM unchanged");

        _settle(2);
        assertEq(
            HyperCoreLib.spotBalance(address(_vault), TOKEN).total,
            CORE_BALANCE_WEI + DEPOSIT_WEI,
            "the credit landed on Core"
        );

        uint256 supplyBefore = _vault.totalSupply();
        uint256 shares = _userDeposit();

        assertFalse(_isPending(), "the hook settled the record");
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 240e6, "market 55 = 120 tokens x $2 live");
        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 0, "market 7 stays empty");
        assertEq(shares, _sharesFor(DEPOSIT, supplyBefore, navBefore), "shares priced on the true NAV");
    }

    /// @notice IL-9199, without the 55 -> 7 edge: the same deposit double counts the token until market 7 is refreshed.
    /// @dev Numbers: market 55 = 240 USDC (in-transit credit) while market 7 keeps its cached 40 USDC, so NAV is
    ///      overstated by exactly 40 USDC. The `execute` mints performance fee shares on that phantom gain and raises the
    ///      HWM, the next depositor receives fewer shares than at the true NAV, and `updateMarketsBalances([7])` restores
    ///      NAV while the HWM stays above the real share price.
    function testNonUnderlyingDepositWithoutDependencyDoubleCounts() public {
        _prepareDeposit(false);
        uint256 navBefore = _vault.totalAssets();
        uint256 supplyBefore = _vault.totalSupply();
        uint256 feeSharesBefore = _vault.balanceOf(_feeAccount);
        uint256 hwmBefore = _hwm();
        assertEq(hwmBefore, _vault.convertToAssets(10 ** _vault.decimals()), "precondition: HWM is the share price");

        // Independent expectation (FeeManager.calculateAndUpdatePerformanceFee; same formula as
        // HyperCoreCapitalFlowPerformanceFeeTest): the execute sees NAV + 40 USDC.
        uint256 phantomNav = navBefore + 40e6;
        uint256 preMintRate = Math.mulDiv(ONE_SHARE, phantomNav + 1, supplyBefore + SHARE_SCALE);
        assertGt(preMintRate, hwmBefore, "the phantom NAV is above the HWM");
        uint256 harvested = Math.mulDiv(supplyBefore, preMintRate - hwmBefore, preMintRate);
        uint256 expectedFeeShares = Math.mulDiv(harvested, PERFORMANCE_FEE, 10000);
        uint256 expectedHwm = Math.mulDiv(ONE_SHARE, phantomNav + 1, supplyBefore + expectedFeeShares + SHARE_SCALE);
        assertGt(expectedFeeShares, 0, "the phantom gain earns a fee");

        _enterDeposit();

        assertTrue(_isPending(), "the deposit is pending");
        assertEq(_token.balanceOf(address(_vault)), 0, "the tokens left the vault");
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 240e6, "market 55 = 200 live + 40 in transit");
        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 40e6, "market 7 is stale: the tokens are already on Core");
        assertEq(_vault.totalAssets(), phantomNav, "NAV overstated by exactly the credit");
        assertEq(
            _vault.balanceOf(_feeAccount) - feeSharesBefore,
            expectedFeeShares,
            "fee shares minted on the phantom gain"
        );
        assertGt(_hwm(), hwmBefore, "HWM raised by the phantom gain");
        assertEq(_hwm(), expectedHwm, "HWM is the post-mint phantom share price");

        _settle(2);
        assertEq(
            HyperCoreLib.spotBalance(address(_vault), TOKEN).total,
            CORE_BALANCE_WEI + DEPOSIT_WEI,
            "the credit landed on Core"
        );

        uint256 supplyBeforeUser = _vault.totalSupply();
        uint256 shares = _userDeposit();

        assertFalse(_isPending(), "the hook settled the record");
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 240e6, "market 55 = 120 tokens x $2 live");
        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 40e6, "market 7 is still stale");
        assertEq(shares, _sharesFor(DEPOSIT, supplyBeforeUser, phantomNav), "shares priced on the overstated NAV");
        assertLt(shares, _sharesFor(DEPOSIT, supplyBeforeUser, navBefore), "the depositor overpays");

        uint256[] memory marketSeven = new uint256[](1);
        marketSeven[0] = ERC20_MARKET;
        vm.prank(_atomist);
        _vault.updateMarketsBalances(marketSeven);

        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 0, "market 7 corrected");
        assertEq(_vault.totalAssets(), navBefore + DEPOSIT, "NAV is the true NAV again");
        assertLt(_vault.convertToAssets(10 ** _vault.decimals()), _hwm(), "the HWM stays above the real share price");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev Registers token 9, grants it in markets 55 and 7, optionally installs the 55 -> 7 dependency, puts 100
    ///      tokens on Core, refreshes, bridges 20 back to the vault and settles the effect without a refresh.
    function _prepare(bool withDependency_) internal {
        _registerAndGrantToken(withDependency_);
        _prepareBridge();
    }

    /// @dev Registers token 9 on the simulator, prices it at $2, grants it in markets 55 and 7 and optionally installs
    ///      the 55 -> 7 dependency.
    function _registerAndGrantToken(bool withDependency_) internal {
        _token = new HyperCoreNonUnderlyingMockToken();

        _hyperCore.registerTokenInfo(
            TOKEN,
            PrecompileLib.TokenInfo({
                name: "NUT",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(_token),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: 0
            })
        );

        MockEffectSettlementChainlinkFeed feed = new MockEffectSettlementChainlinkFeed(2e8, 8);
        address[] memory assets = new address[](1);
        assets[0] = address(_token);
        address[] memory sources = new address[](1);
        sources[0] = address(feed);
        vm.prank(_atomist);
        _priceManager.setAssetsPriceSources(assets, sources);

        // Full market 55 substrate list (grantMarketSubstrates replaces it): base set + token 9.
        bytes32[] memory substrates = new bytes32[](11);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        substrates[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        substrates[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        substrates[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        substrates[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        substrates[6] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        substrates[7] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6,
            1_000_000e6
        );
        substrates[8] = HyperCoreSubstrateLib.encodeSpotToken(TOKEN, address(_token));
        substrates[9] = HyperCoreSubstrateLib.encodeSendCap(TOKEN, type(uint128).max);
        substrates[10] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(TOKEN));

        bytes32[] memory marketSevenSubstrates = new bytes32[](1);
        marketSevenSubstrates[0] = bytes32(uint256(uint160(address(_token))));

        vm.startPrank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, substrates);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(ERC20_MARKET, marketSevenSubstrates);
        if (withDependency_) {
            uint256[] memory markets = new uint256[](1);
            markets[0] = MARKET_ID;
            uint256[][] memory dependencies = new uint256[][](1);
            dependencies[0] = new uint256[](1);
            dependencies[0][0] = ERC20_MARKET;
            PlasmaVaultGovernance(address(_vault)).updateDependencyBalanceGraphs(markets, dependencies);
        }
        vm.stopPrank();
    }

    function _prepareBridge() internal {
        // 100 tokens on Core, cached by an explicit refresh: market 55 = 100 x $2.
        CoreSimulatorLib.forceSpotBalance(address(_vault), TOKEN, CORE_BALANCE_WEI);
        _refreshAndTotalAssets();
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 200e6, "market 55 = 100 tokens x $2 before the bridge");
        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 0, "market 7 empty before the bridge");

        // Bridge 20 tokens Core -> EVM and let the effect land; no external refresh afterwards.
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_sendFuse),
            abi.encodeWithSelector(
                HyperCoreSendFuse.enterSendAsset.selector,
                HyperCoreSendFuseSendAssetData({
                    destination: HyperCoreLib.systemAddress(TOKEN),
                    sourceDex: HyperCoreLib.SPOT_DEX,
                    destinationDex: HyperCoreLib.SPOT_DEX,
                    tokenIndex: TOKEN,
                    amountWei: BRIDGED_WEI
                })
            )
        );
        _vault.execute(actions);
        _settle(2);
        ReadResult memory pending = _vault.read(
            address(new HyperCorePendingReader()),
            abi.encodeCall(HyperCorePendingReader.isActionPending, ())
        );
        assertFalse(abi.decode(pending.data, (bool)), "bridge settled");
        assertEq(_token.balanceOf(address(_vault)), BRIDGED_WEI, "20 tokens credited on the EVM side");
    }

    /// @dev IL-9199: 20% performance fee, token registered and granted (with or without the edge), the Core account
    ///      activated with 100 tokens, 20 tokens on the vault (`deal`, no Transfer event) and both markets refreshed:
    ///      market 55 = 200 USDC, market 7 = 40 USDC.
    function _prepareDeposit(bool withDependency_) internal {
        _feeAccount = PlasmaVaultGovernance(address(_vault)).getPerformanceFeeData().feeAccount;
        _feeManager = FeeManager(FeeAccount(_feeAccount).FEE_MANAGER());
        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: makeAddr("FEE_RECIPIENT"), feeValue: PERFORMANCE_FEE});
        vm.prank(_atomist);
        _feeManager.updatePerformanceFee(recipientFees);

        _registerAndGrantToken(withDependency_);

        // Activates the Core account (a non-USDC deposit into a missing account reverts) and holds 100 tokens on Core.
        CoreSimulatorLib.forceSpotBalance(address(_vault), TOKEN, CORE_BALANCE_WEI);
        deal(address(_token), address(_vault), DEPOSIT_WEI);

        uint256[] memory markets = new uint256[](2);
        markets[0] = MARKET_ID;
        markets[1] = ERC20_MARKET;
        vm.prank(_atomist);
        _vault.updateMarketsBalances(markets);

        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 200e6, "market 55 = 100 tokens x $2");
        assertEq(_vault.totalAssetsInMarket(ERC20_MARKET), 40e6, "market 7 = 20 tokens x $2");
        assertEq(_vault.totalAssets(), _usdc.balanceOf(address(_vault)) + 240e6, "NAV = idle USDC + 240");
    }

    function _enterDeposit() internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: TOKEN, amount: DEPOSIT_WEI})
            )
        );
        _vault.execute(actions);
    }

    function _hwm() internal view returns (uint256) {
        return _feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
    }

    function _userDeposit() internal returns (uint256 shares) {
        _usdc.mint(_user, DEPOSIT);
        vm.startPrank(_user);
        _usdc.approve(address(_vault), DEPOSIT);
        shares = _vault.deposit(DEPOSIT, _user);
        vm.stopPrank();
    }

    /// @dev ERC-4626 conversion with the vault's decimals offset, floor rounding: assets * (supply + 10^offset) / (nav + 1).
    function _sharesFor(uint256 assets_, uint256 supply_, uint256 nav_) internal view returns (uint256) {
        uint256 offset = uint256(_vault.decimals()) - uint256(_usdc.decimals());
        return (assets_ * (supply_ + 10 ** offset)) / (nav_ + 1);
    }
}
