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
/**
 * @title WPlasmaVault
 * @notice A wrapped version of PlasmaVault implementing the ERC4626 standard
 * @dev This contract wraps a PlasmaVault to provide standard ERC4626 functionality
 */
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

    uint256 public lastTotalAssets;

    /**
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
     * @notice Returns the total amount of underlying assets held by the vault
     * @return Total assets
     */
    function totalAssets() public view virtual override returns (uint256) {
        return ERC4626Upgradeable(PLASMA_VAULT).maxWithdraw(address(this));
    }

    /**
     * @notice Deposits assets into the vault
     * @param assets_ Amount of assets to deposit
     * @param receiver_ Address to receive the shares
     * @return shares Amount of shares minted
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
     * @notice Mints shares to receiver by depositing assets
     * @param shares_ Amount of shares to mint
     * @param receiver_ Address to receive the shares
     * @return assets Amount of assets deposited
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
     * @notice Withdraws assets from the vault
     * @param assets_ Amount of assets to withdraw
     * @param receiver_ Address to receive the assets
     * @param owner_ Owner of the shares
     * @return shares Amount of shares burned
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
     * @notice Redeems shares for assets
     * @param shares_ Amount of shares to redeem
     * @param receiver_ Address to receive the assets
     * @param owner_ Owner of the shares
     * @return assets Amount of assets redeemed
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
     * @notice Returns the decimals offset for the vault
     * @return Decimals offset
     */
    function _decimalsOffset() internal view override returns (uint8) {
        return 2;
    }

    function getUnrealizedManagementFee() public view returns (uint256) {
        return _getUnrealizedManagementFee(totalAssets());
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

    function getPerformanceFeeData() external view returns (PlasmaVaultStorageLib.PerformanceFeeData memory feeData) {
        feeData = PlasmaVaultLib.getPerformanceFeeData();
    }

    function getManagementFeeData() external view returns (PlasmaVaultStorageLib.ManagementFeeData memory feeData) {
        feeData = PlasmaVaultLib.getManagementFeeData();
    }

    function _calculateFees() internal {
        _realizeManagementFee();
        _addPerformanceFee(lastTotalAssets);
    }

    function configureManagementFee(address feeAccount_, uint256 feeInPercentage_) external onlyOwner {
        PlasmaVaultLib.configureManagementFee(feeAccount_, feeInPercentage_);
    }

    function configurePerformanceFee(address feeAccount_, uint256 feeInPercentage_) external onlyOwner {
        PlasmaVaultLib.configurePerformanceFee(feeAccount_, feeInPercentage_);
    }

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
}
