// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {IporMath} from "../libraries/math/IporMath.sol";
import {IPlasmaVault, FuseAction} from "../interfaces/IPlasmaVault.sol";
import {IPlasmaVaultRequestCap} from "../interfaces/IPlasmaVaultRequestCap.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";
import {IPlasmaVaultBase} from "../interfaces/IPlasmaVaultBase.sol";
import {IPriceOracleMiddleware} from "../price_oracle/IPriceOracleMiddleware.sol";
import {IRewardsClaimManager} from "../interfaces/IRewardsClaimManager.sol";
import {AccessManagedUpgradeable} from "../managers/access/AccessManagedUpgradeable.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {AssetDistributionProtectionLib, DataToCheck} from "../libraries/AssetDistributionProtectionLib.sol";
import {CallbackHandlerLib} from "../libraries/CallbackHandlerLib.sol";
import {FusesLib} from "../libraries/FusesLib.sol";
import {PlasmaVaultLib} from "../libraries/PlasmaVaultLib.sol";
import {FeeConfig} from "../managers/fee/FeeManagerFactory.sol";

import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";
import {UniversalReader} from "../universal_reader/UniversalReader.sol";
import {ContextClientStorageLib} from "../managers/context/ContextClientStorageLib.sol";
import {PreHooksHandler} from "../handlers/pre_hooks/PreHooksHandler.sol";
import {PlasmaVaultFeesLib} from "./lib/PlasmaVaultFeesLib.sol";
import {PlasmaVaultMarketsLib} from "./lib/PlasmaVaultMarketsLib.sol";

/// @title PlasmaVault Initialization Data Structure
/// @notice Configuration data structure used during Plasma Vault deployment and initialization
/// @dev Encapsulates all required parameters for vault setup and protocol integration
///
/// Core Configuration:
/// - Asset details (name, symbol, underlying token)
/// - Protocol integrations (fuses, markets, substrates)
/// - Fee structure and management
/// - Access control and security settings
/// - Supply cap and withdrawal parameters
///
/// Integration Components:
/// - Price Oracle: Asset valuation and share price calculation
/// - Market Substrates: Protocol-specific market identifiers
/// - Balance Fuses: Market-specific balance tracking
/// - Fee Configuration: Performance and management fee setup
///
/// Security Features:
/// - Access Manager: Permission and role management
/// - Total Supply Cap: Vault size control
/// - Withdraw Manager: Withdrawal control and validation
/// - Base Contract: Common functionality and security
///
/// Validation Requirements:
/// - Non-zero addresses for critical components
/// - Valid fee configurations within limits
/// - Properly formatted market configs
/// - Compatible protocol integrations
struct PlasmaVaultInitData {
    /// @notice Name of the vault's share token
    /// @dev Used in ERC20 token initialization
    string assetName;
    /// @notice Symbol of the vault's share token
    /// @dev Used in ERC20 token initialization
    string assetSymbol;
    /// @notice Address of the token that the vault accepts for deposits
    /// @dev Must be a valid ERC20 token contract
    address underlyingToken;
    /// @notice Address of the price oracle middleware for asset valuation
    /// @dev Must support USD as quote currency
    address priceOracleMiddleware;
    /// @notice Fee configuration for performance and management fees
    /// @dev Includes fee rates and recipient addresses
    FeeConfig feeConfig;
    /// @notice Address of the access control manager contract
    /// @dev Manages roles and permissions for vault operations
    address accessManager;
    /// @notice Address of the base contract providing common functionality
    /// @dev Implements core vault logic through delegatecall
    address plasmaVaultBase;
    /// @notice Address of the withdraw manager contract
    /// @dev Controls withdrawal permissions and limits, zero address disables managed withdrawals
    address withdrawManager;
    /// @notice Address of the votes plugin contract (PlasmaVaultVotesPlugin)
    /// @dev Implements optional ERC20Votes functionality through delegatecall, zero address disables voting
    address plasmaVaultVotesPlugin;
}

/// @title Market Balance Fuse Configuration
/// @notice Configuration structure linking markets with their balance tracking contracts
/// @dev Maps protocol-specific markets to their corresponding balance fuse implementations
///
/// Balance Fuse System:
/// - Tracks protocol-specific positions and balances
/// - Provides standardized balance reporting interface
/// - Supports market-specific balance calculations
/// - Enables protocol integration monitoring
///
/// Market Integration:
/// - Market ID 0: Special case for protocol-independent fuses
/// - Non-zero Market IDs: Protocol-specific market tracking
/// - Single balance fuse per market
/// - Critical for asset distribution protection
///
/// Use Cases:
/// - Protocol position tracking
/// - Market balance monitoring
/// - Asset distribution validation
/// - Protocol integration management
///
/// Security Considerations:
/// - Validates market existence
/// - Ensures fuse compatibility
/// - Prevents duplicate assignments
/// - Critical for balance integrity
struct MarketBalanceFuseConfig {
    /// @notice Identifier of the market this fuse tracks
    /// @dev Market ID 0 indicates protocol-independent functionality (e.g., flashloan fuse)
    uint256 marketId;
    /// @notice Address of the balance tracking contract
    /// @dev Must implement protocol-specific balance calculation logic
    address fuse;
}

/// @title Market Substrates Configuration
/// @notice Configuration structure defining protocol-specific identifiers for market integration
/// @dev Maps markets to their underlying components and protocol-specific identifiers
///
/// Substrate System:
/// - Defines market components and identifiers
/// - Supports multi-protocol integration
/// - Enables complex market structures
/// - Facilitates balance tracking
///
/// Substrate Types:
/// - Protocol tokens and assets
/// - LP positions and pool identifiers
/// - Market-specific parameters
/// - Protocol vault identifiers
/// - Custom protocol identifiers
///
/// Integration Context:
/// - Used by balance fuses for position tracking
/// - Supports protocol-specific calculations
/// - Enables market validation
/// - Critical for protocol interactions
///
/// Security Considerations:
/// - Validates substrate format
/// - Ensures protocol compatibility
/// - Prevents invalid configurations
/// - Maintains market integrity
struct MarketSubstratesConfig {
    /// @notice Unique identifier for the market in the vault system
    /// @dev Used to link market operations and balance tracking
    uint256 marketId;
    /// @notice Array of protocol-specific identifiers for this market
    /// @dev Can include:
    /// - Asset addresses (as bytes32)
    /// - Pool/vault identifiers
    /// - Protocol-specific parameters
    /// - Market configuration data
    bytes32[] substrates;
}

