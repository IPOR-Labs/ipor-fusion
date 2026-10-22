// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ValueNeutralToken} from "./CcipValueNeutralVersionTest.t.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipObservation} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {TrackedVaultPricingLib} from "../../contracts/crosschain/lib/TrackedVaultPricingLib.sol";

/// @notice An honest ERC-4626 whose `convertToAssets` reads `markets_` cold slots (2100 gas each), like a vault that
///         aggregates many markets. 200 slots cost about 0.43M cold: above the 200k on-chain budget, below the 2M
///         view budget.
contract HeavyHonestVault is MockRemoteVault {
    mapping(uint256 => uint256) internal _marketState;
    uint256 public markets;

    constructor(IERC20 asset_, uint256 markets_) MockRemoteVault(asset_, "HVY", "HVY") {
        markets = markets_;
        for (uint256 i; i < markets_; ++i) {
            _marketState[i] = 1;
        }
    }

    function convertToAssets(uint256 shares_) public view override returns (uint256) {
        uint256 acc;
        uint256 n = markets;
        for (uint256 i; i < n; ++i) {
            acc += _marketState[i];
        }
        return super.convertToAssets(shares_) + (acc - n);
    }
}

/// @notice A vault whose `convertToAssets` burns every unit of gas it is given; its other views work.
contract ConvertBurnerVault is MockRemoteVault {
    constructor(IERC20 asset_) MockRemoteVault(asset_, "BRN", "BRN") {}

    function convertToAssets(uint256) public pure override returns (uint256) {
        while (true) {}
        return 0;
    }
}

/// @notice A vault whose `asset()` burns every unit of gas once armed; `convertToAssets` is cheap.
contract AssetBurnerVault is MockRemoteVault {
    bool public armed;

    constructor(IERC20 asset_) MockRemoteVault(asset_, "ABN", "ABN") {}

    function arm() external {
        armed = true;
    }

    function asset() public view override returns (address) {
        if (armed) {
            while (true) {}
        }
        return super.asset();
    }
}

/// @dev Real CCIP executor and dispatcher over `MockCcipRouter`, no tracked vaults yet.
abstract contract CcipViewConvertBudgetBase is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    event TrackedVaultUnpriced(address vault, uint8 reason);

    MockCcipRouter internal router;
    ValueNeutralToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function _routeGas() internal pure virtual returns (uint256);

    function setUp() public virtual {
        router = new MockCcipRouter();
        token = new ValueNeutralToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _safety()
        );
        CcipRouteConfig memory back = _route(EXECUTOR_SELECTOR, address(executor));
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            RESCUE_ADMIN,
            GUARDIAN,
            RESCUE_DELAY
        );
        CcipRouteConfig memory executorRoute = _route(DISPATCHER_SELECTOR, address(dispatcher));
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        vm.warp(1_700_000_000);
        vm.roll(1_000);
    }

    function _route(uint64 selector_, address peer_) private pure returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: address(0),
                messageGasLimit: uint32(_routeGas()),
                tokenGasLimit: uint32(_routeGas()),
                maxFee: 0,
                enabled: true
            });
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }
}

