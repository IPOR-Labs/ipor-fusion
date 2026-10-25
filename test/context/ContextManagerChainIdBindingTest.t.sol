// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ContextManager, ContextDataWithSender} from "../../contracts/managers/context/ContextManager.sol";

/// @dev Minimal approved target accepting the context lifecycle calls without access control.
contract ChainIdBindingTarget {
    uint256 public pings;

    function setupContext(address) external {}

    function clearContext() external {}

    function ping() external {
        ++pings;
    }
}

/// @title ContextManagerChainIdBindingTest
/// @notice IL-8981: the signed digest binds block.chainid at execution time, not the deployment-time CHAIN_ID.
contract ContextManagerChainIdBindingTest is Test {
    ContextManager private _contextManager;
    ChainIdBindingTarget private _target;
    Vm.Wallet private _signer;
    uint256 private _deploymentChainId;

    function setUp() public {
        _deploymentChainId = block.chainid;
        _target = new ChainIdBindingTarget();
        address[] memory targets = new address[](1);
        targets[0] = address(_target);
        _contextManager = new ContextManager(makeAddr("authority"), targets);
        _signer = vm.createWallet("chainIdSigner");
    }

    function testSignatureValidOnDeploymentChain() public {
        ContextDataWithSender[] memory data = _signed(_deploymentChainId, 1);

        _contextManager.runWithContextAndSignature(data);

        assertEq(_target.pings(), 1);
        assertEq(_contextManager.getNonce(_signer.addr), 1);
        assertEq(_contextManager.CHAIN_ID(), _deploymentChainId);
    }

    function testSignatureRejectedAfterChainIdFork() public {
        ContextDataWithSender[] memory data = _signed(_deploymentChainId, 1);

        vm.chainId(_deploymentChainId + 1);

        vm.expectRevert(ContextManager.InvalidSignature.selector);
        _contextManager.runWithContextAndSignature(data);

        assertEq(_target.pings(), 0);
        assertEq(_contextManager.getNonce(_signer.addr), 0);
    }

    function testSignatureForNewChainIdAcceptedAfterFork() public {
        vm.chainId(_deploymentChainId + 1);
        ContextDataWithSender[] memory data = _signed(_deploymentChainId + 1, 1);

        _contextManager.runWithContextAndSignature(data);

        assertEq(_target.pings(), 1);
        assertEq(_contextManager.getNonce(_signer.addr), 1);
        // CHAIN_ID stays the deployment-time value
        assertEq(_contextManager.CHAIN_ID(), _deploymentChainId);
    }

    function _signed(uint256 chainId_, uint256 nonce_) private returns (ContextDataWithSender[] memory out) {
        uint256 expiration = block.timestamp + 1 days;
        bytes memory callData = abi.encodeCall(ChainIdBindingTarget.ping, ());
        bytes32 digest = keccak256(
            abi.encodePacked(address(_contextManager), expiration, nonce_, chainId_, address(_target), callData)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signer.privateKey, digest);
        out = new ContextDataWithSender[](1);
        out[0] = ContextDataWithSender({
            sender: _signer.addr,
            expirationTime: expiration,
            nonce: nonce_,
            target: address(_target),
            data: callData,
            signature: abi.encodePacked(r, s, v)
        });
    }
}
