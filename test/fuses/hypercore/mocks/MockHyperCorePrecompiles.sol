// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title HyperCoreMockState
/// @notice Shared, singleton backing storage for `MockHyperCorePrecompiles`. The same
/// `MockHyperCorePrecompiles` bytecode is `vm.etch`ed at every HyperCore read-precompile address
/// (`0x800`..`0x810`); since storage is per-address, all of them instead delegate their reads and
/// writes to this one real contract, found via a fixed storage slot (`state`, slot 0) written with
/// `vm.store` at each precompile address by `HyperCoreTestHelper.etchPrecompiles`.
/// @dev Struct layouts mirror `HyperCoreLib` (see `chat/INTERFACES.md`).
contract HyperCoreMockState {
    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    mapping(bytes32 => Position) private _positions;
    mapping(bytes32 => SpotBalance) private _spotBalances;
    mapping(address => uint64) private _withdrawable;
    mapping(uint32 => uint64) private _markPx;
    mapping(uint32 => uint64) private _oraclePx;
    uint64 private _l1BlockNumber;
    mapping(uint32 => PerpAssetInfo) private _perpAssetInfo;
    mapping(uint64 => TokenInfo) private _tokenInfo;
    mapping(bytes32 => AccountMarginSummary) private _accountMarginSummary;
    mapping(address => bool) private _coreUserExists;
    mapping(address => bool) private _forcedFail;
    mapping(uint32 => bool) private _accountMarginSummaryForcedFail;

    constructor() {
        // Defaults matching mainnet `eth_call` fixtures recorded in chat/PLAN.md §3.
        // `evmContract` for USDC (token 0) is left at address(0); the test helper sets it once the
        // mock USDC ERC20 is deployed.
        uint64[] memory noSpots = new uint64[](0);
        _tokenInfo[0] = TokenInfo({
            name: "USDC",
            spots: noSpots,
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(0),
            szDecimals: 8,
            weiDecimals: 8,
            evmExtraWeiDecimals: -2
        });
        _tokenInfo[150] = TokenInfo({
            name: "HYPE",
            spots: noSpots,
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(0),
            szDecimals: 2,
            weiDecimals: 8,
            evmExtraWeiDecimals: 10
        });
        _perpAssetInfo[0] = PerpAssetInfo({
            coin: "BTC",
            marginTableId: 0,
            szDecimals: 5,
            maxLeverage: 40,
            onlyIsolated: false
        });
    }

    // ---------------------------------------------------------------------
    // Setters
    // ---------------------------------------------------------------------

    function setPosition(address user, uint32 asset, Position calldata position) external {
        _positions[_userAssetKey(user, asset)] = position;
    }

    function setSpotBalance(address user, uint64 token, SpotBalance calldata balance) external {
        _spotBalances[_userTokenKey(user, token)] = balance;
    }

    function setWithdrawable(address user, uint64 amount) external {
        _withdrawable[user] = amount;
    }

    /// @dev `px` is in the raw HyperCore scale: human price x 10^(6 - szDecimals).
    function setMarkPx(uint32 asset, uint64 px) external {
        _markPx[asset] = px;
    }

    /// @dev `px` is in the raw HyperCore scale: human price x 10^(6 - szDecimals).
    function setOraclePx(uint32 asset, uint64 px) external {
        _oraclePx[asset] = px;
    }

    function setL1BlockNumber(uint64 blockNumber) external {
        _l1BlockNumber = blockNumber;
    }

    function setPerpAssetInfo(uint32 asset, PerpAssetInfo calldata info) external {
        _perpAssetInfo[asset] = info;
    }

    function setTokenInfo(uint64 token, TokenInfo calldata info) external {
        _tokenInfo[token] = info;
    }

    function setAccountMarginSummary(uint32 perpDex, address user, AccountMarginSummary calldata summary) external {
        _accountMarginSummary[_perpDexUserKey(perpDex, user)] = summary;
    }

    function setCoreUserExists(address user, bool exists_) external {
        _coreUserExists[user] = exists_;
    }

    /// @notice Forces the precompile at `precompile` to revert on its next call(s), mimicking
    /// `PrecompileError` (e.g. bad input / out-of-gas on the real HyperCore node).
    function setFail(address precompile, bool shouldFail) external {
        _forcedFail[precompile] = shouldFail;
    }

    /// @notice Forces `accountMarginSummary` (0x80F) to revert for `perpDex` only, mimicking a
    /// per-dex node error while other dexes keep answering. Independent from `setFail`, which
    /// targets a whole precompile address.
    function setAccountMarginSummaryFail(uint32 perpDex, bool shouldFail) external {
        _accountMarginSummaryForcedFail[perpDex] = shouldFail;
    }

    // ---------------------------------------------------------------------
    // Getters (called by MockHyperCorePrecompiles)
    // ---------------------------------------------------------------------

    function shouldFail(address precompile) external view returns (bool) {
        return _forcedFail[precompile];
    }

    function accountMarginSummaryShouldFail(uint32 perpDex) external view returns (bool) {
        return _accountMarginSummaryForcedFail[perpDex];
    }

    /// @notice A HIP-3 read index (>= 10000) is "registered" once `setPerpAssetInfo` was called for
    /// it with a non-empty `coin`. Native indices (< 10000) are never gated by this check.
    function isHip3MarketRegistered(uint32 readIndex) external view returns (bool) {
        return bytes(_perpAssetInfo[readIndex].coin).length > 0;
    }

    function getPosition(address user, uint32 asset) external view returns (Position memory) {
        return _positions[_userAssetKey(user, asset)];
    }

    function getSpotBalance(address user, uint64 token) external view returns (SpotBalance memory) {
        return _spotBalances[_userTokenKey(user, token)];
    }

    function getWithdrawable(address user) external view returns (uint64) {
        return _withdrawable[user];
    }

    function getMarkPx(uint32 asset) external view returns (uint64) {
        return _markPx[asset];
    }

    function getOraclePx(uint32 asset) external view returns (uint64) {
        return _oraclePx[asset];
    }

    function getL1BlockNumber() external view returns (uint64) {
        return _l1BlockNumber;
    }

    function getPerpAssetInfo(uint32 asset) external view returns (PerpAssetInfo memory) {
        return _perpAssetInfo[asset];
    }

    function getTokenInfo(uint64 token) external view returns (TokenInfo memory) {
        return _tokenInfo[token];
    }

    function getAccountMarginSummary(uint32 perpDex, address user) external view returns (AccountMarginSummary memory) {
        return _accountMarginSummary[_perpDexUserKey(perpDex, user)];
    }

    function getCoreUserExists(address user) external view returns (bool) {
        return _coreUserExists[user];
    }

    function _userAssetKey(address user, uint32 asset) private pure returns (bytes32) {
        return keccak256(abi.encode(user, asset));
    }

    function _userTokenKey(address user, uint64 token) private pure returns (bytes32) {
        return keccak256(abi.encode(user, token));
    }

    function _perpDexUserKey(uint32 perpDex, address user) private pure returns (bytes32) {
        return keccak256(abi.encode(perpDex, user));
    }
}

