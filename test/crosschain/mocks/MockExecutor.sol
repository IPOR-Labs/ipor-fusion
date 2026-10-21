// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Command} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title MockExecutor
/// @notice Lightweight `ICrosschainExecutor`-shaped double for the fuse suite. Records the calls the fuses
///         forward, moves ASSET on `claimAsset`, and returns a settable (optionally reverting) `getBalance`.
/// @dev Selector-compatible with the executor surface the fuses touch; does not run the real state machine.
contract MockExecutor {
    address public MANAGER;
    /// @dev Intrinsic Stargate-transport marker probed by the Stargate fuses; zero it to simulate a
    ///      cross-wired (e.g. CCIP) executor.
    address public STARGATE_POOL = address(0x5747A);
    address public immutable ASSET;
    /// @dev Decimals pair the Stargate supply fuse derives its dust unit from (IL-8634); 6/6 = no dust.
    uint8 public LOCAL_DECIMALS = 6;
    uint8 public SHARED_DECIMALS = 6;

    /// @dev Fail-closed revert used by `balanceReverts`; selector is in the balance fuse's cache allowlist.
    error NavSettledStale(uint256 chainId);
    /// @dev Same selector as the executors' `ChainBlocked(uint256)`; used by `balanceBlocked` / `uncheckedBlocked`.
    error ChainBlocked(uint256 chainId);

    /// @dev Non-default `getBalance()` failure modes for the balance fuse catch tests.
    enum FailMode {
        NONE,
        RAW,
        OUT_OF_GAS,
        PANIC,
        ERROR_STRING
    }

    uint256 public balanceValue;
    bool public balanceReverts;
    /// @dev `getBalance()` reverts `ChainBlocked(1)` (takes precedence over `balanceReverts`).
    bool public balanceBlocked;
    /// @dev `getBalanceUnchecked()` reverts `ChainBlocked(1)`, as the real executors do while any chain is blocked.
    bool public uncheckedBlocked;
    FailMode public failMode;
    bytes public rawRevertData;

    // Recorded last-call data
    uint256 public lastSendChainId;
    uint256 public lastSendAmount;
    uint256 public lastSendMin;
    uint256 public lastRequestChainId;
    uint256 public lastRequestAmount;
    uint256 public lastRequestMin;
    bytes public lastRequestOptions;
    uint256 public lastClaimAmount;
    uint256 public lastRegisterChainId;
    uint32 public lastRegisterEid;
    uint256 public lastCreateChainId;
    uint256 public lastUpdateChainId;
    uint256 public lastCommandChainId;
    mapping(uint256 => bool) public chainBlocked;

    function setChainBlocked(uint256 chainId_, bool blocked_) external {
        chainBlocked[chainId_] = blocked_;
    }
    uint256 public lastCancelRequestId;
    uint256 public lastRetryChainId;
    uint256 public lastCancelCommandChainId;

    constructor(address manager_, address asset_) {
        MANAGER = manager_;
        ASSET = asset_;
    }

    function setManager(address manager_) external {
        MANAGER = manager_;
    }

    function setDecimals(uint8 local_, uint8 shared_) external {
        LOCAL_DECIMALS = local_;
        SHARED_DECIMALS = shared_;
    }

    function setStargatePool(address pool_) external {
        STARGATE_POOL = pool_;
    }

    function setBalance(uint256 balanceValue_) external {
        balanceValue = balanceValue_;
    }

    function setBalanceReverts(bool reverts_) external {
        balanceReverts = reverts_;
    }

    function setBalanceBlocked(bool blocked_) external {
        balanceBlocked = blocked_;
    }

    function setUncheckedBlocked(bool blocked_) external {
        uncheckedBlocked = blocked_;
    }

    function setFailMode(FailMode mode_, bytes calldata rawRevertData_) external {
        failMode = mode_;
        rawRevertData = rawRevertData_;
    }

    function getBalance() external view returns (uint256) {
        if (balanceBlocked) revert ChainBlocked(1);
        if (balanceReverts) revert NavSettledStale(1);
        if (failMode == FailMode.RAW) {
            bytes memory data = rawRevertData;
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        } else if (failMode == FailMode.OUT_OF_GAS) {
            uint256 sink;
            while (true) {
                ++sink;
            }
        } else if (failMode == FailMode.PANIC) {
            uint256 zero = balanceValue - balanceValue;
            return 1 / zero;
        } else if (failMode == FailMode.ERROR_STRING) {
            revert("x");
        }
        return balanceValue;
    }

    /// @dev The booked balance without the staleness gates (IL-8611): `balanceValue` regardless of any staleness
    ///      fail-closed mode, but reverting `ChainBlocked` when `uncheckedBlocked` is set.
    function getBalanceUnchecked() external view returns (uint256) {
        if (uncheckedBlocked) revert ChainBlocked(1);
        return balanceValue;
    }

    function sendAssetToDispatcher(uint256 dstChainId_, uint256 amount_, uint256 minAmountLD_, bytes calldata)
        external
    {
        // Mirrors the real executor's shared-decimals dust rule (IL-8634) so the supply-fuse floor is exercised.
        if (amount_ % 10 ** (LOCAL_DECIMALS - SHARED_DECIMALS) != 0) {
            revert CrosschainErrors.AmountBelowSharedDecimals(amount_);
        }
        lastSendChainId = dstChainId_;
        lastSendAmount = amount_;
        lastSendMin = minAmountLD_;
    }

    function requestAssetsFromDispatcher(
        uint256 dstChainId_,
        uint256 amount_,
        uint256 minReturn_,
        bytes calldata options_
    ) external {
        lastRequestChainId = dstChainId_;
        lastRequestAmount = amount_;
        lastRequestMin = minReturn_;
        lastRequestOptions = options_;
    }

    function claimAsset(uint256 amount_) external {
        lastClaimAmount = amount_;
        uint256 bal = IERC20(ASSET).balanceOf(address(this));
        uint256 send = amount_ < bal ? amount_ : bal;
        if (send != 0) IERC20(ASSET).transfer(MANAGER, send);
    }

    function registerChain(uint256 chainId_, uint32 eid_, bytes calldata) external {
        lastRegisterChainId = chainId_;
        lastRegisterEid = eid_;
    }

    function createDispatcher(uint256 dstChainId_, address[] calldata) external {
        lastCreateChainId = dstChainId_;
    }

    function updatePlasmaVaults(uint256 dstChainId_, address[] calldata) external {
        lastUpdateChainId = dstChainId_;
    }

    function sendCommandToDispatcher(uint256 dstChainId_, Command calldata) external {
        lastCommandChainId = dstChainId_;
    }

    function cancelDispatcherRequest(uint256 requestId_) external {
        lastCancelRequestId = requestId_;
    }

    /// @dev Business action reported for the active command (IL-8600); 0 = not a DEPOSIT.
    uint8 public storedActiveCommandAction;

    function setActiveCommandAction(uint8 action_) external {
        storedActiveCommandAction = action_;
    }

    function activeCommandAction(uint256) external view returns (uint8) {
        return storedActiveCommandAction;
    }

    /// @dev Target vault reported for the active DEPOSIT (IL-8600 follow-up: re-checked on a retry).
    address public storedActiveCommandTarget;

    function setActiveCommandTarget(address target_) external {
        storedActiveCommandTarget = target_;
    }

    function activeCommandTarget(uint256) external view returns (address) {
        return storedActiveCommandTarget;
    }

    function retryCommand(uint256 dstChainId_) external {
        lastRetryChainId = dstChainId_;
    }

    function cancelCommand(uint256 dstChainId_) external {
        lastCancelCommandChainId = dstChainId_;
    }

    receive() external payable {}
}
