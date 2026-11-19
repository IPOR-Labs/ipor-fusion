// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {PlasmaVault, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FuseAction} from "../../contracts/interfaces/IPlasmaVault.sol";
import {IFuseCommon} from "../../contracts/fuses/IFuseCommon.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";
import {RealizeManagementFeeFuse} from "../../contracts/fuses/management_fee/RealizeManagementFeeFuse.sol";
import {IRealizeManagementFeeInternal} from "../../contracts/interfaces/IRealizeManagementFeeInternal.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";

/// @notice Fuse that calls the ALPHA method from inside `execute`; it must hit the reentrancy guard (IL-8870)
contract ReentrantRealizeManagementFeeFuse is IFuseCommon {
    uint256 public constant MARKET_ID = IporFusionMarkets.ZERO_BALANCE_MARKET;

    function enter() external {
        PlasmaVault(address(this)).realizeManagementFee();
    }
}

/// @title RealizeManagementFeeTestBase - shared vault fixture of the IL-8870 management fee realization tests
/// @dev The vault is built through the real initializer (`IporFusionAccessManagerHelper.setupInitRoles`, so the ALPHA
///      mapping of `realizeManagementFee` comes from the production initializer). Asset: 6 decimals, price 1 USD,
///      management fee 2% by default, performance fee 20% (the high water mark stays at the initial rate in the tests).
abstract contract RealizeManagementFeeTestBase is Test {
    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);
    event RealizeManagementFeeFuseEnter(address version, uint256 feeShares);

    /// @dev Slot of the pending management fee (PlasmaVaultStorageLib.PENDING_MANAGEMENT_FEE_SLOT)
    bytes32 internal constant PENDING_MANAGEMENT_FEE_SLOT =
        0x612d50d27ffbb749a9804ec5bba7933bff2377ff69afba55e14b5cf7180bff00;

    /// @dev Slot of the supply cap validation flag (PlasmaVaultStorageLib.ERC20_CAPPED_VALIDATION_FLAG)
    bytes32 internal constant CAP_VALIDATION_FLAG_SLOT =
        0xaef487a7a52e82ae7bbc470b42be72a1d3c066fb83773bf99cce7e6a7df2f900;

    /// @dev 2% per year (FeeManager percentages use 2 decimals)
    uint256 internal constant MANAGEMENT_FEE = 200;
    uint256 internal constant PERFORMANCE_FEE = 2000;
    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal constant ONE_UNIT = 1e6;
    /// @dev Shares used to read the exchange rate with a resolution finer than one asset unit
    uint256 internal constant RATE_PROBE = 1e14;

    /// @notice State compared between the realization routes
    struct State {
        uint256 feeShares;
        uint256 clock;
        uint256 pending;
        uint256 rate;
        uint256 totalSupply;
    }

    address internal alpha = TestAddresses.ALPHA;
    address internal fuseManager = TestAddresses.FUSE_MANAGER;
    address internal atomist = TestAddresses.ATOMIST;
    address internal user = makeAddr("user");
    address internal depositor = makeAddr("depositor");

    MockERC20Decimals internal asset;
    PlasmaVault internal plasmaVault;
    IporFusionAccessManager internal accessManager;
    RealizeManagementFeeFuse internal realizeFuse;
    address internal feeAccount;
    address internal performanceFeeAccount;
    /// @dev 10 ** (vault decimals - asset decimals)
    uint256 internal shareScale;

    function _deployVault(uint256 managementFee_, address votesPlugin_) internal {
        asset = new MockERC20Decimals("Mock Asset", "mA", 6);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        accessManager = new IporFusionAccessManager(address(this), 0);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mA",
                "ipfmA",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: managementFee_,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                withdrawManager,
                votesPlugin_
            )
        );

        feeAccount = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeAccount;
        performanceFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER()).initialize();

        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            plasmaVault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(plasmaVault)))
        );

        realizeFuse = new RealizeManagementFeeFuse();
        _addFuse(address(realizeFuse));

        address zeroBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        vm.prank(fuseManager);
        PlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            zeroBalanceFuse
        );

        shareScale = 10 ** (plasmaVault.decimals() - 6);
    }

    function _addFuse(address fuse_) internal {
        address[] memory fuses = new address[](1);
        fuses[0] = fuse_;
        vm.prank(fuseManager);
        PlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
    }

    function _deposit(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.startPrank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(amount_, user_);
        vm.stopPrank();
    }

    /// @dev Tiny supply (1 wei of assets = `shareScale` shares) holding a large donation: a 90 day fee rounds to 0 shares
    function _deployDustVault() internal {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, 1);
        asset.mint(address(plasmaVault), 1_000e6);
    }

    function _executeFuse(address fuse_, bytes memory data_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({fuse: fuse_, data: data_});
        vm.prank(alpha);
        plasmaVault.execute(actions);
    }

    function _executeRealizeFuse() internal {
        _executeFuse(address(realizeFuse), abi.encodeWithSelector(RealizeManagementFeeFuse.enter.selector));
    }

    /// @dev V = floor(F * (S + scale) / (G - F + 1)), the formula of D-002 computed independently of the vault
    function _expectedShares(uint256 fee_, uint256 supply_, uint256 gross_) internal view returns (uint256) {
        return Math.mulDiv(fee_, supply_ + shareScale, gross_ - fee_ + 1);
    }

    function _lastUpdate() internal view returns (uint256) {
        return PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().lastUpdateTimestamp;
    }

    function _pending() internal view returns (uint256) {
        return uint256(vm.load(address(plasmaVault), PENDING_MANAGEMENT_FEE_SLOT));
    }

    function _state() internal view returns (State memory state_) {
        state_.feeShares = plasmaVault.balanceOf(feeAccount);
        state_.clock = _lastUpdate();
        state_.pending = _pending();
        state_.rate = plasmaVault.convertToAssets(RATE_PROBE);
        state_.totalSupply = plasmaVault.totalSupply();
    }

    function _hwm() internal view returns (uint256) {
        return
            FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER())
                .getPlasmaVaultHighWaterMarkPerformanceFee()
                .highWaterMark;
    }

    /// @dev Number of logs with `topic0_` emitted by the vault
    function _countVaultLogs(Vm.Log[] memory logs_, bytes32 topic0_) internal view returns (uint256 count_) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(plasmaVault) && logs_[i].topics[0] == topic0_) {
                ++count_;
            }
        }
    }
}

