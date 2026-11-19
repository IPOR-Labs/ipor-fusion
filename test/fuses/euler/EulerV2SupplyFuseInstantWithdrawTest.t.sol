// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseExitData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

/// @title EulerV2SupplyFuseInstantWithdrawTest
/// @notice Unit tests for instant withdraw functionality in EulerV2SupplyFuse
contract EulerV2SupplyFuseInstantWithdrawTest is Test {
    // ============ Constants ============

    uint256 public constant MARKET_ID = 1;
    address public constant MOCK_EVC = address(0x1234);
    address public constant MOCK_EULER_VAULT = address(0x5678);
    address public constant MOCK_ASSET = address(0x9ABC);
    bytes1 public constant SUB_ACCOUNT = 0x01;

    // ============ State Variables ============

    EulerV2SupplyFuse public fuse;
    PlasmaVaultMock public vault;
    address public subAccountAddress;

    // ============ Events ============

    event EulerV2SupplyExitFuse(address version, address eulerVault, uint256 withdrawnAmount, address subAccount);
    event EulerV2SupplyFuseExitFailed(address version, address eulerVault, uint256 amount, address subAccount);

    // ============ Errors ============

    /// @dev Distinctive error returned by the mocked EVC to prove the exact failure is propagated
    error MockEvcFailure(uint256 amount);

    // ============ Setup ============

    function setUp() public {
        // Deploy fuse
        fuse = new EulerV2SupplyFuse(MARKET_ID, MOCK_EVC);

        // Deploy mock vault
        vault = new PlasmaVaultMock(address(fuse), address(0));

        // Calculate sub-account address
        subAccountAddress = EulerFuseLib.generateSubAccountAddress(address(vault), SUB_ACCOUNT);

        // Label addresses
        vm.label(address(fuse), "EulerV2SupplyFuse");
        vm.label(address(vault), "PlasmaVaultMock");
        vm.label(MOCK_EVC, "MockEVC");
        vm.label(MOCK_EULER_VAULT, "MockEulerVault");
        vm.label(subAccountAddress, "SubAccount");

        // By default the Euler vault is not enabled as collateral of the sub-account in the EVC
        _mockCollateralEnabled(false);
    }

    // ============ Constructor Tests ============

    function testShouldSetVersionToDeploymentAddress() public view {
        assertEq(fuse.VERSION(), address(fuse));
    }

    function testShouldSetMarketIdCorrectly() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
    }

    function testShouldSetEVCCorrectly() public view {
        assertEq(address(fuse.EVC()), MOCK_EVC);
    }

    // ============ InstantWithdraw Tests - Validation ============

    function testShouldSkipInstantWithdrawWhenIsCollateralTrue() public {
        // given - Setup substrate with isCollateral=true, canBorrow=false
        _setupSubstrate(true, false);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // when/then - Should skip (return 0, no revert) because isCollateral is true
        _assertInstantWithdrawSkipped(params);
    }

    function testShouldSkipInstantWithdrawWhenCanBorrowTrue() public {
        // given - Setup substrate with isCollateral=false, canBorrow=true
        _setupSubstrate(false, true);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // when/then - Should skip (return 0, no revert) because canBorrow is true
        _assertInstantWithdrawSkipped(params);
    }

    function testShouldSkipInstantWithdrawWhenBothFlagsTrue() public {
        // given - Setup substrate with both flags true
        _setupSubstrate(true, true);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // when/then - Should skip (return 0, no revert) because both flags are true
        _assertInstantWithdrawSkipped(params);
    }

    function testShouldReturnZeroWhenAmountIsZero() public {
        // given - Setup valid substrate but zero amount
        _setupSubstrate(false, false);

        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(uint256(0)); // zero amount
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // when - Should complete without revert
        vault.instantWithdraw(params);

        // then - No event should be emitted (checked by absence of expectEmit)
    }

    // ============ Success Cases ============

    function testShouldInstantWithdrawSuccessfullyWhenNotCollateralAndNotBorrowable() public {
        // given - Setup valid substrate for instant withdraw
        _setupSubstrate(false, false);

        uint256 amount = 1000e18;
        uint256 sharesAmount = 900e18; // Simulate some shares balance
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // Mock vault to return balance
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(sharesAmount)
        );

        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", sharesAmount),
            abi.encode(amount)
        );

        _mockCash(amount);

        // Mock successful EVC.call
        vm.mockCall(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode(abi.encode(amount))
        );

        // when/then - Should succeed without revert
        vm.expectEmit(true, false, false, true);
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, amount, subAccountAddress);

        vault.instantWithdraw(params);
    }

    function testShouldWithdrawPartialAmountWhenInsufficientBalance() public {
        // given - Setup valid substrate
        _setupSubstrate(false, false);

        uint256 requestedAmount = 1000e18;
        uint256 availableShares = 500e18; // Only half available
        uint256 availableAssets = 500e18;

        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(requestedAmount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // Mock vault to return limited balance
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(availableShares)
        );

        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", availableShares),
            abi.encode(availableAssets)
        );

        _mockCash(requestedAmount);

        // Mock successful EVC.call with partial amount
        vm.mockCall(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode(abi.encode(availableAssets))
        );

        // when/then - Should withdraw only available amount
        vm.expectEmit(true, false, false, true);
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, availableAssets, subAccountAddress);

        vault.instantWithdraw(params);
    }

    function testShouldEmitExitEventOnSuccess() public {
        // given - Setup valid substrate
        _setupSubstrate(false, false);

        uint256 amount = 750e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // Mock vault responses
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(amount)
        );

        vm.mockCall(MOCK_EULER_VAULT, abi.encodeWithSignature("convertToAssets(uint256)", amount), abi.encode(amount));

        _mockCash(amount);

        // Mock successful EVC.call
        vm.mockCall(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode(abi.encode(amount))
        );

        // when/then - Should emit success event with correct parameters
        vm.expectEmit(true, true, true, true);
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, amount, subAccountAddress);

        vault.instantWithdraw(params);
    }

    // ============ Exit Comparison Tests ============

    function testShouldNotRevertOnExternalFailureInInstantWithdraw() public {
        // given - Setup valid substrate for instant withdraw
        _setupSubstrate(false, false);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        // Mock vault to return balance
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(amount)
        );

        vm.mockCall(MOCK_EULER_VAULT, abi.encodeWithSignature("convertToAssets(uint256)", amount), abi.encode(amount));

        _mockCash(amount);

        // Mock EVC.call to revert
        vm.mockCallRevert(
            MOCK_EVC,
            abi.encodeWithSignature("call(address,address,uint256,bytes)"),
            abi.encode("Withdrawal failed")
        );

        // when/then - Should NOT revert, but emit failure event
        vm.expectEmit(true, false, false, true);
        emit EulerV2SupplyFuseExitFailed(address(fuse), MOCK_EULER_VAULT, amount, subAccountAddress);

        vault.instantWithdraw(params);
    }

    /// @notice The cash() read sits outside the try/catch (documented in EulerV2SupplyFuse._exit): a venue whose
    ///         cash() reverts makes the instant withdraw revert and is not reported as an ExitFailed event
    function testShouldRevertInstantWithdrawWhenCashReadReverts() public {
        // given
        _setupSubstrate(false, false);

        uint256 amount = 1000e18;
        bytes32[] memory params = new bytes32[](3);
        params[0] = bytes32(amount);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);

        _mockPosition(amount, amount);
        vm.mockCallRevert(MOCK_EULER_VAULT, abi.encodeWithSignature("cash()"), abi.encode("cash reverted"));

        // when
        vm.recordLogs();
        vm.expectRevert(abi.encode("cash reverted"));
        vault.instantWithdraw(params);

        // then - nothing was emitted, in particular no EulerV2SupplyFuseExitFailed
        assertEq(vm.getRecordedLogs().length, 0, "no event on a reverting cash() read");
    }

    function testShouldRevertOnExternalFailureInNormalExit() public {
        // given - exit data for a position held by the sub-account derived from the vault (delegatecall context)
        uint256 amount = 1000e18;
        EulerV2SupplyFuseExitData memory exitData = EulerV2SupplyFuseExitData({
            eulerVault: MOCK_EULER_VAULT,
            maxAmount: amount,
            subAccount: SUB_ACCOUNT
        });

        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(amount)
        );
        vm.mockCall(MOCK_EULER_VAULT, abi.encodeWithSignature("convertToAssets(uint256)", amount), abi.encode(amount));

        // EVC.call for exactly this withdraw fails with a distinctive custom error
        bytes memory withdrawCall = abi.encodeWithSelector(
            bytes4(keccak256("withdraw(uint256,address,address)")),
            amount,
            address(vault),
            subAccountAddress
        );
        vm.mockCallRevert(
            MOCK_EVC,
            abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall)),
            abi.encodeWithSelector(MockEvcFailure.selector, amount)
        );
        // the normal branch must actually reach EVC.call
        vm.expectCall(MOCK_EVC, abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall)));

        // when/then - normal exit has no try/catch: the exact EVC error bubbles up and no exit event is emitted
        vm.expectRevert(abi.encodeWithSelector(MockEvcFailure.selector, amount));
        vault.execute(address(fuse), abi.encodeWithSelector(EulerV2SupplyFuse.exit.selector, exitData));
    }

    // ============ EVault Cash Cap Tests ============

    function testShouldCapInstantWithdrawAtEulerVaultCash() public {
        // given - position 1000e18, request 1000e18, but the EVault only holds 400e18 of free cash
        _setupSubstrate(false, false);
        _mockPosition(1000e18, 1000e18);
        _mockCash(400e18);

        bytes memory evcCall = abi.encodeCall(
            IEVC.call,
            (MOCK_EULER_VAULT, subAccountAddress, 0, _withdrawCall(400e18))
        );
        vm.mockCall(MOCK_EVC, evcCall, abi.encode(""));

        // then - EVC.call carries the capped amount exactly once and the event reports it
        vm.expectCall(MOCK_EVC, evcCall, 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, 400e18, subAccountAddress);

        // when
        vault.instantWithdraw(_params(1000e18));
    }

    function testShouldEmitCappedAmountWhenCappedInstantWithdrawFails() public {
        // given - same capped situation, but the capped EVC.call fails
        _setupSubstrate(false, false);
        _mockPosition(1000e18, 1000e18);
        _mockCash(400e18);

        vm.mockCallRevert(
            MOCK_EVC,
            abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, _withdrawCall(400e18))),
            abi.encodeWithSelector(MockEvcFailure.selector, 400e18)
        );

        // when - the failure is swallowed
        vm.recordLogs();
        vault.instantWithdraw(_params(1000e18));

        // then - exactly one log, the failure event, carrying the capped amount; no success event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 vaultLogs;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            ++vaultLogs;
            assertEq(
                logs[i].topics[0],
                keccak256("EulerV2SupplyFuseExitFailed(address,address,uint256,address)"),
                "failure event expected"
            );
            assertNotEq(
                logs[i].topics[0],
                keccak256("EulerV2SupplyExitFuse(address,address,uint256,address)"),
                "no success event"
            );
            (address version, address eulerVault, uint256 amount, address subAccount) = abi.decode(
                logs[i].data,
                (address, address, uint256, address)
            );
            assertEq(version, address(fuse));
            assertEq(eulerVault, MOCK_EULER_VAULT);
            assertEq(amount, 400e18, "capped amount");
            assertEq(subAccount, subAccountAddress);
        }
        assertEq(vaultLogs, 1, "exactly one vault log");
    }

    function testShouldSkipInstantWithdrawWhenEulerVaultCashIsZero() public {
        // given - a position exists but the EVault has no free cash; EVC.call would succeed if it were reached
        _setupSubstrate(false, false);
        _mockPosition(1000e18, 1000e18);
        _mockCash(0);
        vm.mockCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), abi.encode(""));

        // then - no EVC call and no event
        vm.expectCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), 0);
        vm.recordLogs();

        // when
        vault.instantWithdraw(_params(1000e18));

        assertEq(vm.getRecordedLogs().length, 0, "no event when cash is zero");
    }

    /// @dev Pins D-009: `cash()` is read only when the amount after the position cap is non-zero
    function testShouldNotReadCashWhenPositionIsZero() public {
        // given - the request is non-zero but the sub-account holds no position; cash would cover the request
        _setupSubstrate(false, false);
        _mockPosition(0, 0);
        _mockCash(1000e18);
        vm.mockCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), abi.encode(""));

        // then - cash() is never read, EVC is never called
        vm.expectCall(MOCK_EULER_VAULT, abi.encodeWithSignature("cash()"), 0);
        vm.expectCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), 0);
        vm.recordLogs();

        // when
        vault.instantWithdraw(_params(1000e18));

        assertEq(vm.getRecordedLogs().length, 0, "no event when position is zero");
    }

    function testShouldNotUseMaxWithdrawForInstantWithdrawCap() public {
        // given - maxWithdraw reports 0 (EVK does so for accounts with an enabled controller), cash covers the request
        _setupSubstrate(false, false);
        _mockPosition(1000e18, 1000e18);
        _mockCash(1000e18);
        vm.mockCall(MOCK_EULER_VAULT, abi.encodeWithSignature("maxWithdraw(address)"), abi.encode(uint256(0)));

        bytes memory evcCall = abi.encodeCall(
            IEVC.call,
            (MOCK_EULER_VAULT, subAccountAddress, 0, _withdrawCall(1000e18))
        );
        vm.mockCall(MOCK_EVC, evcCall, abi.encode(""));

        // then - the full amount is withdrawn
        vm.expectCall(MOCK_EVC, evcCall, 1);

        // when
        vault.instantWithdraw(_params(1000e18));
    }

    function testShouldNotCapNormalExitAtEulerVaultCash() public {
        // given - position 1000e18 but the EVault only has 100e18 of free cash
        _mockPosition(1000e18, 1000e18);
        _mockCash(100e18);

        bytes memory withdrawCall = _withdrawCall(1000e18);
        bytes memory evcCall = abi.encodeCall(IEVC.call, (MOCK_EULER_VAULT, subAccountAddress, 0, withdrawCall));
        vm.mockCall(MOCK_EVC, evcCall, abi.encode(""));

        // then - the normal exit never reads cash() and withdraws the full position amount
        vm.expectCall(MOCK_EULER_VAULT, abi.encodeWithSignature("cash()"), 0);
        vm.expectCall(MOCK_EVC, evcCall, 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, 1000e18, subAccountAddress);

        // when
        vault.execute(
            address(fuse),
            abi.encodeWithSelector(
                EulerV2SupplyFuse.exit.selector,
                EulerV2SupplyFuseExitData({eulerVault: MOCK_EULER_VAULT, maxAmount: 1000e18, subAccount: SUB_ACCOUNT})
            )
        );
    }

    // ============ IL-9644 (L13): any-match flags and EVC collateral skip ============

    /// @notice A blocking entry granted after an unflagged entry of the same pair disables the instant withdraw
    function testShouldSkipInstantWithdrawWhenFlaggedEntryFollowsUnflaggedEntry() public {
        // given - one grant listing the pair twice: unflagged entry first, then an isCollateral entry
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: MOCK_EULER_VAULT,
                isCollateral: false,
                canBorrow: false,
                subAccounts: SUB_ACCOUNT
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: MOCK_EULER_VAULT,
                isCollateral: true,
                canBorrow: false,
                subAccounts: SUB_ACCOUNT
            })
        );
        vm.prank(address(vault));
        vault.grantMarketSubstrates(MARKET_ID, substrates);
        _mockPosition(1000e18, 1000e18);
        _mockCash(1000e18);

        // when/then
        _assertInstantWithdrawSkipped(_params(1000e18));
    }

    /// @notice The vault is enabled as collateral of the sub-account in the EVC: the instant path withdraws nothing,
    ///         does not revert (a user withdrawal must go on to the next fuse), calls no EVC.call and emits no event
    function testShouldSkipInstantWithdrawWithoutRevertWhenCollateralEnabledInEvc() public {
        // given
        _setupSubstrate(false, false);
        _mockPosition(1000e18, 1000e18);
        _mockCash(1000e18);
        _mockCollateralEnabled(true);
        vm.mockCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), abi.encode(""));

        // then - the EVC is asked about the sub-account and the vault, and withdraw is never attempted
        vm.expectCall(MOCK_EVC, abi.encodeCall(IEVC.isCollateralEnabled, (subAccountAddress, MOCK_EULER_VAULT)), 1);
        vm.expectCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), 0);
        vm.recordLogs();

        // when
        vault.instantWithdraw(_params(1000e18));

        // then
        assertEq(vm.getRecordedLogs().length, 0, "no event on the collateral skip");
    }

    /// @notice With collateral not enabled the instant path withdraws as before
    function testShouldWithdrawWhenCollateralNotEnabledInEvc() public {
        // given
        _setupSubstrate(false, false);
        _mockPosition(1000e18, 1000e18);
        _mockCash(1000e18);
        bytes memory evcCall = abi.encodeCall(
            IEVC.call,
            (MOCK_EULER_VAULT, subAccountAddress, 0, _withdrawCall(1000e18))
        );
        vm.mockCall(MOCK_EVC, evcCall, abi.encode(""));

        // then
        vm.expectCall(MOCK_EVC, evcCall, 1);
        vm.expectEmit(true, true, true, true, address(vault));
        emit EulerV2SupplyExitFuse(address(fuse), MOCK_EULER_VAULT, 1000e18, subAccountAddress);

        // when
        vault.instantWithdraw(_params(1000e18));
    }

    /// @notice The normal ALPHA exit is not affected by the EVC collateral state
    function testShouldExitEvenWhenCollateralEnabledInEvc() public {
        // given
        _mockPosition(1000e18, 1000e18);
        _mockCollateralEnabled(true);
        bytes memory evcCall = abi.encodeCall(
            IEVC.call,
            (MOCK_EULER_VAULT, subAccountAddress, 0, _withdrawCall(1000e18))
        );
        vm.mockCall(MOCK_EVC, evcCall, abi.encode(""));

        // then
        vm.expectCall(MOCK_EVC, evcCall, 1);

        // when
        vault.execute(
            address(fuse),
            abi.encodeWithSelector(
                EulerV2SupplyFuse.exit.selector,
                EulerV2SupplyFuseExitData({eulerVault: MOCK_EULER_VAULT, maxAmount: 1000e18, subAccount: SUB_ACCOUNT})
            )
        );
    }

    // ============ Gas bound on the instant path (IL-9719) ============

    /// @dev Mirrors EulerV2SupplyFuse.INSTANT_WITHDRAW_EVC_CALL_GAS_LIMIT (private constant)
    uint64 internal constant EVC_CALL_GAS_LIMIT = 500_000;

    function testShouldForwardBoundedGasToEvcCallOnInstantWithdraw() public {
        _setupSubstrate(false, false);
        uint256 amount = 1000e18;
        _mockPosition(amount, amount);
        _mockCash(amount);
        vm.mockCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), abi.encode(""));

        // the call must be made with exactly the bounded gas, not with all the gas left
        vm.expectCall(MOCK_EVC, 0, EVC_CALL_GAS_LIMIT, _evcCallData(amount));

        vault.instantWithdraw(_params(amount));
    }

    function testShouldCatchGasExhaustingEvcCallOnInstantWithdrawAndKeepGasForCaller() public {
        _setupSubstrate(false, false);
        uint256 amount = 1000e18;
        _mockPosition(amount, amount);
        _mockCash(amount);
        // an EVC whose call burns all the gas it gets, as a paused Euler vault does
        vm.etch(MOCK_EVC, address(new GasBurningEvc()).code);
        vm.mockCall(MOCK_EVC, abi.encodeWithSelector(IEVC.isCollateralEnabled.selector), abi.encode(false));

        vm.expectEmit(true, false, false, true);
        emit EulerV2SupplyFuseExitFailed(address(fuse), MOCK_EULER_VAULT, amount, subAccountAddress);

        uint256 gasBefore = gasleft();
        vault.instantWithdraw(_params(amount));
        uint256 gasUsed = gasBefore - gasleft();

        // bounded by the limit plus the fixed overhead of the fuse, far below the 30M block budget
        assertLt(gasUsed, uint256(EVC_CALL_GAS_LIMIT) + 400_000, "instant withdraw gas must be bounded");
        assertGe(gasUsed, EVC_CALL_GAS_LIMIT, "the failing call must have used its whole bound");
    }

    function _evcCallData(uint256 assets_) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(IEVC.call.selector, MOCK_EULER_VAULT, subAccountAddress, 0, _withdrawCall(assets_));
    }

    // ============ Helper Functions ============

    /// @dev A skipped instant withdraw does not revert, makes no EVC.call and emits no event
    function _assertInstantWithdrawSkipped(bytes32[] memory params_) internal {
        vm.mockCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), abi.encode(""));
        vm.expectCall(MOCK_EVC, abi.encodeWithSelector(IEVC.call.selector), 0);
        vm.recordLogs();
        vault.instantWithdraw(params_);
        assertEq(vm.getRecordedLogs().length, 0, "no event on skip");
    }

    function _mockCollateralEnabled(bool enabled_) internal {
        vm.mockCall(MOCK_EVC, abi.encodeWithSelector(IEVC.isCollateralEnabled.selector), abi.encode(enabled_));
    }

    function _mockCash(uint256 cash_) internal {
        vm.mockCall(MOCK_EULER_VAULT, abi.encodeWithSignature("cash()"), abi.encode(cash_));
    }

    function _mockPosition(uint256 shares_, uint256 assets_) internal {
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("balanceOf(address)", subAccountAddress),
            abi.encode(shares_)
        );
        vm.mockCall(
            MOCK_EULER_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", shares_),
            abi.encode(assets_)
        );
    }

    function _withdrawCall(uint256 assets_) internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                bytes4(keccak256("withdraw(uint256,address,address)")),
                assets_,
                address(vault),
                subAccountAddress
            );
    }

    function _params(uint256 amount_) internal pure returns (bytes32[] memory params) {
        params = new bytes32[](3);
        params[0] = bytes32(amount_);
        params[1] = PlasmaVaultConfigLib.addressToBytes32(MOCK_EULER_VAULT);
        params[2] = bytes32(SUB_ACCOUNT);
    }

    /// @notice Setup substrate configuration for testing
    /// @param isCollateral_ Whether vault can be used as collateral
    /// @param canBorrow_ Whether one can borrow against it
    function _setupSubstrate(bool isCollateral_, bool canBorrow_) internal {
        // Create substrate
        EulerSubstrate memory substrate = EulerSubstrate({
            eulerVault: MOCK_EULER_VAULT,
            isCollateral: isCollateral_,
            canBorrow: canBorrow_,
            subAccounts: SUB_ACCOUNT
        });

        // Convert to bytes32
        bytes32 substrateBytes = EulerFuseLib.substrateToBytes32(substrate);

        // Grant substrate to market
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = substrateBytes;

        vm.prank(address(vault));
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }
}

/// @dev EVC stand-in whose `call` loops until all forwarded gas is spent
contract GasBurningEvc {
    function call(address, address, uint256, bytes calldata) external payable returns (bytes memory) {
        while (true) {}
    }
}