/// @title CcipViewConvertBudgetTest
/// @notice IL-8602 review G-1: the attestation views (`observation()`, `accountedBalance()`) give `convertToAssets`
///         `VIEW_CONVERT_GAS`, so an honest multi-market vault above the 200k on-chain budget is priced; the CCIP
///         responses keep `VAULT_READ_GAS`.
contract CcipViewConvertBudgetTest is CcipViewConvertBudgetBase {
    HeavyHonestVault internal heavy;
    ConvertBurnerVault internal burner;
    AssetBurnerVault internal assetBurner;
    MockRemoteVault internal plain;

    function _routeGas() internal pure override returns (uint256) {
        return 3_000_000;
    }

    function setUp() public override {
        super.setUp();
        heavy = new HeavyHonestVault(IERC20(address(token)), 200);
        burner = new ConvertBurnerVault(IERC20(address(token)));
        plain = new MockRemoteVault(IERC20(address(token)), "P", "P");
        assetBurner = new AssetBurnerVault(IERC20(address(token)));
        address[] memory vaults = new address[](4);
        vaults[0] = address(heavy);
        vaults[1] = address(burner);
        vaults[2] = address(plain);
        vaults[3] = address(assetBurner);
        vm.prank(factory);
        dispatcher.configureVaults(vaults, true);
        _position(heavy, 50e18);
        _position(plain, 30e18);
    }

    function _position(MockRemoteVault vault_, uint256 amount_) private {
        token.mint(address(this), amount_);
        token.approve(address(vault_), amount_);
        vault_.deposit(amount_, address(dispatcher));
    }

    /// @notice The view prices the heavy honest vault (about 0.43M cold) and does not flag it.
    function testShouldPriceAHeavyHonestVaultInObservation() public {
        vm.cool(address(heavy));
        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.accountedBalance, 80e18, "heavy (50) and plain (30) priced");
        assertEq(obs.unpricedCount, 0, "nothing unpriced: the burner holds no shares yet");
        vm.cool(address(heavy)); // observation() above warmed it; accountedBalance() must be priced cold too
        assertEq(dispatcher.accountedBalance(), 80e18, "accountedBalance() uses the view budget too");
    }

    /// @notice A burner with shares is still isolated by the view, and the view's cost stays bounded.
    function testShouldBoundAConvertBurnerInObservation() public {
        _position(burner, 10e18);
        uint256 gasBefore = gasleft();
        CcipObservation memory obs = dispatcher.observation();
        uint256 used = gasBefore - gasleft();
        assertEq(obs.unpricedCount, 1, "burner flagged");
        assertEq(
            (obs.unpricedCodes >> 2) & 3,
            TrackedVaultPricingLib.UNPRICED_CONVERT_TO_ASSETS,
            "reason 2 at index 1"
        );
        assertEq(obs.accountedBalance, 80e18, "heavy and plain still priced");
        assertLt(used, 3_000_000, "one burner costs at most its 2M view budget plus the honest reads");
    }

    /// @notice `asset()` stays on the 200k budget in the view: an asset-burner is flagged as asset drift (reason 3),
    ///         costs the view about 200k, and the other vaults stay priced.
    function testShouldKeepAssetReadsOnTheOnChainBudgetInObservation() public {
        _position(assetBurner, 10e18);
        assetBurner.arm();
        uint256 gasBefore = gasleft();
        CcipObservation memory obs = dispatcher.observation();
        uint256 used = gasBefore - gasleft();
        assertEq(obs.unpricedCount, 1, "asset burner flagged");
        assertEq((obs.unpricedCodes >> 6) & 3, TrackedVaultPricingLib.UNPRICED_ASSET_DRIFT, "reason 3 at index 3");
        assertEq(obs.accountedBalance, 80e18, "heavy and plain still priced");
        assertLt(used, 1_500_000, "asset() burned its 200k cap, not the 2M view budget");
    }

    /// @notice The view budget keeps the pre-check: a caller cannot starve the 2M read into "unpriced".
    function testShouldRevertObservationWhenTheViewBudgetCannotBeHonoured() public {
        vm.expectRevert(TrackedVaultPricingLib.InsufficientGasForVaultRead.selector);
        dispatcher.observation{gas: 1_500_000}();
    }

    /// @notice The on-chain responses keep the 200k budget: a BALANCE_REPORT still flags the heavy vault (evidence
    ///         only) and is delivered. Attesters gate on `observation()`, which prices it.
    function testShouldKeepTheOnChainBudgetForCcipResponses() public {
        vm.cool(address(heavy));
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultUnpriced(address(heavy), TrackedVaultPricingLib.UNPRICED_CONVERT_TO_ASSETS);
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 3_000_000);
        assertFalse(executor.balanceRequestOutstanding(REMOTE_CHAIN), "report delivered");
    }
}