/// @title MockHyperCorePrecompiles
/// @notice Single implementation that is `vm.etch`ed, byte-for-byte identical, at every HyperCore
/// read-precompile address `0x0000...0800`..`0x0000...0810`. Dispatches on `address(this)` in its
/// fallback and abi-decodes the raw input exactly like the real precompiles: HyperCore precompiles
/// take raw `abi.encode(args)` input, not selector-dispatched calls.
/// @dev Storage slot 0 (`state`) holds the address of the shared `HyperCoreMockState` contract; it is
/// written per-etched-address via `vm.store` by `HyperCoreTestHelper.etchPrecompiles`, since `vm.etch`
/// only copies code, not storage.
contract MockHyperCorePrecompiles {
    /// @dev MUST remain the first (and only) storage variable so it lives at slot 0.
    address public state;

    address private constant POSITION = 0x0000000000000000000000000000000000000800;
    address private constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address private constant WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address private constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address private constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address private constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000809;
    address private constant PERP_ASSET_INFO = address(uint160(0x80A));
    address private constant TOKEN_INFO = address(uint160(0x80C));
    address private constant ACCOUNT_MARGIN_SUMMARY = address(uint160(0x80F));
    address private constant CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;
    address private constant POSITION2 = address(uint160(0x813));

    /// @dev Read indices `< 10000` are native (dex 0) markets. They are deliberately not gated by
    /// HIP-3 registration below: existing tests rely on the mock returning default values for native
    /// markets that were never configured. This leniency is a test convenience and does not mirror
    /// mainnet, where an unlisted native index reverts as well.
    uint32 private constant HIP3_READ_INDEX_THRESHOLD = 10000;

    /// @dev `accountMarginSummary` (0x80F) knows perp dex indices 0..10 on mainnet (0 = native, 1..10
    /// = HIP-3 dexes); a higher index reverts.
    uint32 private constant MAX_KNOWN_PERP_DEX = 10;

    fallback(bytes calldata input) external returns (bytes memory) {
        HyperCoreMockState s = HyperCoreMockState(state);
        require(!s.shouldFail(address(this)), "MockHyperCorePrecompiles: forced failure");

        address self = address(this);

        if (self == POSITION) {
            (address user, uint32 readIndex) = abi.decode(input, (address, uint32));
            require(readIndex <= type(uint16).max, "MockHyperCorePrecompiles: position read index exceeds uint16");
            _requireHip3RegisteredIfApplicable(s, readIndex);
            return abi.encode(s.getPosition(user, readIndex));
        } else if (self == POSITION2) {
            (address user, uint32 readIndex) = abi.decode(input, (address, uint32));
            _requireHip3RegisteredIfApplicable(s, readIndex);
            return abi.encode(s.getPosition(user, readIndex));
        } else if (self == SPOT_BALANCE) {
            (address user, uint64 token) = abi.decode(input, (address, uint64));
            return abi.encode(s.getSpotBalance(user, token));
        } else if (self == WITHDRAWABLE) {
            address user = abi.decode(input, (address));
            return abi.encode(s.getWithdrawable(user));
        } else if (self == MARK_PX) {
            uint32 asset = abi.decode(input, (uint32));
            _requireHip3RegisteredIfApplicable(s, asset);
            return abi.encode(s.getMarkPx(asset));
        } else if (self == ORACLE_PX) {
            uint32 asset = abi.decode(input, (uint32));
            _requireHip3RegisteredIfApplicable(s, asset);
            return abi.encode(s.getOraclePx(asset));
        } else if (self == L1_BLOCK_NUMBER) {
            return abi.encode(s.getL1BlockNumber());
        } else if (self == PERP_ASSET_INFO) {
            uint32 asset = abi.decode(input, (uint32));
            _requireHip3RegisteredIfApplicable(s, asset);
            return abi.encode(s.getPerpAssetInfo(asset));
        } else if (self == TOKEN_INFO) {
            uint64 token = abi.decode(input, (uint64));
            return abi.encode(s.getTokenInfo(token));
        } else if (self == ACCOUNT_MARGIN_SUMMARY) {
            (uint32 perpDex, address user) = abi.decode(input, (uint32, address));
            require(perpDex <= MAX_KNOWN_PERP_DEX, "MockHyperCorePrecompiles: unknown perp dex");
            require(
                !s.accountMarginSummaryShouldFail(perpDex),
                "MockHyperCorePrecompiles: forced accountMarginSummary failure"
            );
            return abi.encode(s.getAccountMarginSummary(perpDex, user));
        } else if (self == CORE_USER_EXISTS) {
            address user = abi.decode(input, (address));
            return abi.encode(s.getCoreUserExists(user));
        }

        revert("MockHyperCorePrecompiles: unknown precompile");
    }

    /// @dev Reverts for a HIP-3 read index (>= 10000) that was never registered via
    /// `setPerpAssetInfo`. Native read indices (< 10000) are always allowed, including unconfigured
    /// ones, because existing tests rely on the mock returning default values for native markets that
    /// were never configured; this leniency is a test convenience and does not mirror mainnet, where
    /// an unlisted native index reverts as well.
    function _requireHip3RegisteredIfApplicable(HyperCoreMockState s, uint32 readIndex) private view {
        if (readIndex >= HIP3_READ_INDEX_THRESHOLD) {
            require(s.isHip3MarketRegistered(readIndex), "MockHyperCorePrecompiles: unregistered HIP-3 market");
        }
    }
}
