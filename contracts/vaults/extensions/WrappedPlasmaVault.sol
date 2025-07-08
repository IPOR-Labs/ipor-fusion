// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract WrappedPlasmaVault is ERC4626Upgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    error ZeroPlasmaVaultAddress();
    error ZeroAssetAddress();
    error ZeroAssetsDeposit();
    error ZeroReceiverAddress();
    error ZeroSharesMint();
    error ZeroAssetsWithdraw();
    error ZeroOwnerAddress();

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);
    event PerformanceFeeAdded(uint256 fee, uint256 feeInShares);

    /// @notice The underlying PlasmaVault contract
    address public immutable PLASMA_VAULT;
    uint256 private immutable _SHARE_SCALE_MULTIPLIER; /// @dev 10^_decimalsOffset() multiplier for share scaling in ERC4626

    uint256 private constant FEE_PERCENTAGE_DECIMALS_MULTIPLIER = 1e4; /// @dev 10000 = 100% (2 decimal places for fee percentage)

    /// @notice Stores the total assets value from the last operation (deposit/withdraw/mint/redeem)
    /// @dev Used for performance fee calculations to track asset value changes between operations
    uint256 public lastTotalAssets;

    /**
     * @notice Initializes the Wrapped Plasma Vault with the underlying asset and vault configuration
     * @dev This constructor is marked as initializer for proxy deployment pattern
     * @param name_ Name of the vault token
     * @param symbol_ Symbol of the vault token
     * @param plasmaVault_ Address of the underlying Plasma Vault that this wrapper will interact with
     * @param wrappedPlasmaVaultOwner_ Address of the owner of the wrapped Plasma Vault
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(
        string memory name_,
        string memory symbol_,
        address plasmaVault_,
        address wrappedPlasmaVaultOwner_,
        address managementFeeAccount_,
        uint256 managementFeePercentage_,
        address performanceFeeAccount_,
        uint256 performanceFeePercentage_
    ) initializer {
        if (plasmaVault_ == address(0)) revert ZeroPlasmaVaultAddress();
        if (wrappedPlasmaVaultOwner_ == address(0)) revert ZeroOwnerAddress();

        address asset = ERC4626Upgradeable(plasmaVault_).asset();

        if (asset == address(0)) revert ZeroAssetAddress();

        __ERC4626_init(IERC20(asset));
        __ERC20_init(name_, symbol_);
        __Ownable_init(wrappedPlasmaVaultOwner_);

        PlasmaVaultLib.configureManagementFee(managementFeeAccount_, managementFeePercentage_);
        PlasmaVaultLib.configurePerformanceFee(performanceFeeAccount_, performanceFeePercentage_);

        PLASMA_VAULT = plasmaVault_;
        _SHARE_SCALE_MULTIPLIER = 10 ** _decimalsOffset();
    }

    /**
     * @notice Returns the total amount of underlying assets held by the vault
     * @dev Calculates total assets by querying the maximum withdrawable amount from the underlying PlasmaVault
     *
     * Calculation Flow:
     * 1. Asset Valuation
     *    - Queries underlying PlasmaVault
     *    - Determines maximum withdrawable amount
     *    - Accounts for vault's share position
     *
     * 2. Value Representation
     *    - Returns amount in underlying token decimals
     *    - Reflects current vault holdings
     *    - Considers protocol-specific limits
     *
     * Integration Context:
     * - Used for share price calculations
     * - Affects deposit/withdrawal limits
     * - Influences fee computations
     * - Critical for vault operations
     *
     * Important Notes:
     * - Value may fluctuate based on market conditions
     * - Subject to withdrawal limits
     * - Considers protocol-specific constraints
     * - Used in share/asset conversions
     *
     * @return uint256 Total assets in underlying token decimals
     */
    function totalAssets() public view virtual override returns (uint256) {
        uint256 grossTotalAssets = ERC4626Upgradeable(PLASMA_VAULT).maxWithdraw(address(this));
        uint256 unrealizedManagementFee = _getUnrealizedManagementFee(grossTotalAssets);
        return _totalAssets(grossTotalAssets, unrealizedManagementFee);
    }

    /**
     * @notice Simulates the amount of shares that would be minted for a given deposit
     * @dev Calculates shares accounting for both management and performance fees
     *
     * Calculation Flow:
     * 1. Fee Consideration
     *    - Accounts for unrealized management fees
     *    - Includes potential performance fees
     *    - Uses fee-adjusted total assets and supply
     *
     * 2. Share Price Calculation
     *    - Applies current conversion rate
     *    - Includes fee adjustments
     *    - Uses floor rounding for conservative estimate
     *
     * Integration Context:
     * - Used for deposit previews
     * - Helps users estimate outcomes
     * - Critical for UI/UX integration
     * - Supports deposit planning
     *
     * Important Notes:
     * - Preview may differ from actual mint
     * - Subject to market conditions
     * - Includes all applicable fees
     * - Uses conservative rounding
     *
     * @param assets_ Amount of assets to simulate deposit for
     * @return uint256 Expected number of shares to be minted
     * @custom:security View function, no state modifications
     */

    function previewDeposit(uint256 assets_) public view virtual override returns (uint256) {
        return _convertToSharesWithFees(assets_, Math.Rounding.Floor);
    }

    /**
     * @notice Deposits assets into the vault and mints corresponding shares
     * @dev Handles deposit validation, share minting, and fee realization
     *
     * Deposit Flow:
     * 1. Pre-deposit Validation
     *    - Validates deposit amount (non-zero)
     *    - Verifies receiver address
     *    - Calculates share amount
     *    - Checks share minting constraints
     *
     * 2. Fee Processing
     *    - Calculates and realizes management fees
     *    - Updates fee accounting state
     *    - Adjusts share calculations
     *
     * 3. Asset Transfer and Minting
     *    - Transfers assets from sender to vault
     *    - Approves assets for PlasmaVault deposit
     *    - Deposits into underlying PlasmaVault
     *    - Mints wrapped shares to receiver
     *    - Updates total assets tracking
     *
     * Security Features:
     * - Non-zero amount validation
     * - Address validation
     * - Reentrancy protection
     * - Safe ERC20 operations
     * - Fee calculation safety
     *
     * @param assets_ Amount of underlying assets to deposit
     * @param receiver_ Address to receive the minted shares
     * @return shares Amount of shares minted to receiver
     * @custom:security Non-reentrant and role-restricted
     */
    function deposit(uint256 assets_, address receiver_) public virtual override nonReentrant returns (uint256) {
        if (assets_ == 0) revert ZeroAssetsDeposit();
        if (receiver_ == address(0)) revert ZeroReceiverAddress();

        _calculateFees();

        uint256 shares = previewDeposit(assets_);

        if (shares == 0) revert ZeroSharesMint();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets_);

        IERC20(asset()).forceApprove(PLASMA_VAULT, assets_);

        ERC4626Upgradeable(PLASMA_VAULT).deposit(assets_, address(this));

        _mint(receiver_, shares);

        emit Deposit(msg.sender, receiver_, assets_, shares);

        lastTotalAssets = totalAssets();
        return shares;
    }

    /**
     * @notice Calculates the amount of assets needed to mint a specific amount of shares
     * @dev Converts shares to assets accounting for fees and rounding up
     *
     * Calculation Flow:
     * 1. Asset Conversion
     *    - Converts requested shares to underlying assets
     *    - Accounts for current fee state
     *    - Applies appropriate rounding
     *
     * 2. Fee Consideration
     *    - Includes unrealized management fees
     *    - Adjusts for fee-modified totals
     *    - Maintains share price accuracy
     *
     * Integration Context:
     * - Used in mint operations
     * - Affects deposit pricing
     * - Critical for share issuance
     * - Fee-aware calculations
     *
     * Important Notes:
     * - View function only
     * - Rounds up for mint safety
     * - Includes fee adjustments
     * - No state modifications
     *
     * @param shares Amount of shares to calculate assets for
     * @return uint256 Amount of assets needed to mint the specified shares
     * @custom:security View function, no state modifications
     */

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        return _convertToAssetsWithFees(shares, Math.Rounding.Ceil);
    }

    /**
     * @notice Mints vault shares by depositing the corresponding amount of assets
     * @dev Handles share minting with asset deposit and fee realization
     *
     * Minting Flow:
     * 1. Pre-mint Validation
     *    - Validates share amount (non-zero)
     *    - Verifies receiver address
     *    - Calculates required asset amount
     *    - Validates asset requirements
     *
     * 2. Fee Processing
     *    - Calculates and realizes management fees
     *    - Updates fee accounting state
     *    - Adjusts share calculations
     *
     * 3. Asset Transfer and Minting
     *    - Transfers required assets from sender
     *    - Approves assets for PlasmaVault deposit
     *    - Deposits into underlying PlasmaVault
     *    - Mints exact share amount to receiver
     *    - Updates total assets tracking
     *
     * Security Features:
     * - Non-zero amount validation
     * - Address validation
     * - Reentrancy protection
     * - Safe ERC20 operations
     * - Fee calculation safety
     *
     * @param shares_ Amount of vault shares to mint
     * @param receiver_ Address to receive the minted shares
     * @return assets Amount of underlying assets deposited
     * @custom:security Non-reentrant and role-restricted
     */
    function mint(uint256 shares_, address receiver_) public virtual override nonReentrant returns (uint256) {
        if (shares_ == 0) revert ZeroSharesMint();
        if (receiver_ == address(0)) revert ZeroReceiverAddress();

        _calculateFees();

        uint256 assets = previewMint(shares_);
        if (assets == 0) revert ZeroAssetsDeposit();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        IERC20(asset()).forceApprove(PLASMA_VAULT, assets);
        ERC4626Upgradeable(PLASMA_VAULT).deposit(assets, address(this));

        _mint(receiver_, shares_);

        emit Deposit(msg.sender, receiver_, assets, shares_);

        lastTotalAssets = totalAssets();

        return assets;
    }

    /**
     * @notice Returns the maximum amount of shares that can be withdrawn by an owner
     * @dev Calculates maximum shares considering fees and vault constraints
     *
     * Calculation Flow:
     * 1. Balance Assessment
     *    - Checks owner's current share balance
     *    - Considers withdrawal restrictions
     *    - Accounts for fees
     *
     * 2. Conversion Process
     *    - Converts shares to assets with fees
     *    - Uses floor rounding for conservative estimate
     *    - Applies any withdrawal limits
     *
     * Integration Context:
     * - Used for withdrawal planning
     * - Affects UI display limits
     * - Guides user interactions
     * - Supports withdrawal validation
     *
     * Important Notes:
     * - Conservative calculation
     * - Includes all fees
     * - Real-time value
     * - May change with market conditions
     *
     * @param owner Address of the share owner to check
     * @return uint256 Maximum amount of shares that can be withdrawn
     * @custom:security View function, no state modifications
     */

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _convertToAssetsWithFees(balanceOf(owner), Math.Rounding.Floor);
    }

    /**
     * @notice Simulates the amount of shares needed to withdraw a given amount of assets
     * @dev Calculates required shares accounting for both management and performance fees
     *
     * Calculation Flow:
     * 1. Fee Consideration
     *    - Accounts for unrealized management fees
     *    - Includes potential performance fees
     *    - Uses fee-adjusted total assets and supply
     *
     * 2. Share Calculation
     *    - Applies current conversion rate
     *    - Includes fee adjustments
     *    - Uses ceiling rounding for conservative estimate
     *
     * Integration Context:
     * - Used for withdrawal previews
     * - Helps users estimate costs
     * - Critical for UI/UX integration
     * - Supports withdrawal planning
     *
     * Important Notes:
     * - Preview may differ from actual withdrawal
     * - Subject to market conditions
     * - Includes all applicable fees
     * - Uses conservative rounding
     *
     * @param assets_ Amount of assets to simulate withdrawal for
     * @return uint256 Expected number of shares needed for withdrawal
     * @custom:security View function, no state modifications
     */

    function previewWithdraw(uint256 assets_) public view virtual override returns (uint256) {
        return _convertToSharesWithFees(assets_, Math.Rounding.Ceil);
    }

    /**
     * @notice Withdraws underlying assets from the vault by burning shares
     * @dev Handles asset withdrawal with share burning and fee realization
     *
     * Withdrawal Flow:
     * 1. Pre-withdrawal Validation
     *    - Validates withdrawal amount (non-zero)
     *    - Verifies receiver and owner addresses
     *    - Calculates required shares
     *    - Checks allowance if not owner
     *
     * 2. Fee Processing
     *    - Calculates and realizes management fees
     *    - Updates fee accounting state
     *    - Adjusts share calculations
     *
     * 3. Share Burning and Asset Transfer
     *    - Burns required shares from owner
     *    - Withdraws assets from underlying PlasmaVault
     *    - Transfers assets to receiver
     *    - Updates total assets tracking
     *    - Emits withdrawal event
     *
     * Security Features:
     * - Non-zero amount validation
     * - Address validation
     * - Allowance verification
     * - Reentrancy protection
     * - Safe ERC20 operations
     * - Fee calculation safety
     *
     * @param assets_ Amount of underlying assets to withdraw
     * @param receiver_ Address to receive the withdrawn assets
     * @param owner_ Owner of the shares to burn
     * @return shares Amount of shares burned
     * @custom:security Non-reentrant and role-restricted
     */
    function withdraw(
        uint256 assets_,
        address receiver_,
        address owner_
    ) public virtual override nonReentrant returns (uint256) {
        if (assets_ == 0) revert ZeroAssetsWithdraw();
        if (receiver_ == address(0)) revert ZeroReceiverAddress();

        _calculateFees();

        uint256 shares = previewWithdraw(assets_);

        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }

        _burn(owner_, shares);

        ERC4626Upgradeable(PLASMA_VAULT).withdraw(assets_, receiver_, address(this));

        emit Withdraw(msg.sender, receiver_, owner_, assets_, shares);

        lastTotalAssets = totalAssets();

        return shares;
    }

    /**
     * @notice Calculates the amount of assets that would be withdrawn for a given share redemption
     * @dev Converts shares to assets accounting for fees and rounding down
     *
     * Calculation Flow:
     * 1. Asset Conversion
     *    - Converts requested shares to underlying assets
     *    - Accounts for current fee state
     *    - Applies appropriate rounding
     *
     * 2. Fee Consideration
     *    - Includes unrealized management fees
     *    - Adjusts for fee-modified totals
     *    - Maintains share price accuracy
     *
     * Integration Context:
     * - Used in redeem operations
     * - Affects withdrawal pricing
     * - Critical for share redemption
     * - Fee-aware calculations
     *
     * Important Notes:
     * - View function only
     * - Rounds down for withdrawal safety
     * - Includes fee adjustments
     * - No state modifications
     *
     * @param shares Amount of shares to calculate assets for
     * @return uint256 Amount of assets that would be withdrawn
     * @custom:security View function, no state modifications
     */

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        return _convertToAssetsWithFees(shares, Math.Rounding.Floor);
    }

    /**
     * @notice Redeems vault shares for underlying assets
     * @dev Handles share redemption with asset withdrawal and fee realization
     *
     * Redemption Flow:
     * 1. Pre-redemption Validation
     *    - Validates share amount (non-zero)
     *    - Verifies receiver and owner addresses
     *    - Checks allowance if not owner
     *    - Calculates asset amount
     *
     * 2. Fee Processing
     *    - Calculates and realizes management fees
     *    - Updates fee accounting state
     *    - Adjusts share calculations
     *
     * 3. Share Burning and Asset Transfer
     *    - Burns shares from owner
     *    - Withdraws assets from underlying PlasmaVault
     *    - Transfers assets to receiver
     *    - Updates total assets tracking
     *    - Emits withdrawal event
     *
     * Security Features:
     * - Non-zero amount validation
     * - Address validation
     * - Allowance verification
     * - Reentrancy protection
     * - Safe ERC20 operations
     * - Fee calculation safety
     *
     * @param shares_ Amount of vault shares to redeem
     * @param receiver_ Address to receive the underlying assets
     * @param owner_ Owner of the shares to burn
     * @return assets Amount of underlying assets withdrawn
     * @custom:security Non-reentrant and role-restricted
     */
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_
    ) public virtual override nonReentrant returns (uint256) {
        if (shares_ == 0) revert ZeroSharesMint();
        if (receiver_ == address(0)) revert ZeroReceiverAddress();

        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares_);
        }

        _calculateFees();
        uint256 assets = previewRedeem(shares_);
        if (assets == 0) revert ZeroAssetsWithdraw();

        _burn(owner_, shares_);

        ERC4626Upgradeable(PLASMA_VAULT).withdraw(assets, receiver_, address(this));

        lastTotalAssets = totalAssets();

        emit Withdraw(msg.sender, receiver_, owner_, assets, shares_);
        return assets;
    }

    /**
     * @notice Converts assets to shares considering fees
     * @dev Uses internal conversion function with floor rounding
     * @param assets Amount of assets to convert
     * @return uint256 Amount of shares resulting from conversion
     * @custom:security View function, no state modifications
     */
    function convertToSharesWithFees(uint256 assets) public view returns (uint256) {
        return _convertToSharesWithFees(assets, Math.Rounding.Floor);
    }

    /**
     * @notice Converts shares to assets considering fees
     * @dev Uses internal conversion function with floor rounding
     * @param shares Amount of shares to convert
     * @return uint256 Amount of assets resulting from conversion
     * @custom:security View function, no state modifications
     */
    function convertToAssetsWithFees(uint256 shares) public view returns (uint256) {
        return _convertToAssetsWithFees(shares, Math.Rounding.Floor);
    }

    /**
     * @notice Configures the management fee parameters for the vault
     * @dev Updates management fee recipient and percentage through PlasmaVaultLib
     *
     * Configuration Flow:
     * 1. Parameter Validation
     *    - Validates fee account address
     *    - Verifies fee percentage within limits
     *    - Ensures configuration consistency
     *
     * 2. State Updates
     *    - Updates fee recipient address
     *    - Sets new fee percentage
     *    - Persists configuration in storage
     *
     * 3. Fee System Impact
     *    - Affects future fee calculations
     *    - Influences share price computations
     *    - Updates fee accrual parameters
     *
     * Security Features:
     * - Owner-only access control
     * - Parameter validation
     * - State consistency checks
     * - Safe fee calculations
     *
     * @param feeAccount_ Address to receive the management fees
     * @param feeInPercentage_ Management fee percentage with 2 decimal places (10000 = 100%)
     * @custom:security Restricted to contract owner
     */
    function configureManagementFee(address feeAccount_, uint256 feeInPercentage_) external onlyOwner {
        PlasmaVaultLib.configureManagementFee(feeAccount_, feeInPercentage_);
    }

    /**
     * @notice Configures the performance fee parameters for the vault
     * @dev Updates performance fee recipient and percentage through PlasmaVaultLib
     *
     * Configuration Flow:
     * 1. Parameter Validation
     *    - Validates fee account address
     *    - Verifies fee percentage within limits
     *    - Ensures configuration consistency
     *
     * 2. State Updates
     *    - Updates fee recipient address
     *    - Sets new fee percentage
     *    - Persists configuration in storage
     *
     * 3. Fee System Impact
     *    - Affects profit-based fee calculations
     *    - Influences performance tracking
     *    - Updates fee distribution parameters
     *    - Applies to future value increases
     *
     * Security Features:
     * - Owner-only access control
     * - Parameter validation
     * - State consistency checks
     * - Safe fee calculations
     *
     * @param feeAccount_ Address to receive the performance fees
     * @param feeInPercentage_ Performance fee percentage with 2 decimal places (10000 = 100%)
     * @custom:security Restricted to contract owner
     */
    function configurePerformanceFee(address feeAccount_, uint256 feeInPercentage_) external onlyOwner {
        PlasmaVaultLib.configurePerformanceFee(feeAccount_, feeInPercentage_);
    }

    /**
     * @notice Returns the current unrealized management fee amount
     * @dev Calculates accrued management fees since last fee realization using current total assets
     *
     * Calculation Flow:
     * 1. State Assessment
     *    - Gets current total assets
     *    - Retrieves fee configuration
     *    - Checks fee eligibility
     *
     * 2. Fee Computation
     *    - Calculates time elapsed since last update
     *    - Applies annual fee rate pro-rata
     *    - Converts to underlying token amount
     *    - Handles precision and rounding
     *
     * Integration Context:
     * - Used in maxWithdraw calculations
     * - Affects share price computations
     * - Impacts withdrawal amounts
     * - Key for fee tracking
     *
     * Important Notes:
     * - Time-based calculation
     * - Uses current total assets
     * - Pro-rata fee computation
     * - No state modifications
     *
     * @return uint256 Unrealized management fee in underlying token decimals
     */
    function getUnrealizedManagementFee() public view returns (uint256) {
        return _getUnrealizedManagementFee(ERC4626Upgradeable(PLASMA_VAULT).maxWithdraw(address(this)));
    }

    /**
     * @notice Retrieves the current performance fee configuration data
     * @dev Returns the performance fee settings from PlasmaVaultLib storage
     *
     * Data Structure:
     * 1. Fee Configuration
     *    - Fee recipient address
     *    - Fee percentage rate
     *    - Last update timestamp
     *    - Additional fee parameters
     *
     * Integration Context:
     * - Used for fee calculations
     * - Performance tracking
     * - Fee distribution
     * - Governance operations
     *
     * Important Notes:
     * - Read-only operation
     * - Returns current state
     * - No historical data
     * - Used in fee computations
     *
     * @return feeData Performance fee configuration struct containing recipient and rate information
     * @custom:security View function, no state modifications
     */
    function getPerformanceFeeData() external view returns (PlasmaVaultStorageLib.PerformanceFeeData memory feeData) {
        feeData = PlasmaVaultLib.getPerformanceFeeData();
    }

    /**
     * @notice Retrieves the current management fee configuration data
     * @dev Returns the management fee settings from PlasmaVaultLib storage
     *
     * Data Structure:
     * 1. Fee Configuration
     *    - Fee recipient address
     *    - Fee percentage rate
     *    - Last update timestamp
     *    - Time-based parameters
     *
     * Integration Context:
     * - Used for fee calculations
     * - Time-based fee tracking
     * - Fee distribution
     * - Governance operations
     *
     * Important Notes:
     * - Read-only operation
     * - Returns current state
     * - Critical for fee accrual
     * - Used in management fee computations
     *
     * @return feeData Management fee configuration struct containing recipient, rate, and timing information
     * @custom:security View function, no state modifications
     */
    function getManagementFeeData() external view returns (PlasmaVaultStorageLib.ManagementFeeData memory feeData) {
        feeData = PlasmaVaultLib.getManagementFeeData();
    }

    /**
     * @notice Manually triggers fee calculation and realization
     * @dev Calculates and realizes both management and performance fees
     *
     * Fee Realization Flow:
     * 1. Management Fee Processing
     *    - Calculates time-based management fees
     *    - Updates fee accounting state
     *    - Mints fee shares to recipient
     *
     * 2. Performance Fee Processing
     *    - Evaluates performance metrics
     *    - Calculates performance-based fees
     *    - Updates high water marks
     *    - Mints fee shares if applicable
     *
     * Integration Context:
     * - Manual fee realization
     * - Governance operations
     * - Fee recipient payments
     * - Performance tracking
     *
     * Important Notes:
     * - Updates fee state
     * - Mints fee shares
     * - Affects share price
     * - Updates tracking values
     *
     * @custom:security Non-view function that modifies state
     */

    function realizeFees() external nonReentrant {
        _calculateFees();
    }

    /**
     * @notice Converts assets to shares considering both management and performance fees
     * @dev Internal function used by deposit/mint operations to calculate share amounts
     *
     * Calculation Flow:
     * 1. Fee Consideration
     *    - Assumes management fees are realized first
     *    - Calculates performance fee impact
     *    - Adjusts share/asset ratios accordingly
     *
     * 2. Share Price Determination
     *    - Uses modified total assets/supply after fees
     *    - Applies specified rounding direction
     *    - Maintains price consistency with fee states
     *
     *    - Computes shares needed for fee payments
     *    - Adjusts total supply for fee minting
     *    - Preserves share value for existing holders
     *
     * Integration Context:
     * - Core conversion function for deposits/mints
     * - Used in preview calculations
     * - Critical for share price accuracy
     * - Maintains fee-adjusted ratios
     *
     * Important Notes:
     * - Management fees processed before performance fees
     * - Uses conservative rounding approach
     * - Preserves share value through conversions
     * - Handles edge cases safely
     *
     * Mathematical Model:
     * - Applies fee-adjusted conversion formula
     * - Uses mulDiv for precision
     * - Includes decimal offset for accuracy
     * - Maintains consistent share pricing
     *
     * @param assets_ Amount of assets to convert to shares
     * @param rounding_ Rounding direction for calculations
     * @return uint256 Amount of shares after fee adjustments
     * @custom:security Internal view function with safe math
     */
    function _convertToSharesWithFees(
        uint256 assets_,
        Math.Rounding rounding_
    ) internal view virtual returns (uint256) {
        (
            uint256 modifiedTotalAssets,
            uint256 modifiedTotalSupply
        ) = _takeIntoAccountInTotalsWhenManagementFeeIsRealized(rounding_);

        return
            assets_.mulDiv(
                modifiedTotalSupply +
                    _calculateTotalFeeSharesForConvertWithFee(modifiedTotalAssets, modifiedTotalSupply, rounding_) +
                    _SHARE_SCALE_MULTIPLIER,
                modifiedTotalAssets + 1,
                rounding_
            );
    }

    /**
     * @notice Converts shares to assets considering fees and total supply/asset ratios
     * @dev Internal conversion function that handles fee adjustments and asset calculations
     *
     * Calculation Flow:
     * 1. Fee Processing
     *    - Accounts for unrealized management fees
     *    - Adjusts total assets and supply
     *    - Handles performance fee impacts
     *
     * 2. Asset Value Determination
     *    - Uses modified total assets/supply after fees
     *    - Applies specified rounding direction
     *    - Maintains price consistency with fee states
     *
     * 3. Asset Calculation
     *    - Computes assets corresponding to shares
     *    - Adjusts for fee-modified totals
     *    - Preserves share value for holders
     *
     * Integration Context:
     * - Core conversion function for withdrawals/redemptions
     * - Used in preview calculations
     * - Critical for asset value accuracy
     * - Maintains fee-adjusted ratios
     *
     * Important Notes:
     * - Management fees processed before performance fees
     * - Uses conservative rounding approach
     * - Preserves asset value through conversions
     * - Handles edge cases safely
     *
     * Mathematical Model:
     * - Applies fee-adjusted conversion formula
     * - Uses mulDiv for precision
     * - Includes decimal offset for accuracy
     * - Maintains consistent asset pricing
     *
     * @param shares_ Amount of shares to convert to assets
     * @param rounding_ Rounding direction for calculations
     * @return uint256 Amount of assets after fee adjustments
     * @custom:security Internal view function with safe math
     */
    function _convertToAssetsWithFees(
        uint256 shares_,
        Math.Rounding rounding_
    ) internal view virtual returns (uint256) {
        (
            uint256 modifiedTotalAssets,
            uint256 modifiedTotalSupply
        ) = _takeIntoAccountInTotalsWhenManagementFeeIsRealized(rounding_);

        return
            shares_.mulDiv(
                modifiedTotalAssets + 1,
                modifiedTotalSupply +
                    _calculateTotalFeeSharesForConvertWithFee(modifiedTotalAssets, modifiedTotalSupply, rounding_) +
                    _SHARE_SCALE_MULTIPLIER,
                rounding_
            );
    }

    function _totalAssets(uint256 grossTotalAssets, uint256 unrealizedManagementFee) internal view returns (uint256) {
        if (unrealizedManagementFee >= grossTotalAssets) {
            return 0;
        } else {
            return grossTotalAssets - unrealizedManagementFee;
        }
    }

    function _convertToSharesSimple(
        uint256 currentTotalSupply,
        uint256 currentTotalAssets,
        uint256 assets,
        Math.Rounding rounding_
    ) internal view returns (uint256) {
        return
            currentTotalSupply == 0
                ? assets * _SHARE_SCALE_MULTIPLIER
                : assets.mulDiv(currentTotalSupply + _SHARE_SCALE_MULTIPLIER, currentTotalAssets + 1, rounding_);
    }

    /**
     * @notice Calculates total fee shares for asset/share conversions with fee adjustments
     * @dev Computes performance fee shares based on asset value changes
     *
     * Calculation Flow:
     * 1. Performance Fee Assessment
     *    - Compares current assets to last recorded total
     *    - Calculates fee on asset value increase
     *    - Uses configured fee percentage
     *
     * 2. Share Conversion
     *    - Converts performance fee to shares
     *    - Applies current conversion rate
     *    - Uses specified rounding direction
     *
     * Mathematical Model:
     * - Fee = (CurrentAssets - LastAssets) * FeePercentage
     * - Shares = Fee * (Supply/Assets) with rounding
     *
     * @param modifiedTotalAssets_ Total assets after fee adjustments
     * @param modifiedTotalSupply_ Total supply after fee adjustments
     * @param rounding_ Rounding direction for calculations
     * @return totalFeeShares Amount of shares representing total fees
     * @custom:security Internal view function with safe math
     */
    function _calculateTotalFeeSharesForConvertWithFee(
        uint256 modifiedTotalAssets_,
        uint256 modifiedTotalSupply_,
        Math.Rounding rounding_
    ) internal view returns (uint256 totalFeeShares) {
        uint256 performanceFeeWhenManagementFeeIsMinted = modifiedTotalAssets_ > lastTotalAssets
            ? Math.mulDiv(
                modifiedTotalAssets_ - lastTotalAssets,
                PlasmaVaultLib.getPerformanceFeeData().feeInPercentage,
                FEE_PERCENTAGE_DECIMALS_MULTIPLIER
            )
            : 0;

        totalFeeShares = performanceFeeWhenManagementFeeIsMinted > 0
            ? _convertToSharesSimple(
                modifiedTotalSupply_,
                modifiedTotalAssets_,
                performanceFeeWhenManagementFeeIsMinted,
                rounding_
            )
            : 0;
    }

    /**
     * @notice Calculates modified total assets and supply when management fee is realized
     * @dev Simulates the impact of management fee realization on vault totals
     *
     * Calculation Flow:
     * 1. Asset Assessment
     *    - Gets maximum withdrawable assets from PlasmaVault
     *    - Calculates unrealized management fee
     *    - Determines initial totals
     *
     * 2. Fee Share Calculation
     *    - Converts fee to shares based on current ratio
     *    - Handles edge case of zero total supply
     *    - Applies specified rounding direction
     *
     * 3. Total Modifications
     *    - Adds fee to total assets
     *    - Adds fee shares to total supply
     *    - Returns modified totals
     *
     * @param rounding_ Rounding direction for share calculations
     * @return modifiedTotalAssets Total assets after fee realization
     * @return modifiedTotalSupply Total supply after fee shares minted
     * @custom:security Internal view function with safe math
     */
    function _takeIntoAccountInTotalsWhenManagementFeeIsRealized(
        Math.Rounding rounding_
    ) internal view returns (uint256 modifiedTotalAssets, uint256 modifiedTotalSupply) {
        uint256 grossTotalAssets = ERC4626Upgradeable(PLASMA_VAULT).maxWithdraw(address(this));
        uint256 unrealizedManagementFeeInUnderlying = _getUnrealizedManagementFee(grossTotalAssets);
        uint256 initialTotalAssets = _totalAssets(grossTotalAssets, unrealizedManagementFeeInUnderlying);
        uint256 initialSupply = totalSupply();

        uint256 simulatedManagementFeeInShares = _convertToSharesSimple(
            initialSupply,
            grossTotalAssets,
            unrealizedManagementFeeInUnderlying,
            rounding_
        );

        modifiedTotalAssets = initialTotalAssets + unrealizedManagementFeeInUnderlying;
        modifiedTotalSupply = initialSupply + simulatedManagementFeeInShares;
    }

    /**
     * @notice Calculates the current unrealized management fee based on total assets
     * @dev Computes time-based management fee accrual since last fee update
     *
     * Calculation Flow:
     * 1. Fee Data Validation
     *    - Checks if fee percentage is set
     *    - Verifies last update timestamp
     *    - Validates current timestamp
     *
     * 2. Fee Computation
     *    - Calculates time elapsed since last update
     *    - Applies annual fee rate pro-rata
     *    - Uses total assets as fee base
     *
     * Mathematical Model:
     * - Fee = TotalAssets * TimeElapsed * FeeRate / (365 days * FEE_DECIMALS)
     * - Pro-rates annual fee based on elapsed time
     * - Maintains precision through calculations
     *
     * Important Notes:
     * - Returns 0 if fee conditions not met
     * - Uses block timestamp for time tracking
     * - Applies fee percentage with decimals
     * - Handles edge cases safely
     * - Return value is denominated in underlying asset tokens
     *
     * @param totalAssets_ Current total assets to calculate fee on
     * @return uint256 Unrealized management fee amount in underlying asset tokens
     * @custom:security Internal view function with safe math
     */
    function _getUnrealizedManagementFee(uint256 totalAssets_) internal view returns (uint256) {
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultLib.getManagementFeeData();

        uint256 blockTimestamp = block.timestamp;

        if (
            feeData.feeInPercentage == 0 ||
            feeData.lastUpdateTimestamp == 0 ||
            blockTimestamp <= feeData.lastUpdateTimestamp
        ) {
            return 0;
        }

        return
            Math.mulDiv(
                totalAssets_ * (blockTimestamp - feeData.lastUpdateTimestamp),
                feeData.feeInPercentage,
                365 days * FEE_PERCENTAGE_DECIMALS_MULTIPLIER
            );
    }

    function _calculateFees() internal {
        // First realize management fee
        _realizeManagementFee();
        // Then add performance fee based on lastTotalAssets
        _realizePerformanceFee(lastTotalAssets);
    }

    function _realizeManagementFee() internal {
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = PlasmaVaultLib.getManagementFeeData();
        uint256 unrealizedFeeInUnderlying = getUnrealizedManagementFee();

        PlasmaVaultLib.updateManagementFeeData();

        uint256 unrealizedFeeInShares = convertToShares(unrealizedFeeInUnderlying);

        if (unrealizedFeeInShares == 0) {
            return;
        }

        _mint(feeData.feeAccount, unrealizedFeeInShares);
        emit ManagementFeeRealized(unrealizedFeeInUnderlying, unrealizedFeeInShares);
    }

    function _realizePerformanceFee(uint256 totalAssetsBefore_) internal {
        uint256 totalAssetsAfter = totalAssets();
        if (totalAssetsAfter < totalAssetsBefore_) {
            return;
        }
        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = PlasmaVaultLib.getPerformanceFeeData();
        uint256 fee = Math.mulDiv(
            totalAssetsAfter - totalAssetsBefore_,
            feeData.feeInPercentage,
            FEE_PERCENTAGE_DECIMALS_MULTIPLIER
        );
        uint256 feeInShares = convertToShares(fee);
        _mint(feeData.feeAccount, feeInShares);
        emit PerformanceFeeAdded(fee, feeInShares);

        /// @dev Update lastTotalAssets after realizing fees to ensure consistent performance fee calculations
        lastTotalAssets = totalAssets();
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        return
            supply == 0
                ? assets * _SHARE_SCALE_MULTIPLIER
                : assets.mulDiv(supply + _SHARE_SCALE_MULTIPLIER, totalAssets() + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        // When supply is 0, we need to divide by _SHARE_SCALE_MULTIPLIER to account for decimal offset
        return
            supply == 0
                ? shares.mulDiv(1, _SHARE_SCALE_MULTIPLIER, rounding)
                : shares.mulDiv(totalAssets() + 1, supply + _SHARE_SCALE_MULTIPLIER, rounding);
    }

    /**
     * @notice Returns the decimals offset for the vault
     * @return Decimals offset
     */
    function _decimalsOffset() internal view override returns (uint8) {
        return 2;
    }
}
