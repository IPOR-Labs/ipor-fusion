// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {MockRemoteVault} from "./MockRemoteVault.sol";
import {TrackedVaultPricingLib} from "../../../contracts/crosschain/lib/TrackedVaultPricingLib.sol";

/// @dev Delegatecall target that consumes all forwarded gas (INVALID), like a fuse that runs out of gas.
contract MockGasBurner {
    function burn() external pure {
        assembly {
            invalid()
        }
    }
}

/// @title MockGasBurnVault
/// @notice `MockRemoteVault` whose `deposit` can burn all gas at call depth `burnDepth` (24), revert with a decodable
///         business error, revert with `InsufficientGasForVaultRead`, do heavy honest work, burn all its gas and then
///         revert with a selector (TP-L-13), revert with a large payload, or run the gas burn through OpenZeppelin
///         `Address.functionDelegateCall`, which surfaces the empty revert as `FailedInnerCall()` (IL-8625).
contract MockGasBurnVault is MockRemoteVault {
    enum Mode {
        NORMAL,
        BURN_DEEP,
        BUSINESS_ERROR,
        VAULT_READ_GAS_ERROR,
        HEAVY,
        BURN_ALL_THEN_BUSINESS_ERROR,
        BIG_PAYLOAD_ERROR,
        OZ_FAILED_INNER_CALL,
        OZ_FAILED_CALL
    }

    /// @dev Same selector as OpenZeppelin >= 5.1 `Errors.FailedCall()`.
    error FailedCall();

    /// @dev A decodable application error (what a real vault's custom revert looks like to the dispatcher).
    error BusinessBoom();

    Mode public mode;
    uint256 public burnDepth = 24;
    uint256[] internal _sink;
    MockGasBurner public immutable burner = new MockGasBurner();

    constructor(IERC20 asset_) MockRemoteVault(asset_, "Gas Burn Vault", "GBV") {}

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setBurnDepth(uint256 depth_) external {
        burnDepth = depth_;
    }

    function deposit(uint256 assets_, address receiver_) public override returns (uint256) {
        if (mode == Mode.BURN_DEEP) {
            this.descend(burnDepth);
        } else if (mode == Mode.BUSINESS_ERROR) {
            revert BusinessBoom();
        } else if (mode == Mode.VAULT_READ_GAS_ERROR) {
            revert TrackedVaultPricingLib.InsufficientGasForVaultRead();
        } else if (mode == Mode.BURN_ALL_THEN_BUSINESS_ERROR) {
            assembly {
                for {} gt(gas(), 20000) {} {}
            }
            revert BusinessBoom();
        } else if (mode == Mode.BIG_PAYLOAD_ERROR) {
            bytes4 sel = BusinessBoom.selector;
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, sel)
                revert(ptr, 20000)
            }
        } else if (mode == Mode.OZ_FAILED_INNER_CALL) {
            Address.functionDelegateCall(address(burner), abi.encodeCall(MockGasBurner.burn, ()));
        } else if (mode == Mode.OZ_FAILED_CALL) {
            revert FailedCall();
        } else if (mode == Mode.HEAVY) {
            for (uint256 i; i < 10; ++i) {
                _sink.push(i + 1);
            }
        }
        return super.deposit(assets_, receiver_);
    }

    /// @dev One external frame per level; the deepest one consumes ALL the gas it was forwarded (INVALID), so the
    ///      frames above it each hand back their 1/64 reserve: `G * (1 - (63/64)^k)` reaches the caller's catch.
    function descend(uint256 depth_) external {
        if (depth_ == 0) {
            assembly {
                invalid()
            }
        }
        this.descend(depth_ - 1);
    }
}
