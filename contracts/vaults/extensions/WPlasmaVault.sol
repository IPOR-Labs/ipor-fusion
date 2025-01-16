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

contract WPlasmaVault is ERC4626Upgradeable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Custom errors
    error ZeroPlasmaVaultAddress();
    error ZeroAssetAddress();
    error ZeroAssetsDeposit();
    error ZeroReceiverAddress();
    error ZeroSharesMint();
    error ZeroAssetsWithdraw();

    event ManagementFeeRealized(uint256 unrealizedFeeInUnderlying, uint256 unrealizedFeeInShares);
    event PerformanceFeeAdded(uint256 fee, uint256 feeInShares);
    /// @notice The underlying PlasmaVault contract
    address public immutable PLASMA_VAULT;
    uint256 private constant FEE_PERCENTAGE_DECIMALS_MULTIPLIER = 1e4; /// @dev 10000 = 100% (2 decimal places for fee percentage)

    /// @notice Stores the total assets value from the last operation (deposit/withdraw/mint/redeem)
    /// @dev Used for performance fee calculations to track asset value changes between operations
    uint256 public lastTotalAssets;

    /**
     * @notice Initializes the Wrapped Plasma Vault with the underlying asset and vault configuration
     * @dev This constructor is marked as initializer for proxy deployment pattern
     * @param asset_ Address of the underlying ERC20 token that the vault will manage
     * @param name_ Name of the vault token
     * @param symbol_ Symbol of the vault token
     * @param plasmaVault_ Address of the underlying Plasma Vault that this wrapper will interact with
     * @custom:oz-upgrades-unsafe-allow constructor
     */
    constructor(address asset_, string memory name_, string memory symbol_, address plasmaVault_) initializer {
        if (plasmaVault_ == address(0)) revert ZeroPlasmaVaultAddress();
        if (asset_ == address(0)) revert ZeroAssetAddress();

        __ERC4626_init(IERC20(asset_));
        __ERC20_init(name_, symbol_);
        __Ownable_init(msg.sender);

        PLASMA_VAULT = plasmaVault_;
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

        uint256 shares = previewDeposit(assets_);
        if (shares == 0) revert ZeroSharesMint();

        _calculateFees();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets_);

        IERC20(asset()).forceApprove(PLASMA_VAULT, assets_);

        ERC4626Upgradeable(PLASMA_VAULT).deposit(assets_, address(this));

        _mint(receiver_, shares);

        emit Deposit(msg.sender, receiver_, assets_, shares);

        lastTotalAssets = totalAssets();
        return shares;
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

        uint256 assets = previewMint(shares_);
        if (assets == 0) revert ZeroAssetsDeposit();

        _calculateFees();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        IERC20(asset()).forceApprove(PLASMA_VAULT, assets);
        ERC4626Upgradeable(PLASMA_VAULT).deposit(assets, address(this));

        _mint(receiver_, shares_);

        emit Deposit(msg.sender, receiver_, assets, shares_);

        lastTotalAssets = totalAssets();

        return assets;
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

        uint256 shares = previewWithdraw(assets_);

        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }

        _calculateFees();

        _burn(owner_, shares);

        ERC4626Upgradeable(PLASMA_VAULT).withdraw(assets_, receiver_, address(this));

        emit Withdraw(msg.sender, receiver_, owner_, assets_, shares);

        lastTotalAssets = totalAssets();

        return shares;
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

        uint256 assets = previewRedeem(shares_);
        if (assets == 0) revert ZeroAssetsWithdraw();

        _calculateFees();

        _burn(owner_, shares_);

        ERC4626Upgradeable(PLASMA_VAULT).withdraw(assets, receiver_, address(this));

        lastTotalAssets = totalAssets();

        emit Withdraw(msg.sender, receiver_, owner_, assets, shares_);
        return assets;
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
        return ERC4626Upgradeable(PLASMA_VAULT).maxWithdraw(address(this));
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
        return _getUnrealizedManagementFee(totalAssets());
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
     * @notice Calculates the maximum amount of underlying assets that can be withdrawn for a given owner
     * @dev Computes withdrawal limit considering unrealized fees and share price adjustments
     *
     * Calculation Flow:
     * 1. Share Analysis
     *    - Retrieves owner's share balance
     *    - Calculates unrealized management fees
     *    - Determines potential performance fees
     *
     * 2. Fee Impact Assessment
     *    - Computes shares needed for management fees
     *    - Calculates performance fee if profit exists
     *    - Combines total fee impact on shares
     *
     * 3. Maximum Withdrawal Computation
     *    - Adjusts for total supply changes
     *    - Accounts for decimals offset
     *    - Applies floor rounding for safety
     *    - Ensures withdrawal precision
     *
     * Important Notes:
     * - Considers both management and performance fees
     * - Accounts for unrealized fees
     * - Uses floor rounding for safety
     * - Includes precision adjustments
     *
     * @param owner Address of the share owner
     * @return uint256 Maximum withdrawable amount in underlying token decimals
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 shares = balanceOf(owner);
        uint256 managementFee = getUnrealizedManagementFee();

        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = PlasmaVaultLib.getPerformanceFeeData();

        uint256 totalAssetsNow = totalAssets();

        uint256 performanceFee = totalAssetsNow > lastTotalAssets
            ? Math.mulDiv(totalAssetsNow - lastTotalAssets, feeData.feeInPercentage, FEE_PERCENTAGE_DECIMALS_MULTIPLIER)
            : 0;

        uint256 sharesFromFees = convertToShares(managementFee + performanceFee);
        return
            shares.mulDiv(
                totalAssets() + 1,
                totalSupply() + sharesFromFees + 10 ** _decimalsOffset(),
                Math.Rounding.Floor
            );
    }

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
                Math.mulDiv(totalAssets_, blockTimestamp - feeData.lastUpdateTimestamp, 365 days),
                feeData.feeInPercentage,
                FEE_PERCENTAGE_DECIMALS_MULTIPLIER /// @dev feeInPercentage uses 2 decimal places, example 10000 = 100%
            );
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

    function _addPerformanceFee(uint256 totalAssetsBefore_) internal {
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
    }

    function _calculateFees() internal {
        _realizeManagementFee();
        _addPerformanceFee(lastTotalAssets);
    }

    /**
     * @notice Returns the decimals offset for the vault
     * @return Decimals offset
     */
    function _decimalsOffset() internal view override returns (uint8) {
        return 2;
    }
}
