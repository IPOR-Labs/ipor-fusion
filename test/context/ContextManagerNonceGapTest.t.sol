// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ContextManager, ContextDataWithSender} from "../../contracts/managers/context/ContextManager.sol";

/// @dev Minimal approved target accepting the context lifecycle calls without access control.
contract NonceGapTarget {
    uint256 public lastValue;
    uint256 public calls;

    function setupContext(address) external {}

    function clearContext() external {}

    function record(uint256 value_) external {
        lastValue = value_;
        ++calls;
    }
}

/// @title ContextManagerNonceGapTest
/// @notice IL-9640 (L09): pins the intended nonce semantics of `ContextManager.runWithContextAndSignature`.
/// @dev Nonces only have to be strictly higher than the stored one (gaps are allowed). Consequently a higher nonce
///      invalidates every unused lower one, and the signed digest does not bind the submitter, so a third party can
///      submit a later signed request first and thereby cancel the earlier ones. A cancelled request can be signed
///      again under a fresh, higher nonce. This is the documented "cancel with a higher nonce" mechanism (IL-5032,
///      NatSpec of the function); making nonces sequential would be a separate, breaking change. Pinning test:
///      it passes on the base commit as well.
contract ContextManagerNonceGapTest is Test {
    ContextManager private _contextManager;
    NonceGapTarget private _target;
    Vm.Wallet private _signer;

    function setUp() public {
        _target = new NonceGapTarget();
        address[] memory targets = new address[](1);
        targets[0] = address(_target);
        _contextManager = new ContextManager(makeAddr("authority"), targets);
        _signer = vm.createWallet("nonceGapSigner");
    }

    /// @notice A gap in the nonce sequence is accepted and the stored nonce jumps to the submitted value.
    function testNonceGapIsAccepted() public {
        assertEq(_contextManager.getNonce(_signer.addr), 0);

        _contextManager.runWithContextAndSignature(_signed(5, 111));

        assertEq(_contextManager.getNonce(_signer.addr), 5);
        assertEq(_target.lastValue(), 111);
        assertEq(_target.calls(), 1);
    }

    /// @notice After a higher nonce is used, every lower unused nonce and the used one revert with NonceTooLow.
    function testLowerNoncesRevertAfterHigherNonceUsed() public {
        ContextDataWithSender[] memory low1 = _signed(1, 1);
        ContextDataWithSender[] memory low3 = _signed(3, 3);
        ContextDataWithSender[] memory high = _signed(10, 10);

        _contextManager.runWithContextAndSignature(high);

        vm.expectRevert(ContextManager.NonceTooLow.selector);
        _contextManager.runWithContextAndSignature(low1);

        vm.expectRevert(ContextManager.NonceTooLow.selector);
        _contextManager.runWithContextAndSignature(low3);

        // The same nonce is not reusable either
        vm.expectRevert(ContextManager.NonceTooLow.selector);
        _contextManager.runWithContextAndSignature(high);

        assertEq(_contextManager.getNonce(_signer.addr), 10);
        assertEq(_target.calls(), 1);
        assertEq(_target.lastValue(), 10);
    }

    /// @notice A third party (not the signer) can submit the later signed request first and so cancel the earlier one.
    function testThirdPartyCanSubmitLaterRequestFirstAndCancelEarlier() public {
        ContextDataWithSender[] memory earlier = _signed(1, 1);
        ContextDataWithSender[] memory later = _signed(2, 2);

        address thirdParty = makeAddr("thirdParty");
        vm.prank(thirdParty);
        _contextManager.runWithContextAndSignature(later);

        // The later request ran as the signer intended
        assertEq(_target.lastValue(), 2);
        assertEq(_contextManager.getNonce(_signer.addr), 2);

        // The earlier request is now cancelled
        vm.expectRevert(ContextManager.NonceTooLow.selector);
        _contextManager.runWithContextAndSignature(earlier);

        assertEq(_target.calls(), 1);
    }

    /// @notice A cancelled request can be signed again under a fresh higher nonce and then executes.
    function testCancelledRequestCanBeResignedWithHigherNonce() public {
        _contextManager.runWithContextAndSignature(_signed(2, 2));

        ContextDataWithSender[] memory cancelled = _signed(1, 1);
        vm.expectRevert(ContextManager.NonceTooLow.selector);
        _contextManager.runWithContextAndSignature(cancelled);

        // Same call data (value 1) re-signed with nonce 3
        _contextManager.runWithContextAndSignature(_signed(3, 1));

        assertEq(_target.lastValue(), 1);
        assertEq(_target.calls(), 2);
        assertEq(_contextManager.getNonce(_signer.addr), 3);
    }

    /// @notice Nonces are tracked per signer: another signer's nonce is unaffected by the first signer's jump.
    function testNonceIsPerSigner() public {
        _contextManager.runWithContextAndSignature(_signed(100, 1));

        Vm.Wallet memory other = vm.createWallet("nonceGapOther");
        _contextManager.runWithContextAndSignature(_signedBy(other, 1, 2));

        assertEq(_contextManager.getNonce(_signer.addr), 100);
        assertEq(_contextManager.getNonce(other.addr), 1);
    }

    function _signed(uint256 nonce_, uint256 value_) private returns (ContextDataWithSender[] memory) {
        return _signedBy(_signer, nonce_, value_);
    }

    function _signedBy(
        Vm.Wallet memory wallet_,
        uint256 nonce_,
        uint256 value_
    ) private returns (ContextDataWithSender[] memory out) {
        uint256 expiration = block.timestamp + 1 days;
        bytes memory callData = abi.encodeCall(NonceGapTarget.record, (value_));
        bytes32 digest = keccak256(
            abi.encodePacked(address(_contextManager), expiration, nonce_, block.chainid, address(_target), callData)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet_.privateKey, digest);
        out = new ContextDataWithSender[](1);
        out[0] = ContextDataWithSender({
            sender: wallet_.addr,
            expirationTime: expiration,
            nonce: nonce_,
            target: address(_target),
            data: callData,
            signature: abi.encodePacked(r, s, v)
        });
    }
}
