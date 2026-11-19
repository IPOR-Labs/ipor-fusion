// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Errors as EVCErrors} from "ethereum-vault-connector/src/Errors.sol";
import {CallbackHandlerEuler} from "../../../contracts/handlers/callbacks/CallbackHandlerEuler.sol";
import {CallbackData} from "../../../contracts/libraries/CallbackHandlerLib.sol";
import {Errors} from "../../../contracts/libraries/errors/Errors.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";

/// @dev EVC stand-in: `getCurrentOnBehalfOfAccount` returns the account set by the test and, like the real EVC,
///      reverts when no account is authenticated (a call outside an EVC call or batch)
contract CallbackHandlerEulerTestEvc {
    address public onBehalfOfAccount;
    bool public isOperatorAuthenticated;
    bool public isControlCollateralInProgress;

    function setOnBehalfOfAccount(address account_) external {
        onBehalfOfAccount = account_;
    }

    function setOperatorAuthenticated(bool value_) external {
        isOperatorAuthenticated = value_;
    }

    function setControlCollateralInProgress(bool value_) external {
        isControlCollateralInProgress = value_;
    }

    function getCurrentOnBehalfOfAccount(address) external view returns (address, bool) {
        if (onBehalfOfAccount == address(0)) {
            revert EVCErrors.EVC_OnBehalfOfAccountNotAuthenticated();
        }
        return (onBehalfOfAccount, false);
    }
}