/// @title Plasma Vault - ERC4626 Compliant DeFi Integration Hub
/// @notice Advanced vault system enabling protocol integrations and asset management through fuse system
/// @dev Implements ERC4626 standard with enhanced security and multi-protocol support
///
/// Core Features:
/// - ERC4626 tokenized vault standard compliance
/// - Multi-protocol integration via fuse system
/// - Advanced access control and permissions
/// - Performance and management fee system
/// - Market-specific balance tracking
/// - Protected asset distribution
///
/// Operational Components:
/// - Fuse System: Protocol-specific integration contracts
/// - Balance Tracking: Market-specific position monitoring
/// - Fee Management: Performance and time-based fees
/// - Access Control: Role-based operation permissions
/// - Withdrawal Control: Managed withdrawal process
///
/// Security Features:
/// - Reentrancy protection
/// - Role-based access control
/// - Asset distribution limits
/// - Market balance validation
/// - Withdrawal restrictions
///
/// Integration Architecture:
/// - Delegatecall to base contract for core logic
/// - Fuse contracts for protocol interactions
/// - Price oracle for asset valuation
/// - Balance fuses for position tracking
/// - Callback system for complex operations
///
contract PlasmaVault is
    ERC20Upgradeable,
    ERC4626Upgradeable,
    ReentrancyGuardUpgradeable,
    AccessManagedUpgradeable,
    UniversalReader,
    IPlasmaVault,
    IPlasmaVaultRequestCap,
    PreHooksHandler
{
    using Address for address;
    using Math for uint256;
    using SafeERC20 for IERC20;

    /// @notice ISO-4217 currency code for USD represented as address
    /// @dev 0x348 (840 in decimal) is the ISO-4217 numeric code for USD
    address private constant USD = address(0x0000000000000000000000000000000000000348);
    /// @dev Additional offset to withdraw from markets in case of rounding issues
    uint256 private constant WITHDRAW_FROM_MARKETS_OFFSET = 10;
    /// @dev 10 attempts to withdraw from markets in case of rounding issues
    uint256 private constant REDEEM_ATTEMPTS = 10;
    uint256 public constant DEFAULT_SLIPPAGE_IN_PERCENTAGE = 2;

    error NoSharesToRedeem();
    error NoSharesToMint();
    error NoAssetsToWithdraw();
    error NoSharesToWithdraw();
    error NoAssetsToDeposit();
    error NoSharesToDeposit();
    error UnsupportedFuse();
    error UnsupportedMethod();
    error WithdrawManagerInvalidSharesToRelease(uint256 sharesToRelease);
    error PermitFailed();
    error WithdrawManagerNotSet();
    error VotesPluginNotEnabled();
    /// @notice The FeeManager created for this vault does not report the performance fee rate scale of this build
    /// @dev ABI mirror: reverted by `PlasmaVaultFeesLib.createFeeManager` (linked library, DELEGATECALL) during
    ///      proxyInitialize; same selector as `PlasmaVaultFeesLib.FeeManagerScaleMismatch` (IL-9601)
    /// @param feeManager The FeeManager address the factory returned
    error FeeManagerScaleMismatch(address feeManager);
    /// @notice The performance fee returned by the FeeManagerFactory is above the maximum
    /// @dev ABI mirror: reverted by `PlasmaVaultFeesLib.createFeeManager` (`PlasmaVaultLib.configurePerformanceFee`)
    /// @param feeInPercentage The rejected fee (10000 = 100%)
    error InvalidPerformanceFee(uint256 feeInPercentage);
    /// @notice The management fee returned by the FeeManagerFactory is above the maximum
    /// @dev ABI mirror: reverted by `PlasmaVaultFeesLib.createFeeManager` (`PlasmaVaultLib.configureManagementFee`)
    /// @param feeInPercentage The rejected fee (10000 = 100%)
    error InvalidManagementFee(uint256 feeInPercentage);
    /// @notice The price of the underlying asset is zero
    /// @dev ABI mirror: reverted by `PlasmaVaultMarketsLib` (linked library, DELEGATECALL)
    error AssetPriceIsZero();
    /// @notice A market passed to the balance update has no registered balance fuse
    /// @dev ABI mirror: reverted by `PlasmaVaultMarketsLib` (linked library, DELEGATECALL)
    /// @param marketId The market without a balance fuse
    error MarketWithoutBalanceFuse(uint256 marketId);
    /// @notice An instant withdrawal fuse index is outside the configured list
    /// @dev ABI mirror: reverted by `PlasmaVaultLib` code inlined into `PlasmaVaultMarketsLib` (linked library,
    ///      DELEGATECALL)
    /// @param index The requested index
    /// @param arrayLength The length of the instant withdrawal fuses list
    error InstantWithdrawalFuseIndexOutOfBounds(uint256 index, uint256 arrayLength);
    /// @notice A signed value does not fit into an unsigned integer
    /// @dev ABI mirror: OpenZeppelin `SafeCast` error reverted inside `PlasmaVaultMarketsLib` (linked library)
    /// @param value The rejected value
    error SafeCastOverflowedIntToUint(int256 value);
    /// @notice An unsigned value does not fit into a signed integer
    /// @dev ABI mirror: OpenZeppelin `SafeCast` error reverted inside `PlasmaVaultMarketsLib` (linked library)
    /// @param value The rejected value
    error SafeCastOverflowedUintToInt(uint256 value);

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);
    event DepositFeeRealized(address recipient, uint256 feeShares);
    event ExecuteFinished(address executor, uint256 callsCount, uint256[] marketIds);
    /// @notice Performance fee account and rate stored
    /// @dev ABI mirror: emitted by `PlasmaVaultFeesLib.createFeeManager` (`PlasmaVaultLib.configurePerformanceFee`)
    ///      during proxyInitialize; the vault is the emitter (DELEGATECALL)
    /// @param feeAccount Performance fee account
    /// @param feeInPercentage Performance fee rate (10000 = 100%)
    event PerformanceFeeDataConfigured(address feeAccount, uint256 feeInPercentage);
    /// @notice Management fee account and rate stored
    /// @dev ABI mirror: emitted by `PlasmaVaultFeesLib.createFeeManager` (`PlasmaVaultLib.configureManagementFee`)
    ///      during proxyInitialize; the vault is the emitter (DELEGATECALL)
    /// @param feeAccount Management fee account
    /// @param feeInPercentage Management fee rate (10000 = 100%)
    event ManagementFeeDataConfigured(address feeAccount, uint256 feeInPercentage);
    /// @notice Market balances were updated
    /// @dev ABI mirror: emitted by `PlasmaVaultMarketsLib` (linked library, DELEGATECALL); the vault is the emitter
    /// @param marketIds Updated market ids
    /// @param deltaInUnderlying Total change of the balances in underlying
    event MarketBalancesUpdated(uint256[] marketIds, int256 deltaInUnderlying);
    /// @notice An instant withdrawal entry reverted with error data and was skipped (IL-9659)
    /// @dev ABI mirror: emitted by `PlasmaVaultMarketsLib` (linked library, DELEGATECALL); the vault is the emitter
    /// @param fuse Address of the instant withdrawal fuse of the skipped entry
    /// @param index Position of the entry in the instant withdrawal list
    /// @param errorSelector First four bytes of the revert data of the entry (zero if the data is shorter)
    event InstantWithdrawalFuseFailed(address fuse, uint256 index, bytes4 errorSelector);

    /// @notice Fallback function handling delegatecall execution and callbacks
    /// @dev Routes execution between callback handling and base contract delegation
    ///
    /// Execution Paths:
    /// 1. During Fuse Action Execution:
    ///    - Handles callbacks from protocol interactions
    ///    - Validates callback context
    ///    - Processes protocol-specific responses
    ///
    /// 2. Normal Operation:
    ///    - Delegates calls to PlasmaVaultBase (which also routes the Votes selectors to the votes plugin)
    ///    - Maintains vault functionality
    ///    - Preserves upgrade safety
    ///
    /// Security Considerations:
    /// - Validates execution context
    /// - Prevents unauthorized callbacks
    /// - Maintains delegatecall security
    /// - Protects against reentrancy
    ///
    /// @param calldata_ Raw calldata for function execution
    /// @return bytes Empty if callback, delegated result otherwise
    // solhint-disable-next-line no-unused-vars
    fallback(bytes calldata calldata_) external returns (bytes memory) {
        if (PlasmaVaultLib.isExecutionStarted()) {
            /// @dev Handle callback can be done only during the execution of the FuseActions by Alpha
            CallbackHandlerLib.handleCallback();
            return "";
        }

        /// @dev Votes selectors are routed to the votes plugin by the PlasmaVaultBase fallback (code size)
        return PLASMA_VAULT_BASE().functionDelegateCall(msg.data);
    }

    /// @notice The plasma vault base contract address
    /// @dev Retrieved from storage library
    function PLASMA_VAULT_BASE() public view returns (address) {
        return PlasmaVaultStorageLib.getPlasmaVaultBase();
    }

    /// @notice The plasma vault votes plugin contract address (PlasmaVaultVotesPlugin)
    /// @dev Retrieved from storage library. This contract provides optional ERC20Votes functionality.
    /// @return The address of the votes plugin contract, or address(0) if voting is not enabled
    function PLASMA_VAULT_VOTES_PLUGIN() public view returns (address) {
        return PlasmaVaultStorageLib.getPlasmaVaultVotesPlugin();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Locks the implementation: only clones (FusionFactory → PlasmaVaultFactory.clone) can be initialized (IL-8979).
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the PlasmaVault with initialization data (for cloning)
    /// @param initData_ Initialization parameters encapsulated in PlasmaVaultInitData struct
    /// @dev This method is called after cloning to initialize the contract
    function proxyInitialize(PlasmaVaultInitData memory initData_) external initializer {
        _initializeVault(initData_);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Executes a sequence of protocol interactions through fuse contracts
    /// @dev Processes multiple fuse actions while maintaining vault security and balance tracking
    ///
    /// Execution Flow:
    /// 1. Pre-execution
    ///    - Marks execution start
    ///    - Validates fuse support
    ///
    /// 2. Action Processing
    ///    - Executes each fuse action sequentially
    ///    - Tracks affected markets
    ///    - Handles protocol interactions
    ///    - Processes callbacks if needed
    ///
    /// 3. Post-execution
    ///    - Updates market balances of the markets of the calls and of every market touched in a callback
    ///      (executeInternal), after all callbacks returned and flash loans were repaid (IL-9404)
    ///    - Calculates and applies performance fees
    ///    - Marks execution end
    ///    - Validates final state
    ///
    /// Security Features:
    /// - Reentrancy protection
    /// - Role-based access control
    /// - Fuse validation
    /// - Market balance verification
    /// - Asset distribution protection
    ///
    /// Market Tracking:
    /// - Maintains unique market list
    /// - Updates balances atomically
    /// - Validates market limits, also of the markets touched in callbacks, only once, against the NAV after
    ///   repayment (executeInternal refreshes the callback markets without a limit check and records them in
    ///   transient storage, IL-9404, IL-9708)
    /// - Ensures balance consistency
    ///
    /// @dev Does not realize the management fee (IL-8870, Pete D-003): the accrued fee stays priced in the share
    ///      price through the virtual fee shares, and RealizeManagementFeeFuse realizes it when ALPHA runs it
    /// @param calls_ Array of FuseAction structs defining protocol interactions
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access Restricted to ALPHA_ROLE (managed by ATOMIST_ROLE)
    function execute(FuseAction[] calldata calls_) external override nonReentrant restricted {
        uint256 callsCount = calls_.length;
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex;
        uint256 fuseMarketId;

        PlasmaVaultLib.executeStarted();

        for (uint256 i; i < callsCount; ++i) {
            if (!FusesLib.isFuseSupported(calls_[i].fuse)) {
                revert UnsupportedFuse();
            }

            fuseMarketId = IFuseCommon(calls_[i].fuse).MARKET_ID();

            if (_checkIfExistsMarket(markets, fuseMarketId) == false) {
                markets[marketIndex] = fuseMarketId;
                marketIndex++;
            }

            calls_[i].fuse.functionDelegateCall(calls_[i].data);
        }

        PlasmaVaultLib.executeFinished();

        /// @dev markets touched in callbacks (executeInternal) are refreshed and limit-checked again after the
        ///      callbacks returned, against the NAV after repayment (IL-9404)
        markets = PlasmaVaultMarketsLib.takeCallbackMarkets(markets);

        _updateMarketsBalances(markets, true);

        _addPerformanceFee();

        emit ExecuteFinished(_msgSender(), callsCount, markets);
    }

    /// @notice Updates balances for specified markets and calculates performance fees
    /// @dev Refreshes market balances and applies performance fee calculations
    ///
    /// Update Flow:
    /// 1. Balance Calculation
    ///    - Updates specified market balances
    ///
    /// 2. Fee Processing
    ///    - Calculates performance fee
    ///    - Updates fee data
    ///    - Applies fee adjustments
    ///
    /// Security Features:
    /// - Market validation
    /// - Balance verification
    /// - Fee calculation safety
    /// - Access control via UPDATE_MARKETS_BALANCES_ROLE
    ///
    /// @dev Does not realize the management fee (IL-8870, Pete D-003); the performance fee is charged on the net
    ///      share price after the refresh, without a loss gate (IL-9403)
    /// @dev Stores the refreshed balances without the market limit check, also of a market that is above its limit
    ///      (IL-9612, Olympix M22). A refresh moves no assets, so it cannot allocate past a limit: execute and
    ///      executeInternal still check the limits of the markets they touch; the market pulls of withdraw and redeem
    ///      do not (IL-9694 D-003). Before IL-9612 every refresh of an over-limit market (after a price move or after
    ///      exits shrank the NAV) reverted with MarketLimitExceeded and the cache stayed stale, so deposits were
    ///      priced on it. The pre-hooks that refresh through this function (UpdateBalancesPreHook and its variants, the HyperCore
    ///      capital flow hooks) therefore no longer revert user flows on a market limit.
    /// @param marketIds_ Array of market IDs to update
    /// @return uint256 Updated total assets after balance refresh
    /// @custom:access Restricted to UPDATE_MARKETS_BALANCES_ROLE (Roles.UPDATE_MARKETS_BALANCES_ROLE = 1000)
    function updateMarketsBalances(uint256[] calldata marketIds_) external restricted returns (uint256) {
        if (marketIds_.length == 0) {
            return totalAssets();
        }
        _updateMarketsBalances(marketIds_, false);
        _addPerformanceFee();

        return totalAssets();
    }

    /// @notice Realizes the accrued management fee now by minting the fee shares to the management fee account
    /// @dev IL-8870 (Pete D-001, D-004): ALPHA collects the fee without a deposit or a withdrawal, and without
    ///      execute, a market refresh or oracle reads. It runs the same `_realizeManagementFee` as deposit, mint,
    ///      withdraw and redeem: the fee clock always advances, a fee that rounds to zero shares stays pending
    ///      (IL-6959, IL-8318), and the share price (convertToAssets) is the same before and after the call because
    ///      the views already price the accrued fee as virtual fee shares.
    /// @dev Runs outside execute, so the order rule of RealizeManagementFeeFuse does not apply. The fee is priced on
    ///      the stored, possibly stale, market balances: with a large pending fee, refresh the markets first
    ///      (updateMarketsBalances) for an exact collection. A later refresh revalues the minted shares by about
    ///      pendingFee * (change in gross assets) / gross assets.
    /// @return uint256 Management fee shares minted, 0 when nothing was minted
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access Restricted to ALPHA_ROLE (mapped by IporFusionAccessManagerInitializerLibV1)
    function realizeManagementFee() external override nonReentrant restricted returns (uint256) {
        return _realizeManagementFee();
    }

    /// @notice Crystallizes the performance fee owed at the current net share price, at the rate in force now
    /// @dev IL-9632 (Olympix L01): FeeManager.updatePerformanceFee calls this before it harvests the performance fee
    ///      account and writes the new rate and recipient split, so the gain above the high-water mark earned under
    ///      the old rate is charged at the old rate and paid to the old recipients; the new rate applies only to the
    ///      gain after the change. Runs the same `_addPerformanceFee` as execute, updateMarketsBalances, withdraw and
    ///      redeem (also the high-water mark lowering after the update interval), and does not realize the
    ///      management fee. The fee is priced on the stored market balances: refresh the markets first, in the same
    ///      batch (updateMarketsBalances), so that a gain not yet booked is also charged at the old rate.
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access Restricted to TECH_PERFORMANCE_FEE_MANAGER_ROLE, held by the FeeManager (mapped by
    ///      IporFusionAccessManagerInitializerLibV1)
    function realizePerformanceFee() external override nonReentrant restricted {
        _addPerformanceFee();
    }

    /// @notice Returns the number of decimals used by the vault shares
    /// @dev Overrides both ERC20 and ERC4626 decimals functions to ensure consistency
    ///
    /// Decimal Handling:
    /// - Returns same decimals as underlying asset
    /// - Maintains ERC20/ERC4626 compatibility
    /// - Critical for share price calculations
    /// - Used in conversion operations
    ///
    /// Integration Context:
    /// - Share/asset conversion
    /// - Price calculations
    /// - Balance representation
    /// - Protocol interactions
    ///
    /// @return uint8 Number of decimals used for share token
    /// @custom:access Public view function, no role restrictions
    function decimals() public view virtual override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return super.decimals();
    }

    /// @notice Transfers vault shares between addresses
    /// @dev Overrides ERC20 transfer with additional access control
    ///
    /// Transfer Mechanics:
    /// - Validates transfer permissions
    /// - Updates share balances
    /// - Maintains voting power
    /// - Enforces access control
    ///
    /// Security Features:
    /// - Role-based access control
    /// - Balance validation
    /// - State consistency checks
    /// - Voting power updates
    ///
    /// Integration Context:
    /// - Share transferability
    /// - Secondary market support
    /// - Governance participation
    /// - Protocol interactions
    ///
    /// @param to_ Recipient address for the transfer
    /// @param value_ Amount of shares to transfer
    /// @return bool Success of the transfer operation
    /// @custom:access Initially restricted, can be set to PUBLIC_ROLE via enableTransferShares
    function transfer(
        address to_,
        uint256 value_
    ) public virtual override(IERC20, ERC20Upgradeable) restricted returns (bool) {
        return super.transfer(to_, value_);
    }

    /// @notice Transfers vault shares from one address to another with allowance
    /// @dev Overrides ERC20 transferFrom with additional access control
    ///
    /// Transfer Mechanics:
    /// - Validates transfer permissions
    /// - Checks and updates allowances
    /// - Updates share balances
    /// - Maintains voting power
    ///
    /// Security Features:
    /// - Role-based access control
    /// - Allowance validation
    /// - Balance verification
    /// - State consistency checks
    ///
    /// Integration Context:
    /// - Delegated transfers
    /// - Protocol integrations
    /// - Secondary market support
    /// - Governance participation
    ///
    /// @param from_ Address to transfer shares from
    /// @param to_ Address to transfer shares to
    /// @param value_ Amount of shares to transfer
    /// @return bool Success of the transfer operation
    /// @custom:access Initially restricted, can be set to PUBLIC_ROLE via enableTransferShares
    function transferFrom(
        address from_,
        address to_,
        uint256 value_
    ) public virtual override(IERC20, ERC20Upgradeable) restricted returns (bool) {
        return super.transferFrom(from_, to_, value_);
    }

    /// @notice Deposits underlying assets into the vault
    /// @dev Handles deposit validation, share minting, and fee realization
    ///
    /// Deposit Flow:
    /// 1. Pre-deposit Checks
    ///    - Validates deposit amount
    ///    - Verifies receiver address
    ///    - Checks deposit permissions
    ///    - Validates supply cap
    ///
    /// 2. Fee Processing
    ///    - Realizes pending management fees
    ///    - Updates fee accounting
    ///    - Adjusts share calculations
    ///
    /// 3. Asset Transfer
    ///    - Transfers assets to vault
    ///    - Calculates share amount
    ///    - Mints vault shares
    ///    - Updates balances
    ///
    /// Security Features:
    /// - Non-zero amount validation
    /// - Address validation
    /// - Reentrancy protection
    /// - Access control checks
    ///
    /// @param assets_ Amount of underlying assets to deposit
    /// @param receiver_ Address to receive the minted shares
    /// @return uint256 Amount of shares minted
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access Initially restricted to WHITELIST_ROLE, can be set to PUBLIC_ROLE via convertToPublicVault
    function deposit(uint256 assets_, address receiver_) public override nonReentrant restricted returns (uint256) {
        return _deposit(assets_, receiver_);
    }

    /// @notice Deposits assets into vault using ERC20 permit for gasless approvals
    /// @dev Combines permit signature verification with deposit operation
    ///
    /// Operation Flow:
    /// 1. Permit Processing
    ///    - Verifies permit signature
    ///    - Updates token allowance
    ///    - Validates permit parameters
    ///
    /// 2. Deposit Execution
    ///    - Processes asset transfer
    ///    - Calculates share amount
    ///    - Mints vault shares
    ///    - Updates balances
    ///
    /// Security Features:
    /// - Signature validation
    /// - Deadline enforcement
    /// - Reentrancy protection
    /// - Access control checks
    ///
    /// Integration Context:
    /// - Gasless deposits
    /// - Meta-transaction support
    /// - ERC20 permit compatibility
    /// - Vault share minting
    ///
    /// @param assets_ Amount of assets to deposit
    /// @param receiver_ Address to receive the minted shares
    /// @param deadline_ Timestamp until which the signature is valid
    /// @param v_ Recovery byte of the signature
    /// @param r_ First 32 bytes of the signature
    /// @param s_ Second 32 bytes of the signature
    /// @return uint256 Amount of shares minted
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access Initially restricted to WHITELIST_ROLE, can be set to PUBLIC_ROLE via convertToPublicVault
    function depositWithPermit(
        uint256 assets_,
        address receiver_,
        uint256 deadline_,
        uint8 v_,
        bytes32 r_,
        bytes32 s_
    ) external override nonReentrant restricted returns (uint256) {
        try IERC20Permit(asset()).permit(_msgSender(), address(this), assets_, deadline_, v_, r_, s_) {
            /// @dev Permit successful, proceed with deposit
        } catch {
            /// @dev Check if we already have sufficient allowance
            if (IERC20(asset()).allowance(_msgSender(), address(this)) < assets_) {
                revert PermitFailed();
            }
        }
        return _deposit(assets_, receiver_);
    }

    /// @notice Mints vault shares by depositing underlying assets
    /// @dev Handles share minting with management fee realization
    ///
    /// Minting Flow:
    /// 1. Pre-mint Validation
    ///    - Validates share amount
    ///    - Checks receiver address
    ///    - Verifies permissions
    ///
    /// 2. Fee Processing
    ///    - Realizes pending management fees
    ///    - Updates fee accounting
    ///    - Adjusts share calculations
    ///
    /// 3. Share Minting
    ///    - Calculates asset amount
    ///    - Transfers assets
    ///    - Mints shares
    ///    - Updates balances
    ///
    /// Security Features:
    /// - Non-zero amount validation
    /// - Address validation
    /// - Reentrancy protection
    /// - Access control checks
    ///
    /// @dev The deposit fee is a share of the gross shares, the same base as deposit: the receiver gets
    ///      `shares_`, the fee shares minted to the fee recipient are `shares_ * fee / (1 - fee)` rounded up,
    ///      so the assets paid equal what a deposit that yields `shares_` costs (IL-8743)
    /// @param shares_ Number of vault shares to mint (net of the deposit fee)
    /// @param receiver_ Address to receive the minted shares
    /// @return depositAssets Amount of assets deposited
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access Initially restricted to WHITELIST_ROLE, can be set to PUBLIC_ROLE via convertToPublicVault
    function mint(
        uint256 shares_,
        address receiver_
    ) public override nonReentrant restricted returns (uint256 depositAssets) {
        if (shares_ == 0) {
            revert NoSharesToMint();
        }

        if (receiver_ == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        (address feeRecipient, uint256 feeShares) = PlasmaVaultFeesLib.calculateMintDepositFee(shares_);

        depositAssets = super.mint(shares_, receiver_);

        if (feeShares > 0) {
            super._mint(feeRecipient, feeShares);
            emit DepositFeeRealized(feeRecipient, feeShares);
        }
    }

    /// @notice Withdraws underlying assets from the vault
    /// @dev Handles asset withdrawal with fee realization and market rebalancing
    ///
    /// Withdrawal Flow:
    /// 1. Pre-withdrawal
    ///    - Validates withdrawal amount
    ///    - Checks addresses
    ///    - Realizes management fees
    ///
    /// 2. Market Operations
    ///    - Withdraws assets from markets
    ///    - Handles rounding with offset
    ///    - Updates market balances
    ///    - Processes performance fees
    ///
    /// 3. Asset Transfer
    ///    - Burns vault shares
    ///    - Transfers assets
    ///    - Updates balances
    ///    - Validates final state
    ///
    /// Security Features:
    /// - Withdrawal limit validation
    /// - Reentrancy protection
    /// - Access control checks
    /// - Balance verification
    /// - Market safety checks
    ///
    /// @dev The withdraw fee is a share of the gross shares burned, the same base as redeem: the shares burned
    ///      equal what a redeem that pays `assets_` burns (gross = net / (1 - fee), rounded up) (IL-8751)
    /// @param assets_ Amount of underlying assets to withdraw
    /// @param receiver_ Address to receive the withdrawn assets
    /// @param owner_ Owner of the vault shares
    /// @return withdrawnShares uint256 Amount of shares burned
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access PUBLIC_ROLE with WithdrawManager restrictions if enabled
    function withdraw(
        uint256 assets_,
        address receiver_,
        address owner_
    ) public override nonReentrant restricted returns (uint256 withdrawnShares) {
        if (assets_ == 0) {
            revert NoAssetsToWithdraw();
        }

        if (receiver_ == address(0) || owner_ == address(0)) {
            revert Errors.WrongAddress();
        }

        /// @dev first realize management fee, then other actions
        _realizeManagementFee();

        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        uint256 sharesToRelease = WithdrawManager(withdrawManager).getSharesToRelease();

        uint256 withdrawFee = WithdrawManager(withdrawManager).getWithdrawFee();

        if (sharesToRelease > 0) {
            /// @dev When shares are in withdrawal request, we need to withdraw more assets to cover the shares and use offset
            /// @dev Offset of 0.01% (10001/10000) covers rounding errors only; the released-shares reserve is priced
            ///      again after every pull, because the refresh of the touched markets books their unrecorded yield and
            ///      raises the share price, and a later pull may reach a market not touched before (IL-9436)
            /// @dev WITHDRAW_FROM_MARKETS_OFFSET is kept so a dust release does not strip the buffer for assets_ (IL-8357)
            /// @dev The WithdrawManager check needs the released shares plus the GROSS shares (fee included)
            ///      unallocated, so the pull is sized on the gross amount, as redeem does (IL-8751)
            /// @dev WITHDRAW_FROM_MARKETS_OFFSET is grossed up together with assets_: PlasmaVault grosses up the ceil-rounded
            ///      shares before canWithdrawFromUnallocated (the WithdrawManager only compares), so their rounding
            ///      error grows by 1 / (1 - fee) and the buffer must grow with it (IL-8357, IL-8838)
            uint256 assetsToWithdrawGross = withdrawFee < 1e18
                ? PlasmaVaultFeesLib.grossUpForWithdrawFee(assets_ + WITHDRAW_FROM_MARKETS_OFFSET, withdrawFee)
                : assets_ + WITHDRAW_FROM_MARKETS_OFFSET;

            uint256 previousIdleAssets;
            for (uint256 i; i < REDEEM_ATTEMPTS; ++i) {
                uint256 idleAssets = IERC20(asset()).balanceOf(address(this));
                uint256 target = assetsToWithdrawGross + (convertToAssets(sharesToRelease) * 10001) / 10000;
                /// @dev A round that added no idle assets means the markets cannot supply more in this block (IL-9436)
                if (target <= idleAssets || (i != 0 && idleAssets <= previousIdleAssets)) {
                    break;
                }
                previousIdleAssets = idleAssets;
                _withdrawFromMarkets(target, idleAssets);
            }
        } else {
            _withdrawFromMarkets(assets_ + WITHDRAW_FROM_MARKETS_OFFSET, IERC20(asset()).balanceOf(address(this)));
        }

        _addPerformanceFee();

        /// @dev IL-9624: the performance fee was crystallized just above, so nothing is pending and the limit skips
        ///      the simulation that the public maxWithdraw runs (it would price zero shares)
        /// @dev IL-9624 follow-up: the limit is still the balance less the withdraw fee. It reads neither the closed
        ///      flag (`_checkCanCall` has already enforced it) nor the released-request reserve that the public
        ///      maxWithdraw applies: the WithdrawManager enforces the reserve in `canWithdrawFromUnallocated` below
        uint256 maxAssets = _convertToAssets(_maxWithdrawShares(balanceOf(owner_)), Math.Rounding.Floor);

        if (assets_ > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner_, assets_, maxAssets);
        }

        uint256 sharesForAssets = super.previewWithdraw(assets_);

        if (sharesForAssets == 0) {
            revert NoSharesToWithdraw();
        }

        // The withdraw fee is a share of the gross shares, as in redeem: gross = net / (1 - fee) (IL-8751)
        uint256 feeSharesToBurn = WithdrawManager(withdrawManager).canWithdrawFromUnallocated(
            PlasmaVaultFeesLib.grossUpForWithdrawFee(sharesForAssets, withdrawFee)
        );

        withdrawnShares = sharesForAssets + feeSharesToBurn;

        super._withdraw(_msgSender(), receiver_, owner_, assets_, sharesForAssets);

        if (feeSharesToBurn > 0) {
            if (_msgSender() != owner_) {
                _spendAllowance(owner_, _msgSender(), feeSharesToBurn);
            }
            _burn(owner_, feeSharesToBurn);
        }
    }

    /// @dev Priced net of the accrued management fee: the conversion counts the virtual fee shares that the
    ///      realization in deposit mints first, so the preview equals the shares deposit mints (IL-8870)
    function previewDeposit(uint256 assets_) public view override returns (uint256) {
        uint256 shares = super.previewDeposit(assets_);
        (, uint256 feeShares) = PlasmaVaultFeesLib.prepareForRealizeDepositFee(shares);
        return feeShares > 0 ? shares - feeShares : shares;
    }

    /// @dev The deposit fee is a share of the gross shares, as in deposit: the caller pays for
    ///      shares_ / (1 - fee) shares and receives shares_ (IL-8743)
    /// @dev Priced net of the accrued management fee, like previewDeposit (IL-8870)
    function previewMint(uint256 shares_) public view override returns (uint256) {
        (, uint256 feeShares) = PlasmaVaultFeesLib.calculateMintDepositFee(shares_);
        return super.previewMint(shares_ + feeShares);
    }

    /// @dev Priced after the management fee realization that redeem performs first: the conversion counts the
    ///      virtual fee shares that this realization mints, so no special supply is needed (IL-8343, IL-8870)
    /// @dev IL-9624 (Olympix M34): also priced after the performance fee that redeem crystallizes before it pays
    ///      (rate above the high-water mark): the supply counts the fee shares that the FeeManager would size now
    ///      (`_supplyWithPendingFeesAndGrossAssets`), so with fresh market balances this equals redeem. Not priced:
    ///      a refresh of stale market balances in redeem, which can make this overestimate the assets paid by the
    ///      caller's share of the refresh delta (IL-8489)
    function previewRedeem(uint256 shares_) public view override returns (uint256) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager != address(0)) {
            uint256 withdrawFee = WithdrawManager(withdrawManager).getWithdrawFee();
            if (withdrawFee > 0) {
                shares_ = Math.mulDiv(shares_, 1e18 - withdrawFee, 1e18);
            }
        }

        (uint256 supply, uint256 grossTotalAssets) = _supplyWithPendingFeesAndGrossAssets();
        return _convertToAssetsWithSupply(shares_, supply, grossTotalAssets, Math.Rounding.Floor);
    }

    /// @dev Priced after the management fee realization that withdraw performs first: the conversion counts the
    ///      virtual fee shares that this realization mints, so no special supply is needed (IL-8343, IL-8870)
    /// @dev The withdraw fee is a share of the gross shares (as in redeem): returns net / (1 - fee) rounded up,
    ///      type(uint256).max when the fee is 100% (nothing can be withdrawn) (IL-8751)
    /// @dev IL-9624 (Olympix M34): also priced after the performance fee that withdraw crystallizes before it
    ///      prices the burn (rate above the high-water mark), like previewRedeem, so with fresh market balances this
    ///      equals the shares withdraw burns. Not priced: a refresh of stale market balances in withdraw, which can
    ///      make this underestimate the shares burned by the caller's share of the refresh delta (IL-8489)
    function previewWithdraw(uint256 assets_) public view override returns (uint256) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
        (uint256 supply, uint256 grossTotalAssets) = _supplyWithPendingFeesAndGrossAssets();
        uint256 shares = _convertToSharesWithSupply(assets_, supply, grossTotalAssets, Math.Rounding.Ceil);

        if (withdrawManager != address(0)) {
            // Gross shares that leave `shares` after the fee: gross = shares / (1 - withdrawFee), rounded up.
            // A 100% fee leaves nothing to withdraw: type(uint256).max (IL-8751)
            return PlasmaVaultFeesLib.grossUpForWithdrawFee(shares, WithdrawManager(withdrawManager).getWithdrawFee());
        }
        return shares;
    }

    /// @notice Redeems vault shares for underlying assets
    /// @dev Handles share redemption with fee realization and iterative withdrawal
    ///
    /// Redemption Flow:
    /// 1. Pre-redemption
    ///    - Validates share amount
    ///    - Checks addresses
    ///    - Realizes management fees
    ///
    /// 2. Asset Withdrawal
    ///    - Calculates asset amount
    ///    - Attempts market withdrawals
    ///    - Handles slippage protection
    ///    - Retries if needed (up to REDEEM_ATTEMPTS)
    ///
    /// 3. Fee Processing
    ///    - Mints the performance fee owed at the current share price
    ///    - Applies performance fees
    ///    - Updates fee accounting
    ///    - Finalizes redemption
    ///
    /// Security Features:
    /// - Multiple withdrawal attempts
    /// - Slippage protection
    /// - Reentrancy guard
    /// - Balance verification
    /// - Access control checks
    ///
    /// @param shares_ Amount of vault shares to redeem
    /// @param receiver_ Address to receive the underlying assets
    /// @param owner_ Owner of the vault shares
    /// @return withdrawnAssets uint256 Amount of underlying assets withdrawn
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access PUBLIC_ROLE with WithdrawManager restrictions if enabled
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_
    ) public override nonReentrant restricted returns (uint256 withdrawnAssets) {
        /// @dev IL-9679: `_checkCanCall` (restricted) has already reverted on the owner's redemption lock, so the
        ///      limit is the balance; the public maxRedeem would read the lock from the access manager again
        /// @dev IL-9624 follow-up: the public maxRedeem also reads the closed flag (enforced here by `_checkCanCall`
        ///      too) and, with released request shares, caps the balance by the released-request reserve. The limit
        ///      here stays the balance: the WithdrawManager enforces the reserve in `canWithdrawFromUnallocated`
        uint256 maxShares = balanceOf(owner_);
        if (shares_ > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner_, shares_, maxShares);
        }

        withdrawnAssets = _redeem(shares_, receiver_, owner_, true);
    }

    /// @notice Redeems shares from a previously submitted withdrawal request
    /// @dev Processes redemption of shares that were part of an approved withdrawal request
    ///
    /// Redemption Flow:
    /// 1. Request Validation
    ///    - Verifies request exists via WithdrawManager
    ///    - Checks withdrawal window timing
    ///    - Validates share amount availability
    ///    - Confirms release funds timestamp
    ///
    /// 2. Share Processing
    ///    - Executes share redemption
    ///    - Handles asset transfer
    ///    - Updates request state
    ///    - No fee application (unlike standard redeem)
    ///
    /// Security Features:
    /// - Request-based access control
    /// - Withdrawal window enforcement
    /// - Share amount validation
    /// - State consistency checks
    /// - Atomic execution
    /// - Reentrancy protection: shares the ReentrancyGuard flag with deposit/mint/withdraw/redeem/execute,
    ///   so an instant withdrawal fuse that yields control to an external protocol during the market unwind
    ///   cannot re-enter the vault while totalAssets() is transiently inflated.
    ///   The lock covers the guarded entry points (for example deposit, depositWithPermit, mint, withdraw, redeem,
    ///   redeemFromRequest, execute), but the share-price views stay readable by other contracts during this unwind
    ///   and during execute and can show a transient value; see "Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)"
    ///   in contracts/vaults/README.md
    ///
    /// Integration Points:
    /// - WithdrawManager for request validation
    /// - ERC4626 share redemption
    /// - Asset transfer system
    /// - Balance tracking
    ///
    /// Important Notes:
    /// - Different from standard redeem
    /// - No withdrawal fee applied
    /// - Requires prior request
    /// - Time-window restricted
    /// - Request-bound redemption
    /// - Lock-free: no redemption delay (`RedemptionDelayLib.lockChecks`) is applied, by design. This is the
    ///   exit for holders whose instant exit a third party keeps relocking, and the exit that dispatchers and
    ///   vault-of-vaults use with owner = address(this). The shares are capped by `balanceOf(owner_)`, not by
    ///   maxRedeem, which returns 0 during the owner's redemption lock (IL-9679). From the IL-9624 follow-up on,
    ///   maxRedeem also returns 0 while the vault is closed and caps the balance by the released-request reserve;
    ///   this call still caps by the balance only
    /// - Backed (IL-9531): the WithdrawManager lets `owner_` redeem at most the shares it has held without a break
    ///   since the request (`getRequestCap`); a request filed during the owner's redemption lock starts when that lock
    ///   ends. Deposits to `owner_` after the request change neither. See `WithdrawManager.requestShares`
    ///
    /// @param shares_ Amount of shares to redeem from the request
    /// @param receiver_ Address to receive the underlying assets
    /// @param owner_ Owner of the shares being redeemed
    /// @return uint256 Amount of underlying assets transferred to receiver
    /// @custom:access Restricted to accounts with valid withdrawal requests
    function redeemFromRequest(
        uint256 shares_,
        address receiver_,
        address owner_
    ) external override nonReentrant restricted returns (uint256) {
        bool canWithdraw = WithdrawManager(PlasmaVaultStorageLib.getWithdrawManager().manager).canWithdrawFromRequest(
            owner_,
            shares_
        );

        if (!canWithdraw) {
            revert WithdrawManagerInvalidSharesToRelease(shares_);
        }

        /// @dev IL-9679: lock-free cap from the balance; maxRedeem returns 0 during the owner's redemption lock
        /// @dev IL-9624 follow-up: still the balance, not the public maxRedeem with its closed flag and
        ///      released-request reserve
        uint256 maxShares = balanceOf(owner_);

        if (shares_ > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner_, shares_, maxShares);
        }

        return _redeem(shares_, receiver_, owner_, false);
    }

    /// @inheritdoc IPlasmaVaultRequestCap
    /// @custom:access The vault's WithdrawManager only
    function setRequestCap(address account_, uint256 shares_) external override {
        if (msg.sender != PlasmaVaultStorageLib.getWithdrawManager().manager) {
            revert AccessManagedUnauthorized(msg.sender);
        }
        PlasmaVaultStorageLib.getRequestCaps().caps[account_] = shares_;
    }

    /// @inheritdoc IPlasmaVaultRequestCap
    function getRequestCap(address account_) external view override returns (uint256) {
        return PlasmaVaultStorageLib.getRequestCaps().caps[account_];
    }

    /// @notice Calculates maximum deposit amount allowed for an address
    /// @dev Overrides ERC4626 maxDeposit considering total supply cap
    ///
    /// Calculation Flow:
    /// 1. Supply Validation
    ///    - Retrieves total supply cap
    ///    - Gets current total supply plus the pending management fee shares
    ///    - Checks available capacity
    ///
    /// 2. Conversion Logic
    ///    - Calculates remaining space
    ///    - Converts to asset amount
    ///    - Handles edge cases
    ///
    /// Constraints:
    /// - Returns 0 if cap is reached or while the vault is closed (IL-9624 follow-up)
    /// - Respects supply cap limits
    /// - Considers share/asset ratio
    /// - Maintains vault integrity
    ///
    /// @dev Priced after the management fee realization that deposit performs before it checks this limit: the
    ///      fee shares it mints bypass the cap, so the virtual fee shares are counted in the supply here
    ///      (IL-8490, IL-8870)
    /// @dev The virtual fee shares can floor the unit price to zero when the accrued fee is close to the assets
    ///      (Codex review #1, IL-8870). The overflow check divides by the unit price only when it is non-zero;
    ///      with a zero unit price one share is worth less than one asset unit, so the conversion cannot overflow.
    /// @dev IL-9624 follow-up: 0 while the vault is closed in its access manager (`isTargetClosed`, set by GUARDIAN
    ///      with `updateTargetClosed`). The access manager checks the closed flag before the role, so it rejects every
    ///      `restricted` call of the vault, deposit, depositWithPermit and mint among them, for every caller
    ///      (ERC-4626 asks for 0 when deposits are disabled); getters and views keep working. Reopening restores the
    ///      value at once. Access roles and pre-hooks are still not reflected: they depend on the caller, and the
    ///      view knows only the receiver (IL-9680, IL-8639)
    /// @dev Cost: deposit and depositWithPermit check this limit inside the call (ERC-4626 deposit), so each pays
    ///      one more access manager read (`_isVaultClosed`)
    /// @return uint256 Maximum amount of assets that can be deposited
    /// @custom:access Public view function, no role restrictions
    function maxDeposit(address) public view virtual override returns (uint256) {
        if (_isVaultClosed()) {
            return 0;
        }
        uint256 totalSupplyCap = PlasmaVaultLib.getTotalSupplyCap();
        (uint256 supply, uint256 grossTotalAssets) = _supplyWithManagementFeeAndGrossAssets();

        if (supply >= totalSupplyCap) {
            return 0;
        }

        uint256 exchangeRate = _convertToAssetsWithSupply(
            10 ** uint256(decimals()),
            supply,
            grossTotalAssets,
            Math.Rounding.Floor
        );
        (, uint256 feeShares) = PlasmaVaultFeesLib.prepareForRealizeDepositFee(totalSupplyCap - supply);
        uint256 sharesToMint = totalSupplyCap - supply - feeShares;

        if (exchangeRate != 0 && type(uint256).max / exchangeRate < sharesToMint) {
            return type(uint256).max;
        }

        return _convertToAssetsWithSupply(sharesToMint, supply, grossTotalAssets, Math.Rounding.Floor);
    }

    /// @notice Calculates maximum number of shares that can be minted
    /// @dev Overrides ERC4626 maxMint considering total supply cap
    ///
    /// Calculation Flow:
    /// 1. Supply Validation
    ///    - Retrieves total supply cap
    ///    - Gets current total supply plus the pending management fee shares
    ///    - Validates remaining capacity
    ///
    /// 2. Share Calculation
    ///    - Computes available share space
    ///    - Handles cap constraints
    ///    - Returns maximum mintable shares
    ///
    /// Constraints:
    /// - Returns 0 if cap is reached or while the vault is closed (IL-9624 follow-up)
    /// - Respects total supply limit
    /// - Direct share calculation
    /// - No asset conversion needed
    ///
    /// @dev Priced after the management fee realization that mint performs before it checks this limit: the
    ///      fee shares it mints bypass the cap, so the virtual fee shares are counted in the supply here
    ///      (IL-8490, IL-8870)
    /// @dev Returns the net shares whose gross (net plus the deposit fee, a share of the gross) fits into
    ///      the remaining cap, so mint(maxMint) does not exceed the cap (IL-8743)
    /// @dev IL-9624 follow-up: 0 while the vault is closed in its access manager, as maxDeposit (the access manager
    ///      rejects every `restricted` call of the vault, mint among them, for every caller; reopening restores the
    ///      value at once). Access roles and pre-hooks are still not reflected: they depend on the caller, and the
    ///      view knows only the receiver (IL-9680, IL-8639)
    /// @dev Cost: mint checks this limit inside the call (ERC-4626 mint), so it pays one more access manager read
    ///      (`_isVaultClosed`)
    /// @return uint256 Maximum number of shares that can be minted
    /// @custom:access Public view function, no role restrictions
    function maxMint(address) public view virtual override returns (uint256) {
        if (_isVaultClosed()) {
            return 0;
        }
        uint256 totalSupplyCap = PlasmaVaultLib.getTotalSupplyCap();
        (uint256 supply, ) = _supplyWithManagementFeeAndGrossAssets();

        if (supply >= totalSupplyCap) {
            return 0;
        }

        /// @dev net shares whose gross (net plus the fee minted on top) still fits into the remaining cap (IL-8743)
        return PlasmaVaultFeesLib.netSharesForRoom(totalSupplyCap - supply);
    }

    /// @notice Calculates maximum withdrawal amount considering withdrawal fees
    /// @dev Overrides ERC4626 maxWithdraw to account for withdrawal fee deduction
    /// @dev Priced after the management fee realization that withdraw performs before it checks this limit: the
    ///      conversion counts the virtual fee shares that this realization mints, so withdraw(maxWithdraw(owner))
    ///      does not revert on the management fee shares it mints (IL-8319, IL-8870)
    /// @dev IL-9624 (Olympix M34): also priced after the performance fee that withdraw crystallizes before it
    ///      checks this limit (rate above the high-water mark, e.g. after vesting rewards, a donation or a withdraw
    ///      fee burn), so withdraw(maxWithdraw(owner)) no longer reverts on that fee. Still not a hard guarantee:
    ///      withdraw refreshes the stale market balances it pulls from before the check, which is not simulated
    ///      here; after a market loss not yet cached the in-call limit is lower by the owner's share of the loss and
    ///      withdraw(maxWithdraw(owner)) reverts with ERC4626ExceededMaxWithdraw. To exit a whole position, use
    ///      redeem(balanceOf(owner)) (IL-8489), unless the released-request reserve below binds the owner: that
    ///      redeem then reverts with WithdrawManagerInvalidSharesToRelease, and the owner exits with
    ///      redeemFromRequest for its released request and redeem(maxRedeem(owner))
    /// @dev Exit order under the reserve: redeemFromRequest BEFORE redeem. An ordinary redeem burns shares and
    ///      lowers the owner's request cap (`getRequestCap`) to the remaining balance, while only
    ///      redeemFromRequest lowers R. After an instant-first exit the rest of the request is redeemable only up
    ///      to the balance, so part of R stays reserved for nobody and keeps binding other holders until ALPHA
    ///      releases again. The exact residual depends on offsets and fees
    /// @dev The withdraw fee is a share of the gross shares (as in redeem and previewRedeem): the owner's
    ///      balance is worth balance * (1 - fee) net shares; 0 when the fee is 100% (IL-8751)
    /// @dev IL-9679 (Olympix 2026-11-06 L48): 0 while the owner's redemption lock is active, because withdraw
    ///      reverts then; outside the lock as above. The lock is read like in maxRedeem (`_isRedemptionLocked`).
    ///      The limit inside withdraw does not read it again: `_checkCanCall` has already enforced it
    /// @dev IL-9624 follow-up, closed vault: 0 while the vault is closed in its access manager, as maxRedeem (the
    ///      access manager rejects every `restricted` call of the vault, withdraw and redeem among them, for every
    ///      caller; reopening restores the value at once). Access roles and pre-hooks are still not reflected: they
    ///      depend on the caller, and the view knows only the owner (IL-9680, IL-8639)
    /// @dev IL-9624 follow-up, released-request reserve: the gross shares priced here are maxRedeem(owner), the
    ///      balance capped by max(C - R, 0) when request shares R are released (`_unreservedShares`), so
    ///      maxWithdraw(owner) == previewRedeem(maxRedeem(owner)), also while the cap binds. With a withdraw fee,
    ///      redeem(maxRedeem(owner)) can pay one asset unit more than this (rounding of the fee burn, in the holder's
    ///      favour). An upper bound, not a guarantee: the cap counts every gross asset as available and does not
    ///      reflect the liquidity of the markets, the RewardsClaimManager balance or a refresh of stale market
    ///      balances in the exit (IL-8489). With R = 0 the result is unchanged: previewRedeem(balanceOf(owner))
    /// @dev Reads, after the closed flag and the owner's lock (each ends the view with 0): `getSharesToRelease`, also
    ///      when R = 0, then one valuation with the pending fees, whose supply and gross assets serve both the
    ///      reserve cap and the conversion. The limit inside withdraw gets no new check: it is still the balance less
    ///      the withdraw fee, and the WithdrawManager enforces the reserve
    /// @param owner_ The address to calculate max withdrawal for
    /// @return uint256 Maximum amount of assets that can be withdrawn
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (_isVaultClosed() || _isRedemptionLocked(owner_)) {
            return 0;
        }
        uint256 sharesToRelease = _sharesToRelease();
        (uint256 supply, uint256 grossTotalAssets) = _supplyWithPendingFeesAndGrossAssets();
        uint256 grossShares = Math.min(balanceOf(owner_), _unreservedShares(sharesToRelease, supply, grossTotalAssets));
        return
            _convertToAssetsWithSupply(_maxWithdrawShares(grossShares), supply, grossTotalAssets, Math.Rounding.Floor);
    }

    /// @notice Net shares that a withdraw can pay out of `grossShares_`: the gross shares less the withdraw fee share
    /// @dev Shared by maxWithdraw (the balance capped by the released-request reserve, priced with the pending
    ///      performance fee) and the limit inside withdraw (the balance, priced after the crystallization, IL-9624)
    /// @param grossShares_ Gross shares of the owner that the exit may burn
    /// @return ownerShares Net shares
    function _maxWithdrawShares(uint256 grossShares_) private view returns (uint256 ownerShares) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
        ownerShares = grossShares_;

        if (withdrawManager != address(0)) {
            uint256 withdrawFee = WithdrawManager(withdrawManager).getWithdrawFee();

            if (withdrawFee > 0) {
                // The fee is a share of the gross shares (as in redeem): net = gross * (1 - feeRate) (IL-8751)
                ownerShares = Math.mulDiv(ownerShares, 1e18 - withdrawFee, 1e18, Math.Rounding.Floor);
            }
        }
    }

    /// @notice Calculates the maximum number of shares the owner can redeem
    /// @dev IL-9679 (Olympix 2026-11-06 L48): 0 while the owner's redemption lock is active, because redeem reverts
    ///      then (ERC-4626: maxRedeem is 0 when redemption is disabled for the owner); otherwise the owner's balance,
    ///      capped by the released-request reserve when request shares are released (IL-9624 follow-up, below). The
    ///      lock is read from the vault's access manager the way `RedemptionDelayLib.lockChecks` enforces it on
    ///      withdraw and redeem: unlock time (last deposit or mint plus the current redemption delay) after
    ///      block.timestamp, and the owner not exempt from the delay. redeem and redeemFromRequest cap the shares by
    ///      `balanceOf(owner_)`, not by this view: redeem has already enforced the lock in `_checkCanCall`, and
    ///      redeemFromRequest is lock-free by design
    /// @dev Reflects the owner's own lock, a closed vault and the released-request reserve. Not reflected (IL-9680,
    ///      owner decision IL-8639): the lock of the caller (IL-9705: `_checkCanCall` reads the lock of the owner of
    ///      the shares only, the caller passes the role check), access roles and pre-hooks such as the crosschain
    ///      NAV gate; probe access with `canCall` on the access manager
    /// @dev IL-9624 follow-up, closed vault: 0 while `isTargetClosed(vault)` is true on the vault's access manager
    ///      (set by GUARDIAN with `updateTargetClosed`). The access manager checks the closed flag before the role,
    ///      so it rejects every `restricted` call of the vault, redeem and redeemFromRequest among them, for every
    ///      caller; getters and views keep working. Reopening restores the value at once
    /// @dev IL-9624 follow-up, released-request reserve: with released request shares R > 0
    ///      (`WithdrawManager.getSharesToRelease`, the global pool ALPHA released, not the owner's request and not
    ///      the sum of pending requests) the result is min(balanceOf(owner), max(C - R, 0)), where C is all gross
    ///      assets in shares on the supply after both pending fees (`_unreservedShares`). The cap binds only an owner
    ///      whose balance exceeds max(C - R, 0): typically a requester exiting at once next to its own released
    ///      request, or a holder after ALPHA released more shares than the other holders own. Such an owner exits
    ///      with redeemFromRequest for the released part and redeem(maxRedeem(owner)), while
    ///      redeem(balanceOf(owner)) reverts with WithdrawManagerInvalidSharesToRelease. An upper bound, not a
    ///      guarantee: the cap counts every gross asset as available and does not reflect the liquidity of the
    ///      markets, the RewardsClaimManager balance or a refresh of stale market balances in the exit (IL-8489).
    ///      redeem and redeemFromRequest get no new check: they still cap by the balance, and the WithdrawManager
    ///      enforces the reserve as before
    /// @dev Reads, after the closed flag and the owner's lock (each ends the view with 0): `getSharesToRelease`, also
    ///      when R = 0. With R = 0 or without a WithdrawManager the result is the balance, with no valuation. With
    ///      R > 0 the view makes one valuation with the pending fees, so it then depends on the asset valuation and
    ///      on the FeeManager of the same release (`pendingPerformanceFeeShares`), and like maxWithdraw it can show a
    ///      transient value inside execute and an instant withdrawal (IL-9743). A reader with a gas limit has to
    ///      allow for that cost: the crosschain vault-removal sweep reads this view with 200,000 gas and takes a
    ///      failed read as no limit. When the outer gas cannot fund that read the sweep reverts with
    ///      InsufficientGasForVaultRead instead; only a failed or out-of-gas capped read falls back to the whole
    ///      balance, which reverts for a position capped by the reserve
    /// @dev Under the reserve redeem(maxRedeem(owner)) must run AFTER redeemFromRequest for the owner's released
    ///      request: the instant redeem shrinks the owner's request cap (`getRequestCap`) and leaves part of R
    ///      reserved for nobody until ALPHA releases again. The parent's Erc4626SupplyFuse full exit and the
    ///      crosschain sweep redeem min(balanceOf, maxRedeem) with an ordinary redeem, so they take the instant path
    /// @param owner_ The address to calculate max redemption for
    /// @return uint256 Maximum number of shares that can be redeemed
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (_isVaultClosed() || _isRedemptionLocked(owner_)) {
            return 0;
        }
        uint256 ownerShares = balanceOf(owner_);
        uint256 sharesToRelease = _sharesToRelease();
        if (sharesToRelease == 0) {
            return ownerShares;
        }
        (uint256 supply, uint256 grossTotalAssets) = _supplyWithPendingFeesAndGrossAssets();
        return Math.min(ownerShares, _unreservedShares(sharesToRelease, supply, grossTotalAssets));
    }

    /// @notice True while the vault is closed in its access manager (`updateTargetClosed`, GUARDIAN)
    /// @dev IL-9624 follow-up: the access manager checks the closed flag before the role, so while it is set every
    ///      `restricted` call of the vault reverts for every caller and the four max views return 0
    /// @return True when `isTargetClosed(address(this))` is true on the vault's access manager
    function _isVaultClosed() private view returns (bool) {
        return IporFusionAccessManager(authority()).isTargetClosed(address(this));
    }

    /// @notice Released request shares R: the global pool that ALPHA released on the WithdrawManager
    /// @dev IL-9624 follow-up: not the owner's request and not the sum of pending requests. maxWithdraw and maxRedeem
    ///      read it only after the closed flag and the owner's lock
    /// @return R, or 0 without a WithdrawManager
    function _sharesToRelease() private view returns (uint256) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;
        return withdrawManager == address(0) ? 0 : WithdrawManager(withdrawManager).getSharesToRelease();
    }

    /// @notice Gross shares that one withdraw or redeem can burn next to the released request shares: max(C - R, 0)
    /// @dev IL-9624 follow-up. Mirrors `WithdrawManager.canWithdrawFromUnallocated`, which reverts with
    ///      WithdrawManagerInvalidSharesToRelease when R > 0 and the vault's idle assets in shares are below R plus
    ///      the gross shares of the exit. C is all gross assets G in shares on the supply after both pending fees,
    ///      floor(G * (supply + scale) / (G + 1)): the supply that the check sees after the exit crystallizes the
    ///      fees. It is neither totalSupply() - R nor convertToShares(totalAssets()), which leaves out the pending
    ///      performance fee. The subtraction saturates at 0
    /// @dev No valuation of its own: the caller passes the supply and gross assets it computed once with
    ///      `_supplyWithPendingFeesAndGrossAssets`, so maxWithdraw uses one pair for this cap and for its conversion
    /// @dev An upper bound, not a guarantee: it counts every gross asset as available. Not reflected: the liquidity
    ///      of the markets, the RewardsClaimManager balance (counted in totalAssets() but not pulled by the exit,
    ///      while the check reads only the vault's token balance) and a refresh of stale market balances in the exit
    ///      (IL-8489)
    /// @param sharesToRelease_ Released request shares R (`_sharesToRelease`)
    /// @param supply_ Share supply after both pending fees (management fee and performance fee shares)
    /// @param grossTotalAssets_ Gross total assets G, computed once by the caller
    /// @return Shares an exit can burn, before the owner's balance is applied; type(uint256).max when R = 0, where
    ///         the check does not apply
    function _unreservedShares(
        uint256 sharesToRelease_,
        uint256 supply_,
        uint256 grossTotalAssets_
    ) private view returns (uint256) {
        if (sharesToRelease_ == 0) {
            return type(uint256).max;
        }
        uint256 vaultShares = _convertToSharesWithSupply(
            grossTotalAssets_,
            supply_,
            grossTotalAssets_,
            Math.Rounding.Floor
        );
        return vaultShares > sharesToRelease_ ? vaultShares - sharesToRelease_ : 0;
    }

    /// @notice True while the owner cannot withdraw or redeem because of its redemption lock (IL-9679)
    /// @dev The test of `RedemptionDelayLib.lockChecks` on the exit selectors, read from the vault's access
    ///      manager; the exemption set is read only when the account is otherwise locked
    /// @param owner_ The share owner
    /// @return True when the lock of `owner_` is active and `owner_` is not exempt from the redemption delay
    function _isRedemptionLocked(address owner_) private view returns (bool) {
        IporFusionAccessManager accessManager = IporFusionAccessManager(authority());
        return
            accessManager.getAccountLockTime(owner_) > block.timestamp &&
            !accessManager.isRedemptionDelayExempt(owner_);
    }

    /// @notice Claims rewards from integrated protocols through fuse contracts
    /// @dev Executes reward claiming operations via delegatecall to fuses
    ///
    /// Claiming Flow:
    /// 1. Pre-claim Validation
    ///    - Validates fuse actions
    ///    - Checks permissions
    ///    - Prepares claim context
    ///
    /// 2. Reward Processing
    ///    - Executes claim operations
    ///    - Handles protocol interactions
    ///    - Processes reward tokens
    ///    - Updates reward balances
    ///
    /// Security Features:
    /// - Reentrancy protection
    /// - Role-based access
    /// - Delegatecall safety
    /// - Protocol validation
    ///
    /// @param calls_ Array of FuseAction structs defining reward claim operations
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access Restricted to TECH_REWARDS_CLAIM_MANAGER_ROLE (managed by TECH_REWARDS_CLAIM_MANAGER_ROLE)
    function claimRewards(FuseAction[] calldata calls_) external override nonReentrant restricted {
        uint256 callsCount = calls_.length;
        for (uint256 i; i < callsCount; ++i) {
            calls_[i].fuse.functionDelegateCall(calls_[i].data);
        }
    }

    /// @notice Returns the total assets in the vault
    /// @dev ERC4626 compliant - returns gross total assets inclusive of all fees
    ///
    /// Calculation Flow:
    /// 1. Gross Assets
    ///    - Retrieves vault balance
    ///    - Adds market positions
    ///    - Includes pending operations
    ///
    /// ERC4626 Compliance:
    /// - Returns gross assets as per ERC4626 spec requirement that totalAssets
    ///   "MUST be inclusive of any fees that are charged against assets in the Vault"
    /// - The accrued management fee is priced on the supply side instead: the conversions (convertTo*,
    ///   preview*, max*) count the virtual fee shares that a realization would mint now (IL-8870)
    ///
    /// Important Notes:
    /// - Excludes runtime accrued market interest
    /// - Excludes runtime accrued performance fees
    /// - Does NOT deduct unrealized management fees (ERC4626 compliant); read the share price through
    ///   convertToAssets, totalAssets() / totalSupply() is net of the fee only right after a realization
    /// - Has no execution gate inside the execute batch or an instant withdrawal of this vault: until the final balance
    ///   refresh it can show too little or too much for underlying that has moved and is not yet booked, and the
    ///   conversions, previews and limits built on the same sum are affected too (IL-9631, IL-9743); see
    ///   "Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)" in contracts/vaults/README.md
    ///
    /// @return uint256 Gross total assets in underlying token decimals
    /// @custom:access Public view function, no role restrictions
    function totalAssets() public view virtual override returns (uint256) {
        return _getGrossTotalAssets();
    }

    /// @notice Returns the total assets in the vault for a specific market
    /// @dev Provides market-specific asset tracking without considering fees
    ///
    /// Balance Tracking:
    /// 1. Market Assets
    ///    - Protocol-specific positions
    ///    - Deposited collateral
    ///    - Earned yields
    ///    - Pending operations
    ///
    /// Integration Context:
    /// - Used by balance fuses
    /// - Market limit validation
    /// - Asset distribution checks
    /// - Withdrawal calculations
    ///
    /// Important Notes:
    /// - Raw balance without fees
    /// - Updated by balance fuses
    /// - Market-specific tracking
    /// - Critical for distribution
    ///
    /// @param marketId_ Identifier of the market to query
    /// @return uint256 Total assets in the market in underlying token decimals
    /// @custom:access Public view function, no role restrictions
    function totalAssetsInMarket(uint256 marketId_) public view virtual returns (uint256) {
        return PlasmaVaultLib.getTotalAssetsInMarket(marketId_);
    }

    /// @notice Returns the current unrealized management fee
    /// @dev Calculates accrued management fees since last fee realization
    ///
    /// Calculation Flow:
    /// 1. Fee Computation
    ///    - Gets gross total assets
    ///    - Retrieves fee configuration
    ///    - Calculates time-based accrual
    ///    - Applies fee percentage
    ///
    /// Fee Components:
    /// - Time elapsed since last update
    /// - Current total assets
    /// - Management fee rate
    /// - Fee recipient settings
    ///
    /// Important Notes:
    /// - Pro-rata time calculation
    /// - Based on current assets
    /// - Unrealized until claimed
    /// - Affects total assets
    ///
    /// @return uint256 Unrealized management fee in underlying token decimals
    /// @custom:access Public view function, no role restrictions
    function getUnrealizedManagementFee() public view returns (uint256) {
        return PlasmaVaultFeesLib.getUnrealizedManagementFee(_getGrossTotalAssets());
    }

    /// @notice Reserved function for PlasmaVaultBase delegatecall operations
    /// @dev Prevents direct calls to updateInternal, only accessible via delegatecall
    ///
    /// Security Features:
    /// - Blocks direct execution
    /// - Preserves upgrade safety
    /// - Maintains access control
    /// - Protects vault integrity
    ///
    /// Error Handling:
    /// - Reverts with UnsupportedMethod
    /// - Prevents unauthorized updates
    /// - Guards against direct calls
    /// - Maintains security model
    ///
    /// @custom:access Internal function, reverts on direct calls
    function updateInternal(address, address, uint256) public {
        revert UnsupportedMethod();
    }

    /// @notice Internal execution function for delegated protocol interactions
    /// @dev Handles fuse actions without performance fee calculations
    ///
    /// Execution Flow:
    /// 1. Caller Validation
    ///    - Verifies self-call only
    ///    - Prevents external access
    ///    - Maintains security model
    ///
    /// 2. Action Processing
    ///    - Validates fuse support
    ///    - Tracks affected markets
    ///    - Executes protocol actions
    ///    - Updates the market balance caches of the touched markets without checking market limits: the NAV
    ///      still holds any borrowed tokens, so a limit check here would measure against a NAV that is gone after
    ///      repayment (IL-9708)
    ///    - Records the touched markets in transient storage; execute refreshes and limit-checks them after the
    ///      callbacks returned, against the NAV after repayment (IL-9404)
    ///
    /// Security Features:
    /// - Self-call restriction
    /// - Fuse validation
    /// - Market tracking
    /// - Balance updates
    ///
    /// @param calls_ Array of FuseAction structs defining protocol interactions
    /// @custom:access Internal function, self-call only
    function executeInternal(FuseAction[] calldata calls_) external {
        if (address(this) != msg.sender) {
            revert Errors.WrongCaller(msg.sender);
        }
        uint256 callsCount = calls_.length;
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex;
        uint256 fuseMarketId;

        for (uint256 i; i < callsCount; ++i) {
            if (!FusesLib.isFuseSupported(calls_[i].fuse)) {
                revert UnsupportedFuse();
            }

            fuseMarketId = IFuseCommon(calls_[i].fuse).MARKET_ID();

            if (_checkIfExistsMarket(markets, fuseMarketId) == false) {
                markets[marketIndex] = fuseMarketId;
                marketIndex++;
            }

            calls_[i].fuse.functionDelegateCall(calls_[i].data);
        }
        _updateMarketsBalances(markets, false);
        PlasmaVaultMarketsLib.recordCallbackMarkets(markets);
    }

    /// @notice Entry for RealizeManagementFeeFuse: realizes the accrued management fee from inside execute
    /// @dev IL-8870 (Pete D-003): the fuse runs by delegatecall inside execute and self-calls this entry. It cannot
    ///      call realizeManagementFee: execute already holds the reentrancy guard, and a vault self-call is
    ///      authorized as the vault, which has no ALPHA_ROLE. Accepted only from the vault itself while execute is
    ///      running, otherwise reverts with WrongCaller. Runs the same `_realizeManagementFee` as
    ///      realizeManagementFee and the deposit/withdraw flows. Not part of IPlasmaVault, like executeInternal.
    /// @dev Gross total assets come from the stored market balances, which execute refreshes only after the last
    ///      action. RealizeManagementFeeFuse must therefore be the only action of its own top-level execute (IL-8870
    ///      D-025, D-026): nothing before it, nothing after it, never inside a callback batch. An action before it
    ///      prices the fee on stale balances (over-mint with a pending fee, or the fee is dropped at zero gross
    ///      assets); an action after it reprices the pending fee and can change the performance fee. The vault does
    ///      not enforce this.
    /// @return uint256 Management fee shares minted, 0 when nothing was minted
    /// @custom:access Vault self-call during execute only
    function realizeManagementFeeInternal() external returns (uint256) {
        if (address(this) != msg.sender || !PlasmaVaultLib.isExecutionStarted()) {
            revert Errors.WrongCaller(msg.sender);
        }
        return _realizeManagementFee();
    }

    function _redeem(
        uint256 shares_,
        address receiver_,
        address owner_,
        bool withFee_
    ) internal returns (uint256 withdrawnAssets) {
        if (shares_ == 0) {
            revert NoSharesToRedeem();
        }

        if (receiver_ == address(0) || owner_ == address(0)) {
            revert Errors.WrongAddress();
        }

        /// @dev first realize management fee, then other actions
        _realizeManagementFee();

        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        {
            uint256 sharesToRelease = WithdrawManager(withdrawManager).getSharesToRelease();

            /// @dev The released-shares reserve is priced again in every attempt: the refresh of the touched markets
            ///      books their unrecorded yield and raises the share price (IL-9437)
            uint256 previousIdleAssets;
            for (uint256 i; i < REDEEM_ATTEMPTS; ++i) {
                uint256 idleAssets = IERC20(asset()).balanceOf(address(this));
                /// @dev A round that added no idle assets means the markets cannot supply more in this block (IL-9719)
                if (i != 0 && idleAssets <= previousIdleAssets) {
                    break;
                }
                previousIdleAssets = idleAssets;
                _withdrawFromMarkets(
                    _includeSlippage(convertToAssets(shares_)) +
                        (sharesToRelease == 0 ? 0 : convertToAssets(sharesToRelease)),
                    idleAssets
                );
            }
        }

        _addPerformanceFee();

        address caller = _msgSender();

        if (!withFee_) {
            withdrawnAssets = convertToAssets(shares_);
            _withdraw(caller, receiver_, owner_, withdrawnAssets, shares_);
        } else {
            uint256 feeSharesToBurn = WithdrawManager(withdrawManager).canWithdrawFromUnallocated(shares_);
            withdrawnAssets = convertToAssets(shares_ - feeSharesToBurn);

            if (caller != owner_) {
                _spendAllowance(owner_, caller, shares_);
            }

            _burn(owner_, shares_);

            SafeERC20.safeTransfer(IERC20(asset()), receiver_, withdrawnAssets);

            emit Withdraw(caller, receiver_, owner_, withdrawnAssets, shares_);
        }
    }

    /// @notice The share scale multiplier for ERC4626 operations
    /// @dev Retrieved from storage library
    function _SHARE_SCALE_MULTIPLIER() internal view returns (uint256) {
        return PlasmaVaultStorageLib.getShareScaleMultiplier();
    }

    /// @notice Private method containing the common initialization logic
    /// @param initData_ Initialization parameters encapsulated in PlasmaVaultInitData struct
    /// @dev Common initialization logic of `proxyInitialize`
    function _initializeVault(PlasmaVaultInitData memory initData_) private {
        super.__ERC20_init(initData_.assetName, initData_.assetSymbol);
        super.__ERC4626_init(IERC20(initData_.underlyingToken));

        PlasmaVaultStorageLib.setShareScaleMultiplier(10 ** _decimalsOffset());
        PlasmaVaultStorageLib.setPlasmaVaultBase(initData_.plasmaVaultBase);
        if (initData_.plasmaVaultVotesPlugin != address(0)) {
            PlasmaVaultStorageLib.setPlasmaVaultVotesPlugin(initData_.plasmaVaultVotesPlugin);
        }

        initData_.plasmaVaultBase.functionDelegateCall(
            abi.encodeWithSelector(
                IPlasmaVaultBase.init.selector,
                initData_.assetName,
                initData_.accessManager,
                type(uint256).max /// @dev default total supply cap is max uint256
            )
        );

        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(initData_.priceOracleMiddleware);

        if (priceOracleMiddleware.QUOTE_CURRENCY() != USD) {
            revert Errors.UnsupportedQuoteCurrencyFromOracle();
        }

        PlasmaVaultLib.setPriceOracleMiddleware(initData_.priceOracleMiddleware);

        /// @dev Deploys the FeeManager, checks its rate scale (IL-9601, D-068) and stores the fee accounts and rates;
        ///      linked library call (DELEGATECALL, runs in the vault's context), kept out of the vault for EIP-170
        PlasmaVaultFeesLib.createFeeManager(initData_.feeConfig, initData_.accessManager);

        PlasmaVaultLib.updateManagementFeeData();
        if (initData_.withdrawManager == address(0)) {
            revert WithdrawManagerNotSet();
        }
        PlasmaVaultLib.updateWithdrawManager(initData_.withdrawManager);
    }

    function _deposit(uint256 assets_, address receiver_) internal returns (uint256) {
        if (assets_ == 0) {
            revert NoAssetsToDeposit();
        }
        if (receiver_ == address(0)) {
            revert Errors.WrongAddress();
        }

        _realizeManagementFee();

        uint256 sharesGross = super.convertToShares(assets_);
        uint256 shares = super.deposit(assets_, receiver_);

        if (shares == 0) {
            revert NoSharesToDeposit();
        }

        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager != address(0) && sharesGross > shares) {
            super._mint(withdrawManager, sharesGross - shares);
        }
        return shares;
    }

    /// @notice Mints the performance fee owed at the current net share price
    /// @dev The fee is charged whenever the share price is above the high-water mark, also in a call that lowered
    ///      the assets (market exit cost, revealed loss, rounding) - the high-water mark in FeeManager already
    ///      prevents a fee without a gain (IL-9403). With a non-zero HWM update interval the mark may therefore be
    ///      lowered to the current price in a call that lost value.
    /// @dev IL-8870 (option A, DA-5): the rate is the net share price, priced with the virtual management fee
    ///      shares, and the supply passed to FeeManager includes them (S + V). FeeManager sets the high-water mark
    ///      to (totalAssets + 1) / (passed supply + performance fee shares + scale); with the minted supply it would
    ///      sit above the net price by the accrued management fee and block later performance fees. Of the fee
    ///      shares p that FeeManager returns, the vault mints the part that falls on the minted supply (see the
    ///      body), so that high-water mark is the net price after the performance fee mint.
    /// @dev IL-9601 (Olympix M11): the rate is assets per 10 ** decimals() shares times
    ///      FeeManager.HIGH_WATER_MARK_SCALE (1e12), one mulDiv of the same terms as the net price
    ///      (`PlasmaVaultFeesLib.performanceFeeRateShares`), and the FeeManager stores the high-water mark in that
    ///      unit. An integer asset unit per share floored the post-fee mark by up to 1 ppm of the price on 6-decimal
    ///      assets and charged that fraction again at every crossing. The new PlasmaVault and the new FeeManager are a
    ///      pair: either one with the other's old build compares rates that differ by 1e12.
    /// @dev Invariant: within one call, whether a performance fee is charged, the high-water mark it sets, the net
    ///      share price after it and with it the value the shareholders keep do not depend on whether the management
    ///      fee was realized in that call (IL-8870, Codex review #2). A realization mints V and leaves the gross
    ///      assets unchanged, so S + V and the net rate are the same with and without it when the realization saw
    ///      the gross assets this call ends with. The number of shares minted does depend on it: after a
    ///      realization V is minted supply and takes its part of the dilution, so all of p is minted; while the fee
    ///      is only accrued, V stays worth the accrued fee and the part of p that falls on V is not minted. The
    ///      invariant holds under the D-026 condition: the fuse runs alone in its own top-level execute. If an
    ///      action after the fuse in the same execute revalues a market, the realized fee was priced on the earlier
    ///      gross assets, so S + V differs from the run without the fuse by that re-pricing.
    function _addPerformanceFee() internal {
        (uint256 supply, uint256 grossTotalAssets) = _supplyWithManagementFeeAndGrossAssets();

        uint256 actualExchangeRate = _convertToAssetsWithSupply(
            PlasmaVaultFeesLib.performanceFeeRateShares(decimals()),
            supply,
            grossTotalAssets,
            Math.Rounding.Floor
        );

        /// @dev FeeManager stores the high-water mark as uint128; above that bound skip the performance fee
        /// instead of reverting, otherwise a donation into a dust-supply vault would block withdraw/redeem/execute.
        /// With the 1e12 scale (IL-9601) the bound is a share price of about 3.4e26 / 10 ** assetDecimals assets
        /// (3.4e20 at 6 decimals, 3.4e8 at 18 decimals)
        if (actualExchangeRate > type(uint128).max) {
            return;
        }

        (address recipient, uint256 feeShares) = PlasmaVaultFeesLib.prepareForAddPerformanceFee(
            supply,
            decimals(),
            _decimalsOffset(),
            actualExchangeRate
        );

        if (recipient == address(0) || feeShares == 0) {
            return;
        }

        /// @dev IL-8870: FeeManager sized the fee shares p and the high-water mark on the supply S + V. The virtual
        ///      shares are priced again after this mint so that they stay worth the accrued management fee: V grows
        ///      with the minted supply, which would add the dilution p * V / (S + V) on top of p, paid by the
        ///      shareholders alone, and leave the net price below the stored high-water mark. So only the part of p
        ///      that falls on the minted supply is minted, rounded up: m = p * (S + scale) / (S + V + scale). The
        ///      supply that prices the vault after the mint, S + m + V' + scale, is then the denominator of the
        ///      high-water mark, S + V + p + scale (never below it, at most 2 share units above it): the net price
        ///      after the mint, rounded down, is never above the high-water mark and at most the value of 2 share
        ///      units below it (in the HIGH_WATER_MARK_SCALE unit that can be more than one unit, IL-9601).
        uint256 mintedSupply = totalSupply();
        if (mintedSupply != supply) {
            uint256 shareScale = _SHARE_SCALE_MULTIPLIER();
            feeShares = feeShares.mulDiv(mintedSupply + shareScale, supply + shareScale, Math.Rounding.Ceil);
        }

        /// @dev total supply cap validation is disabled for fee minting
        PlasmaVaultLib.setTotalSupplyCapValidation(1);

        _mint(recipient, feeShares);

        /// @dev total supply cap validation is enabled when fee minting is finished
        PlasmaVaultLib.setTotalSupplyCapValidation(0);
    }

    /// @notice Realizes management fees by minting shares to fee recipient
    /// @dev The fee clock advances on every realization. A fee that rounds to zero shares is kept
    ///      in the pending management fee and minted later, so small/frequent operations cannot
    ///      suppress it (IL-6959), while a stale clock can never price a dormant period on assets
    ///      deposited later (IL-8318). With no assets or no shares there is nobody to charge,
    ///      so the accrual is dropped.
    /// @dev IL-8870 (D-002): mints exactly the virtual fee shares that the views price,
    ///      `managementFeeShares(F, S, G, scale)` on the supply and gross assets before the mint, so the share
    ///      price is the same before and after the realization and no preview is better than its result.
    ///      Reached from deposit, mint, withdraw, redeem, realizeManagementFee and realizeManagementFeeInternal,
    ///      never from execute or updateMarketsBalances (Pete D-003).
    /// @return feeShares Management fee shares minted, 0 when nothing was minted
    function _realizeManagementFee() internal returns (uint256 feeShares) {
        uint256 grossTotalAssets = _getGrossTotalAssets();
        uint256 supply = totalSupply();

        /// @dev Empty vault (or dust without shareholders): drop the accrual and restart the clock
        if (grossTotalAssets == 0 || supply == 0) {
            PlasmaVaultStorageLib.setPendingManagementFee(0);
            PlasmaVaultLib.updateManagementFeeData();
            return 0;
        }

        (address recipient, uint256 unrealizedFeeInUnderlying) = PlasmaVaultFeesLib.prepareForRealizeManagementFee(
            grossTotalAssets
        );

        feeShares = PlasmaVaultFeesLib.managementFeeShares(
            unrealizedFeeInUnderlying,
            supply,
            grossTotalAssets,
            _SHARE_SCALE_MULTIPLIER()
        );

        PlasmaVaultLib.updateManagementFeeData();

        /// @dev Without a fee account the fee is zero, so zero shares also covers recipient == address(0)
        if (feeShares == 0) {
            /// @dev Keep the fee that rounded to zero shares for a later realization
            PlasmaVaultStorageLib.setPendingManagementFee(unrealizedFeeInUnderlying);
            return 0;
        }

        PlasmaVaultStorageLib.setPendingManagementFee(0);

        /// @dev minting is an act of management fee realization
        /// @dev total supply cap validation is disabled for fee minting
        PlasmaVaultLib.setTotalSupplyCapValidation(1);

        _mint(recipient, feeShares);

        /// @dev total supply cap validation is enabled when fee minting is finished
        PlasmaVaultLib.setTotalSupplyCapValidation(0);

        emit ManagementFeeRealized(unrealizedFeeInUnderlying, feeShares);
    }

    function _includeSlippage(uint256 value_) internal pure returns (uint256) {
        /// @dev increase value by DEFAULT_SLIPPAGE_IN_PERCENTAGE to cover potential slippage
        return value_ + IporMath.division(value_ * DEFAULT_SLIPPAGE_IN_PERCENTAGE, 100);
    }

    /// @notice Withdraw assets from the markets
    /// @param assets_ Amount of assets to withdraw
    /// @param vaultCurrentBalanceUnderlying_ Current balance of the vault in underlying token
    function _withdrawFromMarkets(uint256 assets_, uint256 vaultCurrentBalanceUnderlying_) internal {
        if (assets_ == 0) {
            return;
        }

        if (assets_ >= vaultCurrentBalanceUnderlying_) {
            uint256[] memory markets = PlasmaVaultMarketsLib.withdrawFromMarkets(
                asset(),
                assets_,
                vaultCurrentBalanceUnderlying_
            );

            /// @dev IL-9694 D-003: a pull for a withdrawal does not check market limits, so a user can exit through a
            ///      market that sits above its limit; the limit is an allocation rule enforced by execute
            _updateMarketsBalances(markets, false);
        }
    }

    /// @notice Update balances in the vault for markets touched by the fuses during the execution of all FuseActions
    /// @param markets_ Array of market ids touched by the fuses in the FuseActions
    /// @param checkLimits_ True to check the market limits of the refreshed markets against the gross NAV (execute
    ///        only); false for executeInternal (the limits of its markets are checked in execute after repayment,
    ///        IL-9708), for updateMarketsBalances, which only stores the balances (IL-9612), and for the market pulls
    ///        of withdraw and redeem (IL-9694 D-003)
    function _updateMarketsBalances(uint256[] memory markets_, bool checkLimits_) internal {
        DataToCheck memory dataToCheck = PlasmaVaultMarketsLib.updateMarketsBalances(
            markets_,
            asset(),
            decimals(),
            _decimalsOffset()
        );

        if (checkLimits_) {
            dataToCheck.totalBalanceInVault = _getGrossTotalAssets();

            AssetDistributionProtectionLib.checkLimits(dataToCheck);
        }
    }

    function _checkIfExistsMarket(uint256[] memory markets_, uint256 marketId_) internal pure returns (bool exists) {
        for (uint256 i; i < markets_.length; ++i) {
            if (markets_[i] == 0) {
                break;
            }
            if (markets_[i] == marketId_) {
                exists = true;
                break;
            }
        }
    }

    function _getGrossTotalAssets() internal view returns (uint256) {
        address rewardsClaimManagerAddress = PlasmaVaultLib.getRewardsClaimManagerAddress();

        if (rewardsClaimManagerAddress != address(0)) {
            return
                IERC20(asset()).balanceOf(address(this)) +
                PlasmaVaultLib.getTotalAssetsInAllMarkets() +
                IRewardsClaimManager(rewardsClaimManagerAddress).balanceOf();
        }
        return IERC20(asset()).balanceOf(address(this)) + PlasmaVaultLib.getTotalAssetsInAllMarkets();
    }

    /**
     * @dev Reverts if the caller is not allowed to call the function identified by a selector. Panics if the calldata
     * is less than 4 bytes long.
     */
    function _checkCanCall(address caller_, bytes calldata data_) internal virtual override {
        /// @dev The vault's own external self-calls (e.g. UpdateBalancesPreHook -> updateMarketsBalances) are
        ///      authorized against the vault, not against a ContextManager context sender.
        if (msg.sender == address(this)) {
            caller_ = msg.sender;
        }

        bytes4 sig = bytes4(data_[0:4]);
        bool immediate;
        uint32 delay;

        if (this.transferFrom.selector == sig) {
            (address tranferFromAddress, , ) = abi.decode(_msgData()[4:], (address, address, uint256));

            /// @dev apply the redemption-lock check to the owner of shares (`from`); the access result is intentionally
            ///      ignored (IL-8796) - only the caller's access is enforced
            IporFusionAccessManager(authority()).canCallAndUpdate(tranferFromAddress, address(this), sig);

            /// @dev IL-9705 (Pete D-004): the caller passes only the role check, like in the deposit branch; the
            ///      redemption lock is read for the owner of the shares (`from`) above, so a third party cannot lock an
            ///      operator out by depositing to it
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        } else if (this.deposit.selector == sig || this.mint.selector == sig) {
            (, address receiver) = abi.decode(_msgData()[4:], (uint256, address));

            /// @dev start the redemption lock of the receiver of shares; the access result is intentionally ignored
            ///      (IL-8796) - only the caller's access is enforced
            IporFusionAccessManager(authority()).canCallAndUpdate(receiver, address(this), sig);
            /// @dev check that the caller has access to deposit or mint (no lock is set for the caller on this path)
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        } else if (this.depositWithPermit.selector == sig) {
            (, address receiver, , , , ) = abi.decode(
                _msgData()[4:],
                (uint256, address, uint256, uint8, bytes32, bytes32)
            );

            /// @dev start the redemption lock of the receiver of shares (depositWithPermit); the access result is intentionally ignored
            ///      (IL-8796) - only the caller's access is enforced
            IporFusionAccessManager(authority()).canCallAndUpdate(receiver, address(this), sig);
            /// @dev check that the caller has access to depositWithPermit (no lock is set for the caller on this path)
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        } else if (this.redeem.selector == sig || this.withdraw.selector == sig) {
            (, , address owner) = abi.decode(_msgData()[4:], (uint256, address, address));

            /// @dev apply the redemption-lock check to the owner of shares; the access result is intentionally ignored
            ///      (IL-8796) - only the caller's access is enforced
            IporFusionAccessManager(authority()).canCallAndUpdate(owner, address(this), sig);

            /// @dev IL-9705 (Pete D-004): the caller passes only the role check (the lock is the owner's, read above)
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        } else if (this.transfer.selector == sig) {
            (immediate, delay) = IporFusionAccessManager(authority()).canCallAndUpdate(caller_, address(this), sig);
        } else {
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        }

        if (!immediate) {
            if (delay > 0) {
                AccessManagedStorage storage $ = _getAccessManagedStorage();
                $._consumingSchedule = true;
                IAccessManager(authority()).consumeScheduledOp(caller_, data_);
                $._consumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller_);
            }
        }

        _runPreHook(sig);
    }

    function _msgSender() internal view override returns (address) {
        return ContextClientStorageLib.getSenderFromContext();
    }

    function _update(address from_, address to_, uint256 value_) internal virtual override {
        PLASMA_VAULT_BASE().functionDelegateCall(
            abi.encodeWithSelector(IPlasmaVaultBase.updateInternal.selector, from_, to_, value_)
        );
    }

    function _decimalsOffset() internal view virtual override returns (uint8) {
        return PlasmaVaultLib.DECIMALS_OFFSET;
    }

    /// @dev Priced net of the accrued management fee: the supply includes the virtual fee shares, totalAssets
    ///      stays gross (IL-8870). Every conversion, preview and max view goes through here or through
    ///      `_convertToAssetsWithSupply` with the same supply and gross assets.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual override returns (uint256) {
        (uint256 supply, uint256 grossTotalAssets) = _supplyWithManagementFeeAndGrossAssets();
        return _convertToSharesWithSupply(assets, supply, grossTotalAssets, rounding);
    }

    /// @dev Priced net of the accrued management fee, like `_convertToShares` (IL-8870)
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual override returns (uint256) {
        (uint256 supply, uint256 grossTotalAssets) = _supplyWithManagementFeeAndGrossAssets();
        return _convertToAssetsWithSupply(shares, supply, grossTotalAssets, rounding);
    }

    /// @notice Converts assets to shares at the given supply and gross total assets
    /// @param assets_ Amount of underlying assets
    /// @param supply_ Share supply including the virtual management fee shares
    /// @param grossTotalAssets_ Gross total assets, computed once by the caller (IL-8870)
    /// @param rounding_ Rounding direction
    /// @return Shares worth `assets_`
    function _convertToSharesWithSupply(
        uint256 assets_,
        uint256 supply_,
        uint256 grossTotalAssets_,
        Math.Rounding rounding_
    ) private view returns (uint256) {
        return
            supply_ == 0
                ? assets_ * _SHARE_SCALE_MULTIPLIER()
                : assets_.mulDiv(supply_ + _SHARE_SCALE_MULTIPLIER(), grossTotalAssets_ + 1, rounding_);
    }

    /// @notice Converts shares to assets at the given supply and gross total assets
    /// @param shares_ Amount of vault shares
    /// @param supply_ Share supply including the virtual management fee shares
    /// @param grossTotalAssets_ Gross total assets, computed once by the caller (IL-8870)
    /// @param rounding_ Rounding direction
    /// @return Assets worth `shares_`
    function _convertToAssetsWithSupply(
        uint256 shares_,
        uint256 supply_,
        uint256 grossTotalAssets_,
        Math.Rounding rounding_
    ) private view returns (uint256) {
        return
            supply_ == 0
                ? shares_.mulDiv(1, _SHARE_SCALE_MULTIPLIER(), rounding_)
                : shares_.mulDiv(grossTotalAssets_ + 1, supply_ + _SHARE_SCALE_MULTIPLIER(), rounding_);
    }

    /// @notice Share supply including the virtual management fee shares, and the gross total assets
    /// @dev IL-8870 (option A, MetaMorpho pattern): the accrued management fee F is priced on the supply side as
    ///      the shares V that `_realizeManagementFee` would mint now (`PlasmaVaultFeesLib.managementFeeShares`,
    ///      D-002), while totalAssets() stays gross (ERC-4626, #475). The price (G + 1) / (S + V + scale) is the
    ///      same before and after the realization. Gross total assets are computed once here and passed to the
    ///      conversion. Replaces `_totalSupplyAfterManagementFee`, which only the max/preview views of IL-8319,
    ///      IL-8343 and IL-8490 used.
    /// @dev Gas (IL-8870, Pete D-023): the fee library reads the ManagementFeeData slot once. Fast path: when F is
    ///      zero (no pending fee and no time accrued: fee clock at the current block, which holds for every
    ///      conversion after the realization in deposit, mint, withdraw and redeem; zero rate; no fee account), the
    ///      supply is totalSupply() without the share scale read or the fee share math. This is the same result,
    ///      because `managementFeeShares` returns 0 for a zero fee.
    /// @return supply totalSupply() plus the virtual management fee shares V
    /// @return grossTotalAssets Gross total assets G
    function _supplyWithManagementFeeAndGrossAssets() private view returns (uint256 supply, uint256 grossTotalAssets) {
        grossTotalAssets = _getGrossTotalAssets();
        supply = totalSupply();
        (, uint256 fee) = PlasmaVaultFeesLib.prepareForRealizeManagementFee(grossTotalAssets);
        if (fee != 0) {
            supply += PlasmaVaultFeesLib.managementFeeShares(fee, supply, grossTotalAssets, _SHARE_SCALE_MULTIPLIER());
        }
    }

    /// @notice Share supply including the virtual management fee shares and the performance fee shares that withdraw
    ///         and redeem mint before they pay, and the gross total assets
    /// @dev IL-9624 (Olympix M34), used only by previewRedeem, previewWithdraw, maxWithdraw and, with released request
    ///      shares (IL-9624 follow-up), maxRedeem; maxWithdraw and maxRedeem also pass its result to the reserve cap
    ///      `_unreservedShares`, so each prices the vault once. Models the order of
    ///      withdraw and redeem on fresh market balances: the management fee realization mints the virtual shares V
    ///      without changing the gross assets G, then `_addPerformanceFee` converts
    ///      `performanceFeeRateShares(decimals())` on S + V and G (the same conversion as here) and, with S + V
    ///      minted, mints all the p shares the FeeManager sizes (`PlasmaVaultFeesLib.pendingPerformanceFeeShares`,
    ///      FeeManager.pendingPerformanceFeeShares). The exit is then priced on S + V + p and G. Not modelled: the
    ///      market refresh in withdraw and redeem (stale balances, IL-8489). Deposits and mints do not crystallize
    ///      the performance fee (IL-8327, IL-8756), so previewDeposit, previewMint, maxDeposit, maxMint and the
    ///      convertTo* conversions keep `_supplyWithManagementFeeAndGrossAssets`.
    /// @dev `PlasmaVaultFeesLib.pendingPerformanceFeeShares` is a linked library call (DELEGATECALL, EIP-170 size
    ///      round of IL-9590); it reads the FeeManager as the vault, as the inlined code did.
    /// @return supply totalSupply() plus the virtual management fee shares V plus the pending performance fee shares
    /// @return grossTotalAssets Gross total assets G
    function _supplyWithPendingFeesAndGrossAssets() private view returns (uint256 supply, uint256 grossTotalAssets) {
        (supply, grossTotalAssets) = _supplyWithManagementFeeAndGrossAssets();
        supply += PlasmaVaultFeesLib.pendingPerformanceFeeShares(
            _convertToAssetsWithSupply(
                PlasmaVaultFeesLib.performanceFeeRateShares(decimals()),
                supply,
                grossTotalAssets,
                Math.Rounding.Floor
            ),
            supply
        );
    }
}