/// @title CcipViewConvertBudgetFlowTest
/// @notice IL-8602 review G-1 end to end: honest vault above the on-chain budget, full recall and the IL-8606
///         residual anchor.
contract CcipViewConvertBudgetFlowTest is CcipViewConvertBudgetBase {
    function _routeGas() internal pure override returns (uint256) {
        return 2_000_000;
    }

    function setUp() public override {
        super.setUp();
        address[] memory initial = new address[](1);
        initial[0] = address(new MockRemoteVault(IERC20(address(token)), "P", "P"));
        vm.prank(factory);
        dispatcher.configureVaults(initial, true);
    }

    function _bridge(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
    }

    function _command(uint8 action_, bytes memory actionData_) private {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: action_,
                minExecutionGas: 0,
                actionData: actionData_
            }),
            0,
            address(0),
            2_000_000
        );
    }

    function _allow(address vault_) private {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
    }

    function _indexOf(address vault_) private view returns (uint256 i) {
        uint256 len = dispatcher.trackedVaultsLength();
        for (; i < len; ++i) {
            if (dispatcher.trackedVaults(i) == vault_) return i;
        }
        revert("not tracked");
    }

    function _propose(uint256 balance_) private returns (uint256 proposalId) {
        vm.warp(block.timestamp + 1);
        proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    /// @dev settled = 100 and anchor = 100 after the bridge; a 50 position gains `yield_` and half of it is
    ///      realised, so 25e18 shares remain.
    function _openPositionWithYield(uint256 markets_, uint256 yield_) private returns (HeavyHonestVault v) {
        v = new HeavyHonestVault(IERC20(address(token)), markets_);
        _allow(address(v));
        _bridge(100e18);
        _command(uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(address(v), 50e18, 1));
        token.mint(address(v), yield_ + 1);
        _command(uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(address(v), 25e18, 0));
    }

    function _fullRecall(HeavyHonestVault v_) private {
        vm.cool(address(v_)); // cold, as in a fresh inbound transaction
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, dispatcher.trackedIdle(), 0, 0, address(0), 2_000_000);
        assertEq(v_.balanceOf(address(dispatcher)), 25e18, "25e18 shares left on the dispatcher");
    }

    /// @notice G1a, fixed: an honest vault needing about 231k cold is priced in `observation()` (the attestation
    ///         gate), as is a cheaper one. Before the fix the 231k vault was flagged and 50e18 of live value was
    ///         missing.
    function testShouldPriceAnHonestVaultAboveTheOnChainBudgetInObservation() public {
        HeavyHonestVault cheap = new HeavyHonestVault(IERC20(address(token)), 60);
        HeavyHonestVault costly = new HeavyHonestVault(IERC20(address(token)), 110);
        _allow(address(cheap));
        _allow(address(costly));
        _bridge(100e18);
        _command(uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(address(cheap), 30e18, 1));
        _command(uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(address(costly), 50e18, 1));
        // Deployed in this transaction, so warm; cool them to the price an eth_call or a fresh delivery pays.
        vm.cool(address(cheap));
        vm.cool(address(costly));

        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.unpricedCount, 0, "the honest 231k vault is priced by the view");
        assertEq((obs.unpricedCodes >> (_indexOf(address(costly)) * 2)) & 3, 0, "no reason code for it");
        assertEq(obs.accountedBalance, 20e18 + 30e18 + 50e18, "idle 20 + cheap 30 + costly 50");

        _command(uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(address(costly), 50e18, 50e18));
        assertEq(dispatcher.trackedIdle(), 70e18, "the full value comes back from the vault");
    }

    /// @notice Control for G1b: a vault under the on-chain budget keeps the IL-8606 residual anchor and the
    ///         residual is attested by an ordinary approval.
    function testShouldKeepTheResidualAnchorAfterFullRecallWhenTheVaultIsUnderTheOnChainBudget() public {
        HeavyHonestVault v = _openPositionWithYield(60, 50e18);
        _fullRecall(v);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "bucket emptied by the recall");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 50e18, "residual kept as the anchor");
        vm.warp(block.timestamp + 1 hours);
        uint256 pid = _propose(50e18);
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 50e18, "residual attested by an ordinary approval");
    }

    /// @notice Known limitation (IL-8602 G-1, README "Unpriced tracked vaults"): the RETURN_TRANSFER response of a
    ///         full recall prices with the 200k on-chain budget, so a position in a vault above it reports 0. The
    ///         IL-8606 residual anchor drops to 0 and attesting the real residual reverts until a timelocked
    ///         FORCE_SET_SETTLED. No funds are lost. The procedure is in the next test: attest first.
    function testKnownLimitationFullRecallWithOverCapVaultNeedsFreshAttestationFirst() public {
        HeavyHonestVault v = _openPositionWithYield(110, 50e18);
        _fullRecall(v);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "bucket emptied by the recall");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "anchor dropped: the report said 0");
        vm.warp(block.timestamp + 1 hours);
        uint256 pid = _propose(50e18);
        vm.prank(APPROVER);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnanchoredAttestation.selector, REMOTE_CHAIN, 50e18));
        executor.approveBalance(pid);
        assertEq(v.convertToAssets(v.balanceOf(address(dispatcher))), 50e18, "the position is really worth 50e18");
    }

    /// @notice The README procedure: approve a current attestation (the view prices the vault) before the full
    ///         recall. The recall then does not empty `settled`, so the residual rule never applies.
    function testShouldKeepSettledNonZeroWhenAFreshAttestationIsApprovedBeforeAFullRecall() public {
        // A 10% gain keeps the attestation inside the 20% big-change band.
        HeavyHonestVault v = _openPositionWithYield(110, 10e18);
        vm.cool(address(v));
        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.unpricedCount, 0, "the view prices the vault");
        uint256 idle = dispatcher.trackedIdle();
        uint256 position = v.convertToAssets(v.balanceOf(address(dispatcher)));
        assertGt(position, 0, "a position stays in the over-budget vault");
        assertEq(obs.accountedBalance, idle + position, "idle + position, position priced by the view");
        vm.warp(block.timestamp + 1 hours);
        uint256 pid = _propose(obs.accountedBalance);
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), obs.accountedBalance, "fresh attestation approved");

        _fullRecall(v);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), position, "settled keeps the residual");
        assertGt(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "anchor not dropped to 0");
    }
}