/// @title PlasmaVaultRealizeManagementFeeTest
/// @notice IL-8870: the ALPHA method `realizeManagementFee()` and the fuse entry `realizeManagementFeeInternal()`
contract PlasmaVaultRealizeManagementFeeTest is RealizeManagementFeeTestBase {
    // ---------------------------------------------------------------------------------------------
    // 1. ALPHA method
    // ---------------------------------------------------------------------------------------------

    function testShouldRealizeManagementFeeByAlpha() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);

        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 expectedShares = _expectedShares(fee, plasmaVault.totalSupply(), plasmaVault.totalAssets());
        uint256 rateBefore = plasmaVault.convertToAssets(RATE_PROBE);
        uint256 assetsBefore = plasmaVault.totalAssets();

        assertEq(fee, 2e10, "2% of 1 000 000 assets for one year");
        assertEq(expectedShares, 2040816326530, "pinned D-002 value");
        assertEq(plasmaVault.balanceOf(feeAccount), 0, "no fee shares before");

        vm.expectEmit(false, false, false, true, address(plasmaVault));
        emit ManagementFeeRealized(fee, expectedShares);
        vm.prank(alpha);
        uint256 result = plasmaVault.realizeManagementFee();

        assertEq(result, expectedShares, "returned fee shares");
        assertEq(plasmaVault.balanceOf(feeAccount), expectedShares, "minted to the management fee account");
        assertEq(_lastUpdate(), block.timestamp, "clock moved to now");
        assertEq(_pending(), 0, "pending cleared");
        assertEq(plasmaVault.getUnrealizedManagementFee(), 0, "nothing left to realize");
        assertEq(plasmaVault.convertToAssets(RATE_PROBE), rateBefore, "share price unchanged by the collection");
        assertEq(plasmaVault.totalAssets(), assetsBefore, "gross assets unchanged");
    }

    function testShouldRevertRealizeManagementFeeWhenCallerIsNotAlpha() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("AccessManagedUnauthorized(address)")), user));
        plasmaVault.realizeManagementFee();
    }

    // ---------------------------------------------------------------------------------------------
    // 2. Same state through the method, execute([fuse]) and a 1-unit deposit
    // ---------------------------------------------------------------------------------------------

    function testShouldReachSameStateThroughMethodExecuteAndDeposit() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);

        uint256 snapshot = vm.snapshotState();
        vm.prank(alpha);
        plasmaVault.realizeManagementFee();
        State memory viaMethod = _state();
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        _executeRealizeFuse();
        State memory viaExecute = _state();
        vm.revertToState(snapshot);

        _deposit(depositor, ONE_UNIT);
        State memory viaDeposit = _state();

        assertGt(viaMethod.feeShares, 0, "fee shares minted");
        assertEq(viaExecute.feeShares, viaMethod.feeShares, "execute: fee shares");
        assertEq(viaExecute.clock, viaMethod.clock, "execute: clock");
        assertEq(viaExecute.pending, viaMethod.pending, "execute: pending");
        assertEq(viaExecute.rate, viaMethod.rate, "execute: share price");

        assertEq(viaDeposit.feeShares, viaMethod.feeShares, "deposit: fee shares");
        assertEq(viaDeposit.clock, viaMethod.clock, "deposit: clock");
        assertEq(viaDeposit.pending, viaMethod.pending, "deposit: pending");
        assertApproxEqRel(viaDeposit.rate, viaMethod.rate, 1e9, "deposit: share price within the deposit rounding");
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Zero accrual and accrual rounded to zero shares (DA-4, DA-6 semantics)
    // ---------------------------------------------------------------------------------------------

    function testShouldMoveClockWithoutMintWhenRateAndPendingAreZero() public {
        _deployVault(0, address(0));
        _deposit(user, DEPOSIT);
        uint256 clockBefore = _lastUpdate();
        vm.warp(block.timestamp + 30 days);
        uint256 supplyBefore = plasmaVault.totalSupply();

        vm.recordLogs();
        vm.prank(alpha);
        uint256 result = plasmaVault.realizeManagementFee();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(result, 0, "nothing minted");
        assertEq(plasmaVault.totalSupply(), supplyBefore, "supply unchanged");
        assertEq(plasmaVault.balanceOf(feeAccount), 0, "fee account empty");
        assertEq(
            _countVaultLogs(logs, ManagementFeeRealized.selector),
            0,
            "no ManagementFeeRealized event on a zero collection"
        );
        assertLt(clockBefore, block.timestamp, "precondition: time passed");
        assertEq(_lastUpdate(), block.timestamp, "clock moved to now");
        assertEq(_pending(), 0, "pending stays zero");
    }

    function testShouldKeepFeeRoundedToZeroSharesInPendingAndMoveClock() public {
        _deployDustVault();
        vm.warp(block.timestamp + 90 days);

        uint256 fee = plasmaVault.getUnrealizedManagementFee();
        uint256 supplyBefore = plasmaVault.totalSupply();
        assertGt(fee, 0, "precondition: positive accrual");
        assertEq(_expectedShares(fee, supplyBefore, plasmaVault.totalAssets()), 0, "precondition: rounds to 0 shares");

        vm.recordLogs();
        vm.prank(alpha);
        uint256 result = plasmaVault.realizeManagementFee();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(result, 0, "no shares");
        assertEq(plasmaVault.totalSupply(), supplyBefore, "supply unchanged");
        assertEq(_countVaultLogs(logs, ManagementFeeRealized.selector), 0, "no event");
        assertEq(_pending(), fee, "the accrual stays in pending");
        assertEq(_lastUpdate(), block.timestamp, "clock moved to now");
        assertEq(plasmaVault.getUnrealizedManagementFee(), fee, "the fee stays accrued");
    }

    // ---------------------------------------------------------------------------------------------
    // 4. realizeManagementFeeInternal accepts only the vault itself during execute
    // ---------------------------------------------------------------------------------------------

    function testShouldRevertInternalEntryWhenCalledByEoa() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        address eoa = makeAddr("eoa");

        vm.prank(eoa);
        vm.expectRevert(abi.encodeWithSelector(Errors.WrongCaller.selector, eoa));
        IRealizeManagementFeeInternal(address(plasmaVault)).realizeManagementFeeInternal();

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "nothing minted");
    }

    function testShouldRevertInternalEntryWhenVaultCallsItselfOutsideExecute() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);

        vm.prank(address(plasmaVault));
        vm.expectRevert(abi.encodeWithSelector(Errors.WrongCaller.selector, address(plasmaVault)));
        IRealizeManagementFeeInternal(address(plasmaVault)).realizeManagementFeeInternal();

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "nothing minted");
    }

    // ---------------------------------------------------------------------------------------------
    // 5. The ALPHA method cannot be called from inside execute
    // ---------------------------------------------------------------------------------------------

    function testShouldRevertWithReentrancyGuardWhenFuseCallsAlphaMethodInsideExecute() public {
        _deployVault(MANAGEMENT_FEE, address(0));
        _deposit(user, DEPOSIT);
        vm.warp(block.timestamp + 365 days);
        ReentrantRealizeManagementFeeFuse reentrantFuse = new ReentrantRealizeManagementFeeFuse();
        _addFuse(address(reentrantFuse));

        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        _executeFuse(address(reentrantFuse), abi.encodeWithSelector(ReentrantRealizeManagementFeeFuse.enter.selector));

        assertEq(plasmaVault.balanceOf(feeAccount), 0, "nothing minted");
    }
}
