// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IExtTermRepoCollateralManager} from "contracts/fuses/term_finance/ext/IExtTermRepoCollateralManager.sol";
import {MockTermRepoLocker} from "./MockTermRepoLocker.sol";

/// @notice Minimal mock of `TermRepoCollateralManager` for borrower-side unit tests.
/// @dev Models the on-chain semantics required by `TermFinanceCollateralFuse`:
///      - `externalLockCollateral` pulls `amount` of `collateralToken` from `msg.sender`
///        (the borrower / PlasmaVault) into the per-Term `TermRepoLocker` (test wiring uses
///        an EOA-style locker address). The fuse approves the `TermRepoLocker` (not the
///        manager), so the mock honours that contract by calling `transferFrom(msg.sender,
///        termRepoLocker, amount)`.
///      - `externalUnlockCollateral` transfers `amount` back from the configured
///        `termRepoLocker` to `msg.sender`.
///      - `collateralTokens(i)` reverts on out-of-bounds index, mirroring the live impl
///        behaviour documented in `IExtTermRepoCollateralManager` NatSpec.
///      - `numOfAcceptedCollateralTokens()` returns a `uint8` (NOT `uint256`) — the impl
///        return type the fuse's loop bound depends on.
contract MockTermRepoCollateralManager is IExtTermRepoCollateralManager {
    address[] internal _acceptedTokens;
    mapping(address => mapping(address => uint256)) internal _balances; // borrower => token => locked
    /// @notice Per-Term `TermRepoLocker` address. The fuse approves THIS address; the manager
    ///         pulls collateral from the borrower via this contract.
    address public termRepoLocker;

    bool public lockReverts;
    bool public unlockReverts;
    bool public skipPull;

    function setTermRepoLocker(address v_) external {
        termRepoLocker = v_;
    }

    function setAcceptedTokens(address[] memory tokens_) external {
        delete _acceptedTokens;
        for (uint256 i; i < tokens_.length; ++i) {
            _acceptedTokens.push(tokens_[i]);
        }
    }

    function setLockReverts(bool v_) external {
        lockReverts = v_;
    }

    function setUnlockReverts(bool v_) external {
        unlockReverts = v_;
    }

    /// @notice When set, `externalLockCollateral` will skip the ERC20 pull (used to test
    ///         scenarios where the manager doesn't actually consume the approval — the fuse's
    ///         defensive `forceApprove(termRepoLocker, 0)` cleanup must still leave allowance == 0).
    function setSkipPull(bool v_) external {
        skipPull = v_;
    }

    function externalLockCollateral(address collateralToken_, uint256 amount_) external override {
        if (lockReverts) revert("MockCollateralManager: externalLockCollateral reverts");
        if (!skipPull) {
            // Mirror live impl: manager delegates the pull to the per-Term TermRepoLocker.
            // Locker holds the approval; manager only orchestrates the call.
            MockTermRepoLocker(termRepoLocker).transferTokenFromWallet(msg.sender, collateralToken_, amount_);
        }
        _balances[msg.sender][collateralToken_] += amount_;
    }

    function externalUnlockCollateral(address collateralToken_, uint256 amount_) external override {
        if (unlockReverts) revert("MockCollateralManager: externalUnlockCollateral reverts");
        uint256 bal = _balances[msg.sender][collateralToken_];
        require(amount_ <= bal, "MockCollateralManager: amount exceeds locked");
        _balances[msg.sender][collateralToken_] = bal - amount_;
        // Push from locker back to the borrower (vault); mirrors the live unlock path.
        MockTermRepoLocker(termRepoLocker).transferTokenToWallet(msg.sender, collateralToken_, amount_);
    }

    function getCollateralBalance(address borrower_, address collateralToken_) external view override returns (uint256) {
        return _balances[borrower_][collateralToken_];
    }

    function isBorrowerInShortfall(address) external pure override returns (bool) {
        return false;
    }

    function getCollateralMarketValue(address) external pure override returns (uint256) {
        return 0;
    }

    function maintenanceCollateralRatios(address) external pure override returns (uint256) {
        return 1.05e18;
    }

    function initialCollateralRatios(address) external pure override returns (uint256) {
        return 1.10e18;
    }

    function liquidatedDamage(address) external pure override returns (uint256) {
        return 0.05e18;
    }

    function numOfAcceptedCollateralTokens() external view override returns (uint8) {
        return uint8(_acceptedTokens.length);
    }

    function collateralTokens(uint256 index_) external view override returns (address) {
        require(index_ < _acceptedTokens.length, "MockCollateralManager: OOB");
        return _acceptedTokens[index_];
    }
}
