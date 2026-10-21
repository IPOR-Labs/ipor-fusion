// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HyperCore} from "./HyperCore.sol";

interface IMintableUsdc {
    function mint(address to, uint256 amount) external;
}

/// @title SimCoreDepositWallet
/// @notice Local (not vendored) test double for Hyperliquid/Circle's CoreDepositWallet, wired into the
///         offline `hyper-evm-lib` simulator (see `VENDORED.md`) so `HyperCoreDepositFuse`'s
///         CoreDepositWallet path (USDC, token 0) is exercised end-to-end by
///         `HyperCoreFlowSimulationTest`.
/// @dev The real CoreDepositWallet pulls USDC via `transferFrom` and credits the recipient on
///      HyperCore; the vendored simulator has no built-in model of that contract (it only auto-detects
///      a plain ERC20 `Transfer` to a token's derived system address, which the fuse's wallet path no
///      longer performs for token 0 -- see `HyperCoreDepositFuse.sol`'s `_transferToCore`). This shim
///      closes that gap by pulling the USDC itself and then crediting Core spot through the exact same
///      `HyperCore.executeTokenTransfer(address(0), tokenIndex, recipient, amount)` entrypoint that
///      `CoreSimulatorLib.nextBlock()` uses for the generic system-address path, so activation-fee and
///      wei-conversion behavior stays identical between the two deposit paths.
/// @dev Also exposes a minimal, self-contained `balanceOf`/`transfer` pair (backed by its own storage
///      mapping, not proxied to `token`) purely so the vendored simulator's Core->EVM withdrawal path
///      (`hyper-core/CoreExecution.sol`'s `executeSpotSend`/`executeSendAsset`, which treats
///      `tokenInfo(0).evmContract` as a plain ERC20 and does
///      `deal(evmContract, systemAddress, ...)` then `IERC20(evmContract).safeTransfer(sender, amount)`)
///      keeps working now that `tokenInfo(0).evmContract` is this wallet instead of the real USDC
///      contract. `deal()` needs a standard mapping-backed `balanceOf` to locate a storage slot to
///      write to; `transfer()` then mints the equivalent amount of real `token()` USDC to the
///      recipient, so `HyperCoreSendFuse`'s Core->EVM leg still lands real, spendable USDC on the
///      vault. See `VENDORED.md` for why this can't just proxy to the real USDC token instead.
contract SimCoreDepositWallet {
    HyperCore private constant HYPER_CORE = HyperCore(payable(0x9999999999999999999999999999999999999999));

    /// @notice The underlying native ERC20 token this wallet accepts and forwards to HyperCore
    address public immutable token;

    /// @notice The HyperCore spot token index this wallet forwards deposits to
    uint64 public immutable tokenIndex;

    /// @notice Whether deposits into this wallet are currently paused
    bool public paused;

    address public lastCaller;
    address public lastRecipient;
    uint256 public lastAmount;
    uint32 public lastDestinationDex;
    uint256 public depositForCallCount;

    /// @dev Fictional, self-contained balances used only by the Core->EVM `deal`/`transfer` shim
    ///      described above; unrelated to the real USDC this wallet pulls in on deposit.
    mapping(address => uint256) private _withdrawBalances;

    event Deposited(address indexed caller, address indexed recipient, uint256 amount, uint32 destinationDex);

    constructor(address token_, uint64 tokenIndex_) {
        token = token_;
        tokenIndex = tokenIndex_;
    }

    /// @dev See contract-level NatSpec: storage-backed so `deal()` can locate and write this slot.
    function balanceOf(address account_) external view returns (uint256) {
        return _withdrawBalances[account_];
    }

    /// @dev See contract-level NatSpec: mints real `token()` USDC to `to_` rather than moving a
    ///      balance the vault could otherwise never spend.
    function transfer(address to_, uint256 amount_) external returns (bool) {
        require(_withdrawBalances[msg.sender] >= amount_, "SimCoreDepositWallet: insufficient withdraw balance");
        _withdrawBalances[msg.sender] -= amount_;
        IMintableUsdc(token).mint(to_, amount_);
        return true;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function deposit(uint256 amount_, uint32 destinationDex_) external {
        _deposit(msg.sender, msg.sender, amount_, destinationDex_);
    }

    function depositFor(address recipient_, uint256 amount_, uint32 destinationDex_) external {
        _deposit(msg.sender, recipient_, amount_, destinationDex_);
    }

    function _deposit(address caller_, address recipient_, uint256 amount_, uint32 destinationDex_) internal {
        require(!paused, "SimCoreDepositWallet: paused");

        IERC20(token).transferFrom(caller_, address(this), amount_);

        // Credit the recipient's HyperCore spot balance for `tokenIndex` through the same
        // wei-converting, activation-aware entrypoint the simulator's Transfer-log scan uses for the
        // generic (non-wallet) deposit path.
        HYPER_CORE.executeTokenTransfer(address(0), tokenIndex, recipient_, amount_);

        lastCaller = caller_;
        lastRecipient = recipient_;
        lastAmount = amount_;
        lastDestinationDex = destinationDex_;
        depositForCallCount += 1;

        emit Deposited(caller_, recipient_, amount_, destinationDex_);
    }
}
