// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CrosschainNavValidationPreHook} from "contracts/handlers/pre_hooks/pre_hooks/CrosschainNavValidationPreHook.sol";
import {CrosschainSubstrateLib} from "contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";

/// @dev Succeeds on any call and returns empty data (shorter than any ABI type).
contract EmptyReturnMock {
    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// @dev Vault mock returning a single configured substrate.
contract SubstrateVaultMock {
    bytes32[] internal _substrates;

    constructor(bytes32 substrate_) {
        _substrates.push(substrate_);
    }

    function getMarketSubstrates(uint256) external view returns (bytes32[] memory) {
        return _substrates;
    }
}

/// @dev Executor mock whose `MANAGER()` returns 31 bytes.
contract ShortManagerExecutorMock {
    fallback() external {
        assembly {
            mstore(0, 0)
            return(0, 31)
        }
    }
}

/// @dev Executor mock with a valid `MANAGER()` and an empty `getBalance()` return.
contract EmptyBalanceExecutorMock {
    address public immutable MANAGER;

    constructor(address manager_) {
        MANAGER = manager_;
    }

    fallback() external {
        assembly {
            return(0, 0)
        }
    }
}

/// @title CrosschainNavHealthMalformedReturnTest
/// @notice Pins IL-9118: `isNavHealthy` reverts (does not return false) when a probed read succeeds with malformed
///         returndata, because `try ... returns` does not catch decode failures.
contract CrosschainNavHealthMalformedReturnTest is Test {
    uint256 private constant MARKET_ID = 41;

    CrosschainNavValidationPreHook internal hook;

    function setUp() public {
        hook = new CrosschainNavValidationPreHook(MARKET_ID);
    }

    function _probe(address vault_) internal view returns (bool ok_, bytes memory ret_) {
        (ok_, ret_) = address(hook).staticcall(abi.encodeCall(hook.isNavHealthy, (vault_)));
    }

    function testEmptyGetMarketSubstratesReturnReverts() public {
        address vault = address(new EmptyReturnMock());
        (bool ok, bytes memory ret) = _probe(vault);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function testShortManagerReturnReverts() public {
        address executor = address(new ShortManagerExecutorMock());
        address vault = address(new SubstrateVaultMock(CrosschainSubstrateLib.executorSubstrate(executor)));
        (bool ok, bytes memory ret) = _probe(vault);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function testEmptyGetBalanceReturnReverts() public {
        // The executor needs the vault as MANAGER, so predict the vault address (deployed right after the executor).
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address executor = address(new EmptyBalanceExecutorMock(predictedVault));
        address vault = address(new SubstrateVaultMock(CrosschainSubstrateLib.executorSubstrate(executor)));
        assertEq(vault, predictedVault);
        (bool ok, bytes memory ret) = _probe(vault);
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    function testCodelessAddressesReturnFalseWithoutRevert() public {
        (bool ok, bytes memory ret) = _probe(address(0xBEEF));
        assertTrue(ok);
        assertFalse(abi.decode(ret, (bool)));

        address vault = address(new SubstrateVaultMock(CrosschainSubstrateLib.executorSubstrate(address(0xCAFE))));
        (ok, ret) = _probe(vault);
        assertTrue(ok);
        assertFalse(abi.decode(ret, (bool)));
    }
}