/// @title CallbackHandlerEulerTest
/// @notice Unit test (IL-9253, GLM C-011/C-016/C-028, Codex C-003/C-049): CallbackHandlerEuler returns the callback
///         payload only when the EVC on-behalf-of account shares the calling vault's 19-byte address prefix
contract CallbackHandlerEulerTest is Test {
    /// @dev An address with a zero last byte, so `_VAULT ^ id` covers every sub-account id
    address private constant _VAULT = 0x1234567890ABCdeF1234567890aBCDEF12345600;
    address private constant _ASSET = address(0xA55E7);
    address private constant _SPENDER = address(0x5BE4DE4);

    CallbackHandlerEulerTestEvc private _evc;
    CallbackHandlerEuler private _handler;

    function setUp() public {
        _evc = new CallbackHandlerEulerTestEvc();
        _handler = new CallbackHandlerEuler(address(_evc));
    }

    function testShouldRevertWhenEvcIsZeroAddress() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new CallbackHandlerEuler(address(0));
    }

    function testShouldExposeEvc() public view {
        assertEq(address(_handler.EVC()), address(_evc), "EVC getter");
    }

    /// @notice The registration key stays (EVC, 0xc555e119); EVK `flashLoan` calls `onFlashLoan(bytes)` (0xc4850ea8),
    ///         which is a different selector, so the only legitimate source of `onEulerFlashLoan` is a batch item
    function testShouldKeepCallbackSelector() public pure {
        assertEq(CallbackHandlerEuler.onEulerFlashLoan.selector, bytes4(0xc555e119), "onEulerFlashLoan selector");
        assertEq(bytes4(keccak256("onFlashLoan(bytes)")), bytes4(0xc4850ea8), "EVK onFlashLoan selector");
    }

    function testShouldReturnPayloadWhenAccountIsTheVault() public {
        _evc.setOnBehalfOfAccount(_VAULT);

        vm.prank(_VAULT);
        CallbackData memory result = _handler.onEulerFlashLoan(_payload());

        _assertPayload(result);
    }

    function testShouldReturnPayloadWhenAccountIsTheLastSubAccount() public {
        _evc.setOnBehalfOfAccount(address(uint160(_VAULT) ^ 0xFF));

        vm.prank(_VAULT);
        CallbackData memory result = _handler.onEulerFlashLoan(_payload());

        _assertPayload(result);
    }

    function testFuzzShouldReturnPayloadForEverySubAccountOfTheVault(uint8 subAccountId_) public {
        _evc.setOnBehalfOfAccount(address(uint160(_VAULT) ^ uint160(subAccountId_)));

        vm.prank(_VAULT);
        CallbackData memory result = _handler.onEulerFlashLoan(_payload());

        _assertPayload(result);
    }

    /// @notice The first account outside the vault's prefix (bit 8 flipped) is rejected
    function testShouldRevertWhenAccountDiffersFromTheVaultInBitEight() public {
        address account = address(uint160(_VAULT) ^ 0x100);
        _evc.setOnBehalfOfAccount(account);

        vm.expectRevert(
            abi.encodeWithSelector(CallbackHandlerEuler.CallbackHandlerEulerUnauthorizedOrigin.selector, account)
        );
        vm.prank(_VAULT);
        _handler.onEulerFlashLoan(_payload());
    }

    /// @notice An outside contract that authenticated for its own account (the SupplyFuse.exit route) is rejected
    function testShouldRevertWhenAccountIsAForeignContract() public {
        address foreign = makeAddr("foreignEulerVault");
        _evc.setOnBehalfOfAccount(foreign);

        vm.expectRevert(
            abi.encodeWithSelector(CallbackHandlerEuler.CallbackHandlerEulerUnauthorizedOrigin.selector, foreign)
        );
        vm.prank(_VAULT);
        _handler.onEulerFlashLoan(_payload());
    }

    /// @notice The check binds the account to `msg.sender`: a vault account is rejected when another caller asks
    function testShouldRevertWhenCallerIsNotTheVaultOfTheAccount() public {
        address otherVault = makeAddr("otherVault");
        _evc.setOnBehalfOfAccount(_VAULT);

        vm.expectRevert(
            abi.encodeWithSelector(CallbackHandlerEuler.CallbackHandlerEulerUnauthorizedOrigin.selector, _VAULT)
        );
        vm.prank(otherVault);
        _handler.onEulerFlashLoan(_payload());
    }

    function testFuzzShouldRevertWhenAccountIsOutsideTheVaultPrefix(address account_) public {
        vm.assume(account_ != address(0));
        vm.assume((uint160(account_) ^ uint160(_VAULT)) >= 0x100);
        _evc.setOnBehalfOfAccount(account_);

        vm.expectRevert(
            abi.encodeWithSelector(CallbackHandlerEuler.CallbackHandlerEulerUnauthorizedOrigin.selector, account_)
        );
        vm.prank(_VAULT);
        _handler.onEulerFlashLoan(_payload());
    }

    /// @notice IL-9697: an operator-authenticated call is rejected even for an account with the vault prefix
    function testShouldRevertWhenOperatorIsAuthenticated() public {
        _evc.setOnBehalfOfAccount(address(uint160(_VAULT) ^ 1));
        _evc.setOperatorAuthenticated(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                CallbackHandlerEuler.CallbackHandlerEulerUnauthorizedOrigin.selector,
                address(uint160(_VAULT) ^ 1)
            )
        );
        vm.prank(_VAULT);
        _handler.onEulerFlashLoan(_payload());
    }

    /// @notice IL-9697: a `controlCollateral` call is rejected even for an account with the vault prefix
    function testShouldRevertWhenControlCollateralIsInProgress() public {
        _evc.setOnBehalfOfAccount(_VAULT);
        _evc.setControlCollateralInProgress(true);

        vm.expectRevert(
            abi.encodeWithSelector(CallbackHandlerEuler.CallbackHandlerEulerUnauthorizedOrigin.selector, _VAULT)
        );
        vm.prank(_VAULT);
        _handler.onEulerFlashLoan(_payload());
    }

    /// @notice Outside an EVC call or batch the EVC has no authenticated account and the handler fails closed
    function testShouldRevertWhenEvcHasNoAuthenticatedAccount() public {
        vm.expectRevert(EVCErrors.EVC_OnBehalfOfAccountNotAuthenticated.selector);
        vm.prank(_VAULT);
        _handler.onEulerFlashLoan(_payload());
    }

    function _payload() private pure returns (bytes memory) {
        return
            abi.encode(
                CallbackData({
                    asset: _ASSET,
                    addressToApprove: _SPENDER,
                    amountToApprove: 123e6,
                    actionData: abi.encode(new FuseAction[](0))
                })
            );
    }

    function _assertPayload(CallbackData memory result_) private pure {
        assertEq(result_.asset, _ASSET, "asset");
        assertEq(result_.addressToApprove, _SPENDER, "addressToApprove");
        assertEq(result_.amountToApprove, 123e6, "amountToApprove");
        assertEq(keccak256(result_.actionData), keccak256(abi.encode(new FuseAction[](0))), "actionData");
    }
}
