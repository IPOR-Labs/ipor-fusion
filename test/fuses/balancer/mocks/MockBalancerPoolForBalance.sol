// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool, IRateProvider} from "contracts/fuses/balancer/ext/IPool.sol";

/// @notice Minimal mock of a Balancer V3 pool (also acting as the BPT/LP token) used to unit-test
///         BalancerBalanceFuse.balanceOf() without a mainnet fork.
///
///         `getTokenInfo()` returns configurable `balancesRaw` (native token decimals) and
///         `lastBalancesLiveScaled18` (deliberately configured to a DIFFERENT value than
///         `balancesRaw`, so that a test which accidentally re-reads the live-scaled array instead
///         of the raw one would be caught, not just a test that skips decimals normalization).
contract MockBalancerPoolForBalance is IPool {
    IERC20[] private _tokens;
    TokenInfo[] private _tokenInfo;
    uint256[] private _balancesRaw;
    uint256[] private _lastBalancesLiveScaled18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _bptBalances;

    function setTokens(IERC20[] memory tokens_) external {
        delete _tokens;
        for (uint256 i; i < tokens_.length; ++i) {
            _tokens.push(tokens_[i]);
        }
    }

    /// @dev tokenInfo is always discarded by BalancerBalanceFuse's destructuring
    ///      (`(tokens, , balancesRaw, ) = getTokenInfo()`), so a single STANDARD placeholder per
    ///      token is enough to keep array lengths consistent.
    function setTokenInfoLength(uint256 len_) external {
        delete _tokenInfo;
        for (uint256 i; i < len_; ++i) {
            _tokenInfo.push(TokenInfo({tokenType: TokenType.STANDARD, rateProvider: IRateProvider(address(0)), paysYieldFees: false}));
        }
    }

    function setBalancesRaw(uint256[] memory balancesRaw_) external {
        delete _balancesRaw;
        for (uint256 i; i < balancesRaw_.length; ++i) {
            _balancesRaw.push(balancesRaw_[i]);
        }
    }

    /// @dev Set to a value that diverges from `balancesRaw` on purpose, see contract NatSpec.
    function setLastBalancesLiveScaled18(uint256[] memory lastBalancesLiveScaled18_) external {
        delete _lastBalancesLiveScaled18;
        for (uint256 i; i < lastBalancesLiveScaled18_.length; ++i) {
            _lastBalancesLiveScaled18.push(lastBalancesLiveScaled18_[i]);
        }
    }

    function setTotalSupply(uint256 totalSupply_) external {
        _totalSupply = totalSupply_;
    }

    function setBptBalance(address account_, uint256 balance_) external {
        _bptBalances[account_] = balance_;
    }

    // ============ IPool ============

    function getTokens() external view returns (IERC20[] memory tokens) {
        return _tokens;
    }

    function getTokenInfo()
        external
        view
        override
        returns (
            IERC20[] memory tokens,
            TokenInfo[] memory tokenInfo,
            uint256[] memory balancesRaw,
            uint256[] memory lastBalancesLiveScaled18
        )
    {
        return (_tokens, _tokenInfo, _balancesRaw, _lastBalancesLiveScaled18);
    }

    // ============ BPT / LP token (ERC20-like) ============

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account_) external view returns (uint256) {
        return _bptBalances[account_];
    }
}
