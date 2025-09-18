// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {FeeManagerData, FeeManagerFactory, FeeConfig} from "../managers/fee/FeeManagerFactory.sol";

import {FeeManagerInitData} from "../managers/fee/FeeManager.sol";
import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";
import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";
import {UniversalReader} from "../universal_reader/UniversalReader.sol";
import {ContextClientStorageLib} from "../managers/context/ContextClientStorageLib.sol";
import {PreHooksHandler} from "../handlers/pre_hooks/PreHooksHandler.sol";
import {PlasmaVaultFeesLib} from "./lib/PlasmaVaultFeesLib.sol";
import {PlasmaVaultMarketsLib} from "./lib/PlasmaVaultMarketsLib.sol";
import {RecipientFee} from "../managers/fee/FeeManager.sol";

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
    PreHooksHandler
{
    using Address for address;
    using Math for uint256;

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
    error NoAssetsToDeposit();
    error NoSharesToDeposit();
    error UnsupportedFuse();
    error UnsupportedMethod();
    error WithdrawManagerInvalidSharesToRelease(uint256 sharesToRelease);
    error PermitFailed();
    error WithdrawManagerNotSet();

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);
    event DepositFeeRealized(address recipient, uint256 feeShares);


    /// @notice Constructor with initialization for direct deployment
    /// @dev Used when deploying directly without proxy
    /// @param initData_ Initialization parameters encapsulated in PlasmaVaultInitData struct
    constructor(PlasmaVaultInitData memory initData_) ERC20Upgradeable() ERC4626Upgradeable() initializer {
        _initializeVault(initData_);
    }

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
    ///    - Delegates calls to PlasmaVaultBase
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
        } else {
            return PLASMA_VAULT_BASE().functionDelegateCall(msg.data);
        }
    }

    /// @notice The plasma vault base contract address
    /// @dev Retrieved from storage library
    function PLASMA_VAULT_BASE() public view returns (address) {
        return PlasmaVaultStorageLib.getPlasmaVaultBase();
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
    ///    - Records initial total assets
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
    ///    - Updates market balances
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
    /// - Validates market limits
    /// - Ensures balance consistency
    ///
    /// @param calls_ Array of FuseAction structs defining protocol interactions
    /// @custom:security Non-reentrant and role-restricted
    /// @custom:access Restricted to ALPHA_ROLE (managed by ATOMIST_ROLE)
    function execute(FuseAction[] calldata calls_) external override nonReentrant restricted {
        uint256 callsCount = calls_.length;
        uint256[] memory markets = new uint256[](callsCount);
        uint256 marketIndex;
        uint256 fuseMarketId;

        uint256 totalAssetsBefore = totalAssets();

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

        _updateMarketsBalances(markets);

        _addPerformanceFee(totalAssetsBefore);
    }

    /// @notice Updates balances for specified markets and calculates performance fees
    /// @dev Refreshes market balances and applies performance fee calculations
    ///
    /// Update Flow:
    /// 1. Balance Calculation
    ///    - Retrieves current total assets
    ///    - Updates specified market balances
    ///    - Calculates performance metrics
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
    ///
    /// @param marketIds_ Array of market IDs to update
    /// @return uint256 Updated total assets after balance refresh
    /// @custom:access Public function, no role restrictions
    function updateMarketsBalances(uint256[] calldata marketIds_) external restricted returns (uint256) {
        if (marketIds_.length == 0) {
            return totalAssets();
        }
        uint256 totalAssetsBefore = totalAssets();
        _updateMarketsBalances(marketIds_);
        _addPerformanceFee(totalAssetsBefore);

        return totalAssets();
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
    /// @param shares_ Number of vault shares to mint
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

        (address feeRecipient, uint256 feeShares) = PlasmaVaultFeesLib.prepareForRealizeDepositFee(shares_);

        depositAssets = super.mint(shares_ + feeShares, receiver_);

        if (feeShares > 0) {
            _transfer(receiver_, feeRecipient, feeShares);
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
    ///    - Records initial assets
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

        uint256 totalAssetsBefore = totalAssets();

        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        uint256 sharesToRelease = WithdrawManager(withdrawManager).getSharesToRelease();

        uint256 assetsToWithdrawFromMarkets;

        if (sharesToRelease > 0) {
            /// @dev When shares are in withdrawal request, we need to withdraw more assets to cover the shares and use offset
            /// @dev Offset of 0.01% (10001/10000) is added to account for potential rounding errors and price fluctuations during withdrawal
            assetsToWithdrawFromMarkets = assets_ + (convertToAssets(sharesToRelease) * 10001) / 10000;
        } else {
            assetsToWithdrawFromMarkets = assets_ + WITHDRAW_FROM_MARKETS_OFFSET;
        }

        _withdrawFromMarkets(assetsToWithdrawFromMarkets, IERC20(asset()).balanceOf(address(this)));

        _addPerformanceFee(totalAssetsBefore);

        uint256 maxAssets = maxWithdraw(owner_);

        if (assets_ > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner_, assets_, maxAssets);
        }

        uint256 shares = convertToShares(assets_);

        uint256 feeSharesToBurn = WithdrawManager(withdrawManager).canWithdrawFromUnallocated(shares);

        withdrawnShares = shares - feeSharesToBurn;

        super._withdraw(
            _msgSender(),
            receiver_,
            owner_,
            assets_ - super.convertToAssets(feeSharesToBurn),
            withdrawnShares
        );

        if (feeSharesToBurn > 0) {
            if (_msgSender() != owner_) {
                _spendAllowance(owner_, _msgSender(), feeSharesToBurn);
            }

            _burn(owner_, feeSharesToBurn);
        }
    }

    function previewDeposit(uint256 assets_) public view override returns (uint256) {
        uint256 shares = super.previewDeposit(assets_);
        (, uint256 feeShares) = PlasmaVaultFeesLib.prepareForRealizeDepositFee(shares);
        return feeShares > 0 ? shares - feeShares : shares;
    }

    function previewMint(uint256 shares_) public view override returns (uint256) {
        (, uint256 feeShares) = PlasmaVaultFeesLib.prepareForRealizeDepositFee(shares_);
        return super.previewMint(shares_ + feeShares);
    }

    function previewRedeem(uint256 shares_) public view override returns (uint256) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager != address(0)) {
            uint256 withdrawFee = WithdrawManager(withdrawManager).getWithdrawFee();
            if (withdrawFee > 0) {
                return super.previewRedeem(Math.mulDiv(shares_, 1e18 - withdrawFee, 1e18));
            }
        }

        return super.previewRedeem(shares_);
    }

    function previewWithdraw(uint256 assets_) public view override returns (uint256) {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager != address(0)) {
            /// @dev get withdraw fee in shares with 18 decimals
            uint256 withdrawFee = WithdrawManager(withdrawManager).getWithdrawFee();

            if (withdrawFee > 0) {
                return Math.mulDiv(super.previewWithdraw(assets_), 1e18, withdrawFee);
            }
        }
        return super.previewWithdraw(assets_);
    }

    /// @notice Redeems vault shares for underlying assets
    /// @dev Handles share redemption with fee realization and iterative withdrawal
    ///
    /// Redemption Flow:
    /// 1. Pre-redemption
    ///    - Validates share amount
    ///    - Checks addresses
    ///    - Realizes management fees
    ///    - Records initial state
    ///
    /// 2. Asset Withdrawal
    ///    - Calculates asset amount
    ///    - Attempts market withdrawals
    ///    - Handles slippage protection
    ///    - Retries if needed (up to REDEEM_ATTEMPTS)
    ///
    /// 3. Fee Processing
    ///    - Calculates performance metrics
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
        uint256 maxShares = maxRedeem(owner_);
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
    ) external override restricted returns (uint256) {
        bool canWithdraw = WithdrawManager(PlasmaVaultStorageLib.getWithdrawManager().manager).canWithdrawFromRequest(
            owner_,
            shares_
        );

        if (!canWithdraw) {
            revert WithdrawManagerInvalidSharesToRelease(shares_);
        }

        uint256 maxShares = maxRedeem(owner_);

        if (shares_ > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner_, shares_, maxShares);
        }

        return _redeem(shares_, receiver_, owner_, false);
    }

    /// @notice Calculates maximum deposit amount allowed for an address
    /// @dev Overrides ERC4626 maxDeposit considering total supply cap
    ///
    /// Calculation Flow:
    /// 1. Supply Validation
    ///    - Retrieves total supply cap
    ///    - Gets current total supply
    ///    - Checks available capacity
    ///
    /// 2. Conversion Logic
    ///    - Calculates remaining space
    ///    - Converts to asset amount
    ///    - Handles edge cases
    ///
    /// Constraints:
    /// - Returns 0 if cap is reached
    /// - Respects supply cap limits
    /// - Considers share/asset ratio
    /// - Maintains vault integrity
    ///
    /// @return uint256 Maximum amount of assets that can be deposited
    /// @custom:access Public view function, no role restrictions
    function maxDeposit(address) public view virtual override returns (uint256) {
        uint256 totalSupplyCap = PlasmaVaultLib.getTotalSupplyCap();
        uint256 totalSupply = totalSupply();

        if (totalSupply >= totalSupplyCap) {
            return 0;
        }

        uint256 exchangeRate = convertToAssets(10 ** uint256(decimals()));
        (, uint256 feeShares) = PlasmaVaultFeesLib.prepareForRealizeDepositFee(totalSupplyCap - totalSupply);
        uint256 sharesToMint = totalSupplyCap - totalSupply - feeShares;

        if (type(uint256).max / exchangeRate < sharesToMint) {
            return type(uint256).max;
        }

        return convertToAssets(sharesToMint);
    }

    /// @notice Calculates maximum number of shares that can be minted
    /// @dev Overrides ERC4626 maxMint considering total supply cap
    ///
    /// Calculation Flow:
    /// 1. Supply Validation
    ///    - Retrieves total supply cap
    ///    - Gets current total supply
    ///    - Validates remaining capacity
    ///
    /// 2. Share Calculation
    ///    - Computes available share space
    ///    - Handles cap constraints
    ///    - Returns maximum mintable shares
    ///
    /// Constraints:
    /// - Returns 0 if cap is reached
    /// - Respects total supply limit
    /// - Direct share calculation
    /// - No asset conversion needed
    ///
    /// @return uint256 Maximum number of shares that can be minted
    /// @custom:access Public view function, no role restrictions
    function maxMint(address) public view virtual override returns (uint256) {
        uint256 totalSupplyCap = PlasmaVaultLib.getTotalSupplyCap();
        uint256 totalSupply = totalSupply();

        if (totalSupply >= totalSupplyCap) {
            return 0;
        }
        (, uint256 feeShares) = PlasmaVaultFeesLib.prepareForRealizeDepositFee(totalSupplyCap - totalSupply);

        /// @dev we need to subtract fee shares to get the maximum number of shares that can be minted, We accept the error of calculating a higher fee than will actually be charged.
        return totalSupplyCap - totalSupply - feeShares;
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
    /// @dev Calculates net total assets after management fee deduction
    ///
    /// Calculation Flow:
    /// 1. Gross Assets
    ///    - Retrieves vault balance
    ///    - Adds market positions
    ///    - Includes pending operations
    ///
    /// 2. Fee Deduction
    ///    - Calculates unrealized management fees
    ///    - Subtracts from gross total
    ///    - Handles edge cases
    ///
    /// Important Notes:
    /// - Excludes runtime accrued market interest
    /// - Excludes runtime accrued performance fees
    /// - Considers management fee impact
    /// - Returns 0 if fees exceed assets
    ///
    /// @return uint256 Net total assets in underlying token decimals
    /// @custom:access Public view function, no role restrictions
    function totalAssets() public view virtual override returns (uint256) {
        uint256 grossTotalAssets = _getGrossTotalAssets();
        uint256 unrealizedManagementFee = PlasmaVaultFeesLib.getUnrealizedManagementFee(grossTotalAssets);

        if (unrealizedManagementFee >= grossTotalAssets) {
            return 0;
        } else {
            return grossTotalAssets - unrealizedManagementFee;
        }
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
    ///    - Updates market balances
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
        _updateMarketsBalances(markets);
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

        uint256 assets;
        uint256 vaultCurrentBalanceUnderlying;

        uint256 totalAssetsBefore = totalAssets();

        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        uint256 assetsToRelease = convertToAssets(WithdrawManager(withdrawManager).getSharesToRelease());

        for (uint256 i; i < REDEEM_ATTEMPTS; ++i) {
            assets = convertToAssets(shares_);
            vaultCurrentBalanceUnderlying = IERC20(asset()).balanceOf(address(this));

            _withdrawFromMarkets(_includeSlippage(assets) + assetsToRelease, vaultCurrentBalanceUnderlying);
        }

        _addPerformanceFee(totalAssetsBefore);

        if (!withFee_) {
            withdrawnAssets = convertToAssets(shares_);
            _withdraw(_msgSender(), receiver_, owner_, withdrawnAssets, shares_);
        } else {
            uint256 feeSharesToBurn = WithdrawManager(withdrawManager).canWithdrawFromUnallocated(shares_);
            uint256 sharesToWithdraw = shares_ - feeSharesToBurn;

            withdrawnAssets = convertToAssets(sharesToWithdraw);

            super._withdraw(_msgSender(), receiver_, owner_, withdrawnAssets, sharesToWithdraw);

            if (feeSharesToBurn > 0) {
                if (_msgSender() != owner_) {
                    _spendAllowance(owner_, _msgSender(), feeSharesToBurn);
                }

                _burn(owner_, feeSharesToBurn);
            }
        }
    }

    /// @notice The share scale multiplier for ERC4626 operations
    /// @dev Retrieved from storage library
    function _SHARE_SCALE_MULTIPLIER() internal view returns (uint256) {
        return PlasmaVaultStorageLib.getShareScaleMultiplier();
    }

    /// @notice Private method containing the common initialization logic
    /// @param initData_ Initialization parameters encapsulated in PlasmaVaultInitData struct
    /// @dev This method is used by both constructor and proxyInitialize to avoid code duplication
    function _initializeVault(PlasmaVaultInitData memory initData_) private {
        super.__ERC20_init(initData_.assetName, initData_.assetSymbol);
        super.__ERC4626_init(IERC20(initData_.underlyingToken));

        PlasmaVaultStorageLib.setShareScaleMultiplier(10 ** _decimalsOffset());
        PlasmaVaultStorageLib.setPlasmaVaultBase(initData_.plasmaVaultBase);

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

        FeeManagerData memory feeManagerData = FeeManagerFactory(initData_.feeConfig.feeFactory).deployFeeManager(
            FeeManagerInitData({
                initialAuthority: initData_.accessManager,
                plasmaVault: address(this),
                iporDaoManagementFee: initData_.feeConfig.iporDaoManagementFee,
                iporDaoPerformanceFee: initData_.feeConfig.iporDaoPerformanceFee,
                iporDaoFeeRecipientAddress: initData_.feeConfig.iporDaoFeeRecipientAddress,
                recipientManagementFees: new RecipientFee[](0),
                recipientPerformanceFees: new RecipientFee[](0)
            })
        );

        PlasmaVaultLib.configurePerformanceFee(feeManagerData.performanceFeeAccount, feeManagerData.performanceFee);
        PlasmaVaultLib.configureManagementFee(feeManagerData.managementFeeAccount, feeManagerData.managementFee);

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

    function _addPerformanceFee(uint256 totalAssetsBefore_) internal {
        uint256 totalAssetsAfter = totalAssets();

        if (totalAssetsAfter < totalAssetsBefore_) {
            return;
        }

        (address recipient, uint256 feeShares) = PlasmaVaultFeesLib.prepareForAddPerformanceFee(
            totalSupply(),
            decimals(),
            _decimalsOffset(),
            convertToAssets(10 ** uint256(decimals()))
        );

        if (recipient == address(0) || feeShares == 0) {
            return;
        }

        /// @dev total supply cap validation is disabled for fee minting
        PlasmaVaultLib.setTotalSupplyCapValidation(1);

        _mint(recipient, feeShares);

        /// @dev total supply cap validation is enabled when fee minting is finished
        PlasmaVaultLib.setTotalSupplyCapValidation(0);
    }

    function _realizeManagementFee() internal {
        (address recipient, uint256 unrealizedFeeInUnderlying) = PlasmaVaultFeesLib.prepareForRealizeManagementFee(
            _getGrossTotalAssets()
        );

        uint256 unrealizedFeeInShares = convertToShares(unrealizedFeeInUnderlying);

        if (unrealizedFeeInShares == 0) {
            return;
        }

        /// @dev minting is an act of management fee realization
        /// @dev total supply cap validation is disabled for fee minting
        PlasmaVaultLib.setTotalSupplyCapValidation(1);

        _mint(recipient, unrealizedFeeInShares);

        /// @dev total supply cap validation is enabled when fee minting is finished
        PlasmaVaultLib.setTotalSupplyCapValidation(0);

        emit ManagementFeeRealized(unrealizedFeeInUnderlying, unrealizedFeeInShares);
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

            _updateMarketsBalances(markets);
        }
    }

    /// @notice Update balances in the vault for markets touched by the fuses during the execution of all FuseActions
    /// @param markets_ Array of market ids touched by the fuses in the FuseActions
    function _updateMarketsBalances(uint256[] memory markets_) internal {
        DataToCheck memory dataToCheck = PlasmaVaultMarketsLib.updateMarketsBalances(
            markets_,
            asset(),
            decimals(),
            _decimalsOffset()
        );

        dataToCheck.totalBalanceInVault = _getGrossTotalAssets();

        AssetDistributionProtectionLib.checkLimits(dataToCheck);
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
        bytes4 sig = bytes4(data_[0:4]);
        bool immediate;
        uint32 delay;

        if (this.transferFrom.selector == sig) {
            (address tranferFromAddress, , ) = abi.decode(_msgData()[4:], (address, address, uint256));

            /// @dev check if the owner of shares has access to transfer
            IporFusionAccessManager(authority()).canCallAndUpdate(tranferFromAddress, address(this), sig);

            /// @dev check if the caller has access to transferFrom method
            (immediate, delay) = IporFusionAccessManager(authority()).canCallAndUpdate(caller_, address(this), sig);
        } else if (this.deposit.selector == sig || this.mint.selector == sig) {
            (, address receiver) = abi.decode(_msgData()[4:], (uint256, address));

            /// @dev check if the receiver of shares has access to deposit or mint and setup delay
            IporFusionAccessManager(authority()).canCallAndUpdate(receiver, address(this), sig);
            /// @dev check if the caller has access to deposit or mint and setup delay
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        } else if (this.depositWithPermit.selector == sig) {
            (, address receiver, , , , ) = abi.decode(
                _msgData()[4:],
                (uint256, address, uint256, uint8, bytes32, bytes32)
            );

            /// @dev check if the receiver of shares has access to depositWithPermit and setup delay
            IporFusionAccessManager(authority()).canCallAndUpdate(receiver, address(this), sig);
            /// @dev check if the caller has access to depositWithPermit and setup delay
            (immediate, delay) = AuthorityUtils.canCallWithDelay(authority(), caller_, address(this), sig);
        } else if (this.redeem.selector == sig || this.withdraw.selector == sig) {
            (, , address owner) = abi.decode(_msgData()[4:], (uint256, address, address));

            /// @dev check if the owner of shares has access to redeem or withdraw and setup delay
            IporFusionAccessManager(authority()).canCallAndUpdate(owner, address(this), sig);

            (immediate, delay) = IporFusionAccessManager(authority()).canCallAndUpdate(caller_, address(this), sig);
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

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual override returns (uint256) {
        uint256 supply = totalSupply();

        return
            supply == 0
                ? assets * _SHARE_SCALE_MULTIPLIER()
                : assets.mulDiv(supply + _SHARE_SCALE_MULTIPLIER(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual override returns (uint256) {
        uint256 supply = totalSupply();

        return
            supply == 0
                ? shares.mulDiv(1, _SHARE_SCALE_MULTIPLIER(), rounding)
                : shares.mulDiv(totalAssets() + 1, supply + _SHARE_SCALE_MULTIPLIER(), rounding);
    }
}
