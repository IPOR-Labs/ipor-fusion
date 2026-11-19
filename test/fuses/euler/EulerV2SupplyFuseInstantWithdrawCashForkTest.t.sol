// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {
    EulerV2SupplyFuse,
    EulerV2SupplyFuseEnterData,
    EulerV2SupplyFuseExitData
} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultCloneLib} from "../../test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    InitializationData,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

/// @title EulerV2SupplyFuseInstantWithdrawCashForkTest
/// @notice IL-9352: the instant withdraw path of EulerV2SupplyFuse caps each request at the EVault's free cash, so a
///         partially liquid venue pays what it can and the next fuse in the list takes the rest. Real Euler V2
///         EVaults on a mainnet fork, a real PlasmaVault and the real withdrawFromMarkets loop.
contract EulerV2SupplyFuseInstantWithdrawCashForkTest is Test {
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Venue A (drained to low cash) and venue B (liquid), both real Euler V2 USDC EVaults
    address private constant EULER_VAULT_PRIME_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant EULER_VAULT_USDC = 0xB93d4928f39fBcd6C89a7DFbF0A867E6344561bE;
    /// @dev WETH EVault, accepted as collateral by Prime USDC (see EulerV2CreditMarket.t.sol)
    address private constant EULER_VAULT_WETH = 0xb3b36220fA7d12f7055dab5c9FD18E860e9a6bF8;

    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _USDC_USD_CHAINLINK = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address private constant _USDC_WHALE = 0x4B16c5dE96EB2117bBE5fd171E4d203624B014aa;

    address private constant _ATOMIST = address(0x111111);
    address private constant _USER = address(0x222222);

    bytes1 private constant _SUB_A = 0x01;
    bytes1 private constant _SUB_B = 0x02;

    /// @dev Own fork block: shared blocks share one backend and leak vm.warp between suites
    uint256 public constant FORK_BLOCK = 20990352;

    address private _plasmaVault;
    address private _accessManager;
    address private _withdrawManager;
    address private _eulerSupplyFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        address priceOracle = _createPriceOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Euler IW cash",
                assetSymbol: "eIWc",
                underlyingToken: _USDC,
                priceOracleMiddleware: priceOracle,
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: _accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: _withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            _plasmaVault,
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigsErc20()
        );

        _initAccessManager();
        _grantEulerSubstrates();

        vm.prank(_USDC_WHALE);
        ERC20(_USDC).transfer(_USER, 10_000e6);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();
    }

    /// @notice Venue A (cash 3,000) is first in the list, venue B is liquid: the withdrawal draws the partial cash of A
    ///         and the rest from B instead of reverting
    function test_withdrawTakesPartialCashFromFirstVenueAndRestFromNext() public {
        _allocate(6_000e6, 4_000e6, true);
        _liftCaps(EULER_VAULT_PRIME_USDC);
        _liftCaps(EULER_VAULT_WETH);
        _drainCash(EULER_VAULT_PRIME_USDC, 3_000e6);
        assertEq(IBorrowing(EULER_VAULT_PRIME_USDC).cash(), 3_000e6, "venue A cash");

        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs, EULER_VAULT_PRIME_USDC), 3_000e6, "venue A pays its whole cash");
        assertEq(_exitAmount(logs, EULER_VAULT_USDC), 2_000e6 + 10, "venue B pays the rest incl. offset");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
        assertEq(IBorrowing(EULER_VAULT_PRIME_USDC).cash(), 0, "venue A cash fully used");

        uint256 remaining = IERC4626(EULER_VAULT_PRIME_USDC).convertToAssets(
            IERC20(EULER_VAULT_PRIME_USDC).balanceOf(_subA())
        ) + IERC4626(EULER_VAULT_USDC).convertToAssets(IERC20(EULER_VAULT_USDC).balanceOf(_subB()));
        assertApproxEqAbs(
            PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2),
            remaining,
            20,
            "market 11 refreshed to the remaining positions"
        );
    }

    /// @notice 3sigma PoC (finding 5, IL-9532): two real positions of about 1,000, each above its 400 of free cash,
    ///         idle 0. A 600 withdrawal must recover 800 available: 400 from venue A and the rest (200 plus the 10 wei
    ///         vault offset) from venue B, instead of failing in both. Venue A is drained through a real borrower;
    ///         venue B (eUSDC-1, no governor) has part of its cash re-booked as borrows, so its total assets and the
    ///         position stay at the real value
    function test_withdrawTakesPartialCashFromBothVenues() public {
        // given - leave 2,000 of the 10,000 deposit idle so that the allocation drains the idle balance to zero
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(8_000e6, _USER, _USER);
        uint256 userBefore = ERC20(_USDC).balanceOf(_USER);

        _allocate(1_000e6, 1_000e6, true);
        _liftCaps(EULER_VAULT_PRIME_USDC);
        _liftCaps(EULER_VAULT_WETH);
        _drainCash(EULER_VAULT_PRIME_USDC, 400e6);
        _rebookCashAsBorrows(EULER_VAULT_USDC, 400e6);

        assertEq(ERC20(_USDC).balanceOf(_plasmaVault), 0, "idle is zero before the withdrawal");
        assertEq(IBorrowing(EULER_VAULT_PRIME_USDC).cash(), 400e6, "venue A cash");
        assertEq(IBorrowing(EULER_VAULT_USDC).cash(), 400e6, "venue B cash");
        uint256 positionA = IERC4626(EULER_VAULT_PRIME_USDC).convertToAssets(
            IERC20(EULER_VAULT_PRIME_USDC).balanceOf(_subA())
        );
        uint256 positionB = IERC4626(EULER_VAULT_USDC).convertToAssets(IERC20(EULER_VAULT_USDC).balanceOf(_subB()));
        assertApproxEqAbs(positionA, 1_000e6, 10, "venue A position is about 1,000");
        assertApproxEqAbs(positionB, 1_000e6, 10, "venue B position is about 1,000");
        assertGt(positionA, IBorrowing(EULER_VAULT_PRIME_USDC).cash(), "venue A position exceeds its cash");
        assertGt(positionB, IBorrowing(EULER_VAULT_USDC).cash(), "venue B position exceeds its cash");

        // when
        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(600e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // then
        assertEq(ERC20(_USDC).balanceOf(_USER) - userBefore, 600e6, "user received the payout");
        assertEq(_exitAmount(logs, EULER_VAULT_PRIME_USDC), 400e6, "venue A pays its whole cash");
        assertEq(_exitAmount(logs, EULER_VAULT_USDC), 200e6 + 10, "venue B pays the rest incl. offset");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice Cash covers the payout (5,000) but not the payout plus the 10 wei vault offset by 5 wei: the capped
    ///         request still satisfies the withdrawal
    function test_withdrawSucceedsWhenCashCoversPayoutButNotOffset() public {
        _allocate(10_000e6, 0, false);
        _liftCaps(EULER_VAULT_PRIME_USDC);
        _liftCaps(EULER_VAULT_WETH);
        _drainCash(EULER_VAULT_PRIME_USDC, 5_000e6 + 5);

        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs, EULER_VAULT_PRIME_USDC), 5_000e6 + 5, "request capped at cash");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice Half of the shares are redeemed. Venue A cash covers the redeem payout (+1%) but sits below the vault's
    ///         2% slippage-buffered request, and the position exceeds that request, so the cash cap is the binding one:
    ///         the request is capped at cash and the redeem succeeds
    function test_redeemSucceedsWhenCashIsBelowSlippageBuffer() public {
        _allocate(10_000e6, 0, false);
        _liftCaps(EULER_VAULT_PRIME_USDC);
        _liftCaps(EULER_VAULT_WETH);

        uint256 shares = IERC20(_plasmaVault).balanceOf(_USER);
        uint256 sharesToRedeem = shares / 2;
        uint256 payout = PlasmaVault(_plasmaVault).convertToAssets(sharesToRedeem);
        uint256 cashLeft = (payout * 101) / 100;
        {
            uint256 position = IERC4626(EULER_VAULT_PRIME_USDC).convertToAssets(
                IERC20(EULER_VAULT_PRIME_USDC).balanceOf(_subA())
            );
            assertGt(cashLeft, payout, "cash covers the payout");
            assertLt(cashLeft, (payout * 102) / 100, "cash is below the buffered request");
            assertGt(position, (payout * 103) / 100, "position exceeds the buffered request");
        }
        _drainCash(EULER_VAULT_PRIME_USDC, cashLeft);

        vm.recordLogs();
        vm.prank(_USER);
        uint256 assets = PlasmaVault(_plasmaVault).redeem(sharesToRedeem, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_exitAmount(logs, EULER_VAULT_PRIME_USDC), cashLeft, "request capped at cash");
        assertEq(IBorrowing(EULER_VAULT_PRIME_USDC).cash(), 0, "venue A cash fully used");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
        assertEq(ERC20(_USDC).balanceOf(_USER), assets, "user received the redeem payout");
        assertApproxEqAbs(assets, payout, 20, "redeem paid the converted payout");
        assertEq(IERC20(_plasmaVault).balanceOf(_USER), shares - sharesToRedeem, "half of the shares redeemed");
    }

    /// @notice The sub-account has an EVC controller enabled, so EVK maxWithdraw is 0, yet the cash-based cap still
    ///         lets the instant withdraw pull the available cash (a maxWithdraw-based cap would pay nothing)
    function test_instantWithdrawIgnoresZeroMaxWithdrawOfControllerAccount() public {
        _allocate(6_000e6, 4_000e6, true);
        _liftCaps(EULER_VAULT_PRIME_USDC);
        _liftCaps(EULER_VAULT_WETH);
        _drainCash(EULER_VAULT_PRIME_USDC, 3_000e6);

        vm.prank(_plasmaVault);
        IEVC(_EVC).enableController(_subA(), EULER_VAULT_PRIME_USDC);
        assertEq(IERC4626(EULER_VAULT_PRIME_USDC).maxWithdraw(_subA()), 0, "EVK: maxWithdraw is 0 with a controller");

        vm.recordLogs();
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).withdraw(5_000e6, _USER, _USER);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(ERC20(_USDC).balanceOf(_USER), 5_000e6, "user received the payout");
        assertEq(_exitAmount(logs, EULER_VAULT_PRIME_USDC), 3_000e6, "venue A pays its whole cash");
        assertEq(_exitAmount(logs, EULER_VAULT_USDC), 2_000e6 + 10, "venue B pays the rest incl. offset");
        assertEq(_failedCount(logs), 0, "no ExitFailed event");
    }

    /// @notice Pins D-001: the normal ALPHA exit is not capped at cash, a request above the EVault cash reverts
    function test_alphaExitAboveCashStillReverts() public {
        _allocate(6_000e6, 4_000e6, true);
        _liftCaps(EULER_VAULT_PRIME_USDC);
        _liftCaps(EULER_VAULT_WETH);
        _drainCash(EULER_VAULT_PRIME_USDC, 3_000e6);

        FuseAction[] memory exits = new FuseAction[](1);
        exits[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,bytes1))",
                EulerV2SupplyFuseExitData({eulerVault: EULER_VAULT_PRIME_USDC, maxAmount: 5_000e6, subAccount: _SUB_A})
            )
        });
        vm.prank(_ATOMIST);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("E_InsufficientCash()"))));
        PlasmaVault(_plasmaVault).execute(exits);
    }

    // ============ helpers ============

    /// @dev Allocates idle USDC to venue A (sub-account 0x01) and optionally B (0x02), sets the instant withdraw list
    function _allocate(uint256 amountA_, uint256 amountB_, bool useB_) private {
        FuseAction[] memory enter = new FuseAction[](useB_ ? 2 : 1);
        enter[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_USDC,
                    maxAmount: amountA_,
                    subAccount: _SUB_A
                })
            )
        });
        if (useB_) {
            enter[1] = FuseAction({
                fuse: _eulerSupplyFuse,
                data: abi.encodeWithSignature(
                    "enter((address,uint256,bytes1))",
                    EulerV2SupplyFuseEnterData({eulerVault: EULER_VAULT_USDC, maxAmount: amountB_, subAccount: _SUB_B})
                )
            });
        }
        vm.prank(_ATOMIST);
        PlasmaVault(_plasmaVault).execute(enter);
        assertEq(ERC20(_USDC).balanceOf(_plasmaVault), 0, "no idle USDC");

        InstantWithdrawalFusesParamsStruct[] memory iw = new InstantWithdrawalFusesParamsStruct[](useB_ ? 2 : 1);
        iw[0] = InstantWithdrawalFusesParamsStruct({
            fuse: _eulerSupplyFuse,
            params: _iwParams(EULER_VAULT_PRIME_USDC, _SUB_A)
        });
        if (useB_) {
            iw[1] = InstantWithdrawalFusesParamsStruct({
                fuse: _eulerSupplyFuse,
                params: _iwParams(EULER_VAULT_USDC, _SUB_B)
            });
        }
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(iw);
    }

    function _subA() private view returns (address) {
        return EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_A);
    }

    function _subB() private view returns (address) {
        return EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_B);
    }

    /// @dev Sum of EulerV2SupplyExitFuse amounts emitted by the vault for the given EVault
    function _exitAmount(Vm.Log[] memory logs_, address eulerVault_) private view returns (uint256 total) {
        bytes32 topic = keccak256("EulerV2SupplyExitFuse(address,address,uint256,address)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) {
                (, address eulerVault, uint256 amount, ) = abi.decode(
                    logs_[i].data,
                    (address, address, uint256, address)
                );
                if (eulerVault == eulerVault_) total += amount;
            }
        }
    }

    function _failedCount(Vm.Log[] memory logs_) private view returns (uint256 count) {
        bytes32 topic = keccak256("EulerV2SupplyFuseExitFailed(address,address,uint256,address)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == _plasmaVault && logs_[i].topics[0] == topic) ++count;
        }
    }

    function _iwParams(address eulerVault_, bytes1 subAccount_) private pure returns (bytes32[] memory params) {
        params = new bytes32[](3);
        params[0] = bytes32(0);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(eulerVault_);
        params[2] = bytes32(subAccount_);
    }

    /// @dev Lifts supply/borrow caps through the real EVault governor (low-level: no interface declared in tests)
    function _liftCaps(address eVault_) private {
        /* solhint-disable avoid-low-level-calls */
        (bool okGov, bytes memory govData) = eVault_.staticcall(abi.encodeWithSignature("governorAdmin()"));
        require(okGov, "governorAdmin failed");
        vm.prank(abi.decode(govData, (address)));
        (bool okCaps, ) = eVault_.call(abi.encodeWithSignature("setCaps(uint16,uint16)", uint16(0), uint16(0)));
        require(okCaps, "setCaps failed");
        /* solhint-enable avoid-low-level-calls */
    }

    /// @dev eUSDC-1 has no governor, no oracle and no LTV, so its cash cannot be borrowed away. EVK keeps `cash` as a
    ///      uint112 at bit 48 of storage slot 2 (the slot also holds the 48-bit lastInterestAccumulatorUpdate and the
    ///      caps); overwrite it to model a venue whose free cash is low. `withdraw` only checks and decrements it.
    function _setEVaultCash(address eVault_, uint256 cash_) private {
        bytes32 slot = bytes32(uint256(2));
        uint256 packed = uint256(vm.load(eVault_, slot));
        uint256 mask = ((uint256(1) << 112) - 1) << 48;
        vm.store(eVault_, slot, bytes32((packed & ~mask) | (cash_ << 48)));
    }

    /// @dev Models a venue with low free cash and an intact position value: moves `cash - cashLeft_` from `cash` to
    ///      `totalBorrows`, so `totalAssets = cash + totalBorrows` is preserved. EVK storage: slot 2 holds `cash` as a
    ///      uint112 at bit 48; slot 3 holds `totalShares` (uint112, bit 0) and `totalBorrows` (Owed, uint144, bit 112)
    ///      scaled by 2^31 (INTERNAL_DEBT_PRECISION_SHIFT). The borrows are asserted to read back as raised.
    function _rebookCashAsBorrows(address eVault_, uint256 cashLeft_) private {
        uint256 cashBefore = IBorrowing(eVault_).cash();
        uint256 borrowsBefore = IBorrowing(eVault_).totalBorrows();
        uint256 totalAssetsBefore = IERC4626(eVault_).totalAssets();
        uint256 moved = cashBefore - cashLeft_;

        bytes32 slot3 = bytes32(uint256(3));
        uint256 packed = uint256(vm.load(eVault_, slot3));
        uint256 owed = packed >> 112;
        vm.store(eVault_, slot3, bytes32((packed & ((uint256(1) << 112) - 1)) | ((owed + (moved << 31)) << 112)));
        _setEVaultCash(eVault_, cashLeft_);

        assertEq(IBorrowing(eVault_).cash(), cashLeft_, "rebook: cash");
        assertApproxEqAbs(IBorrowing(eVault_).totalBorrows(), borrowsBefore + moved, 1, "rebook: totalBorrows");
        assertApproxEqAbs(IERC4626(eVault_).totalAssets(), totalAssetsBefore, 1, "rebook: totalAssets preserved");
    }

    /// @dev An unrelated borrower posts WETH collateral and borrows USDC until `cashLeft_` remains in the EVault
    function _drainCash(address eVault_, uint256 cashLeft_) private {
        address borrower = makeAddr(string.concat("borrower", vm.toString(eVault_)));
        uint256 collateral = 200_000e18;
        deal(_W_ETH, borrower, collateral);

        uint256 borrowAmount = IBorrowing(eVault_).cash() - cashLeft_;

        vm.startPrank(borrower);
        ERC20(_W_ETH).approve(EULER_VAULT_WETH, collateral);
        IERC4626(EULER_VAULT_WETH).deposit(collateral, borrower);
        IEVC(_EVC).enableCollateral(borrower, EULER_VAULT_WETH);
        IEVC(_EVC).enableController(borrower, eVault_);
        IBorrowing(eVault_).borrow(borrowAmount, borrower);
        vm.stopPrank();
    }

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = _USDC;
        sources[0] = _USDC_USD_CHAINLINK;
        priceOracle.setAssetsPricesSources(assets, sources);
        return address(priceOracle);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _eulerSupplyFuse = address(new EulerV2SupplyFuse(IporFusionMarkets.EULER_V2, _EVC));
        fuses = new address[](1);
        fuses[0] = _eulerSupplyFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.EULER_V2,
            address(new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, _EVC))
        );
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
    }

    function _setupMarketConfigsErc20() private pure returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
    }

    function _grantEulerSubstrates() private {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_PRIME_USDC,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_A
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: EULER_VAULT_USDC, isCollateral: false, canBorrow: false, subAccounts: _SUB_B})
        );
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](2);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }
}
