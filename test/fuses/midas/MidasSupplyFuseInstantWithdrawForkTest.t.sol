// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";

import {MidasSupplyFuse, MidasSupplyFuseEnterData} from "../../../contracts/fuses/midas/MidasSupplyFuse.sol";
import {MidasBalanceFuse} from "../../../contracts/fuses/midas/MidasBalanceFuse.sol";
import {
    MidasSubstrateLib,
    MidasSubstrate,
    MidasSubstrateType
} from "../../../contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {IMidasDataFeed} from "../../../contracts/fuses/midas/ext/IMidasDataFeed.sol";

import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {PlasmaVaultHelper, DeployMinimalPlasmaVaultParams} from "../../test_helpers/PlasmaVaultHelper.sol";
import {PriceOracleMiddlewareHelper} from "../../test_helpers/PriceOracleMiddlewareHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @title MidasSupplyFuseInstantWithdrawForkTest
/// @notice IL-9617 (IL-9565): the withdraw router writes the MISSING amount of the vault's underlying (USDC) into word 0
///         of the instant withdraw params; MidasSupplyFuse used to redeem that number as mTokens (about 1e-12 of what
///         is needed on a USDC vault), so the Midas entry added nothing to the withdrawal. These tests let the real
///         mTBILL instant redemption vault (RedemptionVaultWithUSTB, paying from its USTB position) run `redeemInstant`
///         on an Ethereum fork: the fuse converts the missing USDC into mTBILL with Midas' own rate and fees and the
///         vault receives the missing USDC. On the audited base 8692fbe5 every test here fails.
contract MidasSupplyFuseInstantWithdrawForkTest is Test {
    using stdStorage for StdStorage;
    using PriceOracleMiddlewareHelper for PriceOracleMiddleware;
    using PlasmaVaultHelper for PlasmaVault;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    // ============ Mainnet Addresses ============
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant MTBILL = 0xDD629E5241CbC5919847783e6C96B2De4754e438;
    address private constant MTBILL_DEPOSIT_VAULT = 0x99361435420711723aF805F08187c9E6bF796683;
    /// @dev Instant redemption vault of mTBILL; at FORK_BLOCK: minAmount 1 mTBILL, instantFee 7 bps, USDC stable,
    ///      USDC fee 0, almost no USDC of its own (it redeems USTB for the missing USDC)
    address private constant MTBILL_INSTANT_REDEMPTION_VAULT = 0x569D7dccBF6923350521ecBC28A555A500c4f0Ec;
    address private constant CHAINLINK_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    uint256 private constant MARKET_ID = IporFusionMarkets.MIDAS;
    uint256 private constant ONE_HUNDRED_PERCENT = 100_00;

    /// @dev Own fork block (2026-11-09): shared blocks share one backend and leak vm.warp between suites
    uint256 public constant FORK_BLOCK = 26_380_000;

    bytes32 private constant EXIT_TOPIC = keccak256("MidasSupplyFuseExit(address,address,uint256,address,address)");
    bytes32 private constant EXIT_FAILED_TOPIC =
        keccak256("MidasSupplyFuseExitFailed(address,address,uint256,address,address)");

    MidasSupplyFuse private _supplyFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);
        _supplyFuse = new MidasSupplyFuse(MARKET_ID);

        vm.label(USDC, "USDC");
        vm.label(MTBILL, "mTBILL");
        vm.label(MTBILL_DEPOSIT_VAULT, "MidasDepositVault");
        vm.label(MTBILL_INSTANT_REDEMPTION_VAULT, "MidasInstantRedemptionVault");
        vm.label(address(_supplyFuse), "MidasSupplyFuse");
    }

    // ============ Fuse level (instantWithdraw as the router calls it) ============

    /// @notice 1,000 USDC missing: the fuse redeems the mTBILL that pays exactly that through the real redeemInstant
    function test_instantWithdrawPaysTheMissingUsdc() public {
        // given
        PlasmaVaultMock vault = _mockVaultWithMTbill(10_000e18);
        uint256 missing = 1_000e6;
        uint256 expectedMTbill = _mTbillForUsdc(missing);
        uint256 usedBefore = _dailyLimitUsed();

        // when
        vm.recordLogs();
        vault.instantWithdraw(_params(missing));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256 received = IERC20(USDC).balanceOf(address(vault));
        uint256 spent = 10_000e18 - IERC20(MTBILL).balanceOf(address(vault));
        assertGe(received, missing, "vault receives the missing USDC");
        assertLe(received, missing + 1, "no material over-redemption");
        assertEq(spent, expectedMTbill, "mTBILL grossed up by Midas' rate and instant fee");
        assertApproxEqRel(spent, 928e18, 0.01e18, "about 928 mTBILL for 1,000 USDC at ~1.0776");
        assertEq(_dailyLimitUsed() - usedBefore, spent, "redeemed through the real instant redemption vault");
        assertEq(_count(logs, EXIT_TOPIC), 1, "MidasSupplyFuseExit emitted");
        assertEq(_count(logs, EXIT_FAILED_TOPIC), 0, "no MidasSupplyFuseExitFailed");
        assertEq(IERC20(MTBILL).allowance(address(vault), MTBILL_INSTANT_REDEMPTION_VAULT), 0, "approval cleared");
    }

    /// @notice The request is capped at the rest of today's instant limit: the real vault pays for what is left instead
    ///         of rejecting the whole redemption
    function test_instantWithdrawIsCappedAtRemainingDailyLimit() public {
        // given - only 500 mTBILL of today's instant limit left
        PlasmaVaultMock vault = _mockVaultWithMTbill(10_000e18);
        uint256 limit = _view("instantDailyLimit()");
        stdstore
            .target(MTBILL_INSTANT_REDEMPTION_VAULT)
            .sig("dailyLimits(uint256)")
            .with_key(block.timestamp / 1 days)
            .checked_write(limit - 500e18);

        // when - 1,000 USDC missing would need about 928 mTBILL
        vm.recordLogs();
        vault.instantWithdraw(_params(1_000e6));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        uint256 spent = 10_000e18 - IERC20(MTBILL).balanceOf(address(vault));
        assertEq(spent, 500e18, "capped at the remaining daily limit");
        assertEq(_dailyLimitUsed(), limit, "daily limit fully used");
        assertGt(IERC20(USDC).balanceOf(address(vault)), 500e6, "the capped redemption pays USDC");
        assertEq(_count(logs, EXIT_FAILED_TOPIC), 0, "no MidasSupplyFuseExitFailed");
    }

    /// @notice Below Midas' minimum (1 mTBILL) the entry is skipped without a call: no revert, no failed redemption
    function test_instantWithdrawBelowMidasMinimumIsSkipped() public {
        // given - 0.5 USDC missing is about 0.46 mTBILL
        PlasmaVaultMock vault = _mockVaultWithMTbill(10_000e18);
        uint256 usedBefore = _dailyLimitUsed();

        // when
        vm.recordLogs();
        vault.instantWithdraw(_params(0.5e6));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(IERC20(MTBILL).balanceOf(address(vault)), 10_000e18, "no mTBILL redeemed");
        assertEq(_dailyLimitUsed(), usedBefore, "Midas not called");
        assertEq(_count(logs, EXIT_FAILED_TOPIC), 1, "one MidasSupplyFuseExitFailed for the skipped entry");
        assertEq(_count(logs, EXIT_TOPIC), 0, "no MidasSupplyFuseExit");
    }

    // ============ PlasmaVault: user withdrawal through withdrawFromMarkets ============

    /// @notice A user withdrawal larger than the idle USDC is served by the Midas instant withdraw entry. On the base
    ///         the entry redeemed `missing` wei of mTBILL (below Midas' minimum, caught) and the withdrawal reverted
    function test_userWithdrawalIsServedFromMidas() public {
        // given - 10,000 USDC deposited, 9,000 of it allocated to mTBILL through depositInstant
        (PlasmaVault plasmaVault, MidasSupplyFuse supplyFuse) = _plasmaVaultWithMidas();
        _depositAndAllocate(plasmaVault, supplyFuse, 10_000e6, 9_000e6);
        assertEq(IERC20(USDC).balanceOf(address(plasmaVault)), 1_000e6, "1,000 USDC idle");
        uint256 mTbillBefore = IERC20(MTBILL).balanceOf(address(plasmaVault));

        // when - the user withdraws 3,000 USDC: about 2,000 USDC must come from Midas
        vm.recordLogs();
        vm.prank(TestAddresses.USER);
        plasmaVault.withdraw(3_000e6, TestAddresses.USER, TestAddresses.USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(IERC20(USDC).balanceOf(TestAddresses.USER), 3_000e6, "user received the payout");
        uint256 spent = mTbillBefore - IERC20(MTBILL).balanceOf(address(plasmaVault));
        assertEq(spent, _mTbillForUsdc(2_000e6 + 10), "mTBILL for the missing USDC incl. the 10 wei offset");
        assertLe(IERC20(USDC).balanceOf(address(plasmaVault)), 11, "only the offset and rounding stay idle");
        assertEq(_count(logs, EXIT_TOPIC), 1, "MidasSupplyFuseExit emitted");
        assertEq(_count(logs, EXIT_FAILED_TOPIC), 0, "no MidasSupplyFuseExitFailed");
    }

    // ============ helpers ============

    /// @dev mTBILL that Midas needs to pay `usdc_` (6 decimals), from the vault's live views:
    ///      ceil(usdc × 1e12 × tokenOutRate × 100_00 / (mTokenRate × (100_00 − instantFee − tokenFee)))
    function _mTbillForUsdc(uint256 usdc_) private view returns (uint256) {
        (bool ok, bytes memory data) = MTBILL_INSTANT_REDEMPTION_VAULT.staticcall(
            abi.encodeWithSignature("tokensConfig(address)", USDC)
        );
        assertTrue(ok, "tokensConfig failed");
        (address dataFeed, uint256 tokenFee, , bool stable) = abi.decode(data, (address, uint256, uint256, bool));
        uint256 tokenOutRate = stable ? 1e18 : IMidasDataFeed(dataFeed).getDataInBase18();
        uint256 mTokenRate = IMidasDataFeed(address(uint160(_view("mTokenDataFeed()")))).getDataInBase18();
        uint256 feeBps = _view("instantFee()") + tokenFee;
        uint256 numerator = usdc_ * 1e12 * tokenOutRate * ONE_HUNDRED_PERCENT;
        uint256 denominator = mTokenRate * (ONE_HUNDRED_PERCENT - feeBps);
        return (numerator + denominator - 1) / denominator;
    }

    function _dailyLimitUsed() private view returns (uint256) {
        (bool ok, bytes memory data) = MTBILL_INSTANT_REDEMPTION_VAULT.staticcall(
            abi.encodeWithSignature("dailyLimits(uint256)", block.timestamp / 1 days)
        );
        assertTrue(ok, "dailyLimits failed");
        return abi.decode(data, (uint256));
    }

    function _view(string memory signature_) private view returns (uint256) {
        (bool ok, bytes memory data) = MTBILL_INSTANT_REDEMPTION_VAULT.staticcall(abi.encodeWithSignature(signature_));
        assertTrue(ok, signature_);
        return abi.decode(data, (uint256));
    }

    /// @dev Instant withdraw params as the router builds them: word 0 = missing USDC, word 4 = minTokenOutAmount 0
    function _params(uint256 missingUsdc_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](5);
        params[0] = bytes32(missingUsdc_);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MTBILL);
        params[2] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        params[3] = PlasmaVaultConfigLib.addressToBytes32(MTBILL_INSTANT_REDEMPTION_VAULT);
        params[4] = bytes32(uint256(0));
    }

    function _count(Vm.Log[] memory logs_, bytes32 topic_) private pure returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics.length != 0 && logs_[i].topics[0] == topic_) ++count;
        }
    }

    function _substrates() private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](4);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: MTBILL})
        );
        substrates[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: MTBILL_DEPOSIT_VAULT})
        );
        substrates[2] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: USDC})
        );
        substrates[3] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({
                substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
                substrateAddress: MTBILL_INSTANT_REDEMPTION_VAULT
            })
        );
    }

    function _mockVaultWithMTbill(uint256 mTbill_) private returns (PlasmaVaultMock vault) {
        vault = new PlasmaVaultMock(address(_supplyFuse), address(0));
        vault.grantMarketSubstrates(MARKET_ID, _substrates());
        deal(MTBILL, address(vault), mTbill_);
        vm.label(address(vault), "PlasmaVaultMock");
    }

    function _plasmaVaultWithMidas() private returns (PlasmaVault plasmaVault, MidasSupplyFuse supplyFuse) {
        vm.startPrank(TestAddresses.ATOMIST);
        PriceOracleMiddleware priceOracleMiddleware = PriceOracleMiddlewareHelper.deployPriceOracleMiddleware(
            TestAddresses.ATOMIST,
            address(0)
        );
        priceOracleMiddleware.addSource(USDC, CHAINLINK_USDC_USD);

        address withdrawManager;
        (plasmaVault, withdrawManager) = PlasmaVaultHelper.deployMinimalPlasmaVault(
            DeployMinimalPlasmaVaultParams({
                underlyingToken: USDC,
                underlyingTokenName: "USDC",
                priceOracleMiddleware: address(priceOracleMiddleware),
                atomist: TestAddresses.ATOMIST
            })
        );
        IporFusionAccessManager accessManager = plasmaVault.accessManagerOf();
        accessManager.setupInitRoles(
            plasmaVault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );
        vm.stopPrank();

        supplyFuse = new MidasSupplyFuse(MARKET_ID);
        MidasBalanceFuse balanceFuse = new MidasBalanceFuse(MARKET_ID);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);
        plasmaVault.addFusesToVault(fuses);
        plasmaVault.addBalanceFusesToVault(MARKET_ID, address(balanceFuse));
        plasmaVault.addSubstratesToMarket(MARKET_ID, _substrates());
        vm.stopPrank();

        bytes32[] memory iwParams = _params(0);
        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](1);
        iw[0] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuse), params: iwParams});
        vm.prank(TestAddresses.CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER);
        PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(iw);

        vm.label(address(plasmaVault), "PlasmaVault");
    }

    function _depositAndAllocate(
        PlasmaVault plasmaVault_,
        MidasSupplyFuse supplyFuse_,
        uint256 deposit_,
        uint256 allocate_
    ) private {
        deal(USDC, TestAddresses.USER, deposit_);
        vm.startPrank(TestAddresses.USER);
        IERC20(USDC).approve(address(plasmaVault_), deposit_);
        plasmaVault_.deposit(deposit_, TestAddresses.USER);
        vm.stopPrank();

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(supplyFuse_),
            data: abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,address))",
                MidasSupplyFuseEnterData({
                    mToken: MTBILL,
                    tokenIn: USDC,
                    amount: allocate_,
                    minMTokenAmountOut: 0,
                    depositVault: MTBILL_DEPOSIT_VAULT
                })
            )
        });
        vm.prank(TestAddresses.ALPHA);
        plasmaVault_.execute(actions);
        assertGt(IERC20(MTBILL).balanceOf(address(plasmaVault_)), 0, "mTBILL minted by depositInstant");
    }
}
