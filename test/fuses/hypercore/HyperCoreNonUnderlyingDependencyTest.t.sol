// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {HyperCoreEffectSettlementBase, MockEffectSettlementChainlinkFeed} from "./HyperCoreEffectSettlementBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
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
/// @dev Numbers: setUp holds 1,000,000 USDC. Token 9 (8 decimals) is priced at $2; Core holds 100 tokens,
///      20 are bridged back to the vault, so market 55 = 80 x $2 = 160 USDC and market 7 = 20 x $2 = 40 USDC.
contract HyperCoreNonUnderlyingDependencyTest is HyperCoreEffectSettlementBase {
    uint64 internal constant TOKEN = 9;
    uint256 internal constant ERC20_MARKET = UNDERLYING_MARKET_ID; // market 7
    uint64 internal constant CORE_BALANCE_WEI = 100e8;
    uint64 internal constant BRIDGED_WEI = 20e8;
    uint256 internal constant DEPOSIT = 100e6;

    HyperCoreNonUnderlyingMockToken internal _token;

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

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev Registers token 9, grants it in markets 55 and 7, optionally installs the 55 -> 7 dependency, puts 100
    ///      tokens on Core, refreshes, bridges 20 back to the vault and settles the effect without a refresh.
    function _prepare(bool withDependency_) internal {
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
