// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct StakeDaoV2SupplyFuseEnterData {
    /// @dev Stake DAO V2 reward vault address, with underlying asset as lp token
    /// @dev Example: Stake DAO Curve Vault for crvUSD Vault (sd-cvcrvUSD-vault) [0x1544E663DD326a6d853a0cc4ceEf0860eb82B287]
    address rewardVault;
    /// @dev amount of lp token underlying asset amount to supply,
    /// @dev Example: Curve.Fi USD Stablecoin (crvUSD) [0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5] in vault Curve Vault for crvUSD (cvcrvUSD) [0xe07f1151887b8FDC6800f737252f6b91b46b5865]
    uint256 lpTokenUnderlyingAmount;
    /// @dev minimum amount of lp token underlying asset to supply, if not enough underlying asset is supplied, the enter will revert
    uint256 minLpTokenUnderlyingAmount;
}

struct StakeDaoV2SupplyFuseExitData {
    /// @dev Stake DAO V2 reward vault address, with underlying asset as lp token
    /// @dev Example: Stake DAO Curve Vault for crvUSD Vault (sd-cvcrvUSD-vault) [0x1544E663DD326a6d853a0cc4ceEf0860eb82B287]
    address rewardVault;
    /// @dev amount of reward vault shares to withdraw,
    uint256 rewardVaultShares;
    /// @dev minimum amount of reward vault shares to withdraw,
    uint256 minRewardVaultShares;
}

contract StakeDaoV2SupplyFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event StakeDaoV2SupplyFuseEnter(
        address version,
        address rewardVault,
        uint256 rewardVaultShares,
        uint256 lpTokenAmount,
        uint256 finalLpTokenUnderlyingAmount
    );
    event StakeDaoV2SupplyFuseExit(
        address version,
        address rewardVault,
        uint256 finalRewardVaultShares,
        uint256 lpTokenAmount,
        uint256 lpTokenUnderlyingAmount
    );

    error StakeDaoV2SupplyFuseInsufficientLpTokenUnderlyingAmount(
        uint256 finalLpTokenUnderlyingAmount,
        uint256 minLpTokenUnderlyingAmount
    );
    error StakeDaoV2SupplyFuseInsufficientRewardVaultShares(
        uint256 finalRewardVaultShares,
        uint256 minRewardVaultShares
    );
    error StakeDaoV2SupplyFuseUnsupportedRewardVault(string action, address rewardVault);

    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @dev Alpha have to prepare lp token underlying asset in the vault before entering
    function enter(StakeDaoV2SupplyFuseEnterData memory data_) external {
        if (data_.lpTokenUnderlyingAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.rewardVault)) {
            revert StakeDaoV2SupplyFuseUnsupportedRewardVault("enter", data_.rewardVault);
        }

        IERC4626 rewardVault = IERC4626(data_.rewardVault);

        address lpTokenAddress = rewardVault.asset();

        address lpTokenUnderlyingAddress = IERC4626(lpTokenAddress).asset();

        address plasmaVault = address(this);

        uint256 finalLpTokenUnderlyingAmount = IporMath.min(
            ERC20(lpTokenUnderlyingAddress).balanceOf(plasmaVault),
            data_.lpTokenUnderlyingAmount
        );

        if (finalLpTokenUnderlyingAmount < data_.minLpTokenUnderlyingAmount) {
            revert StakeDaoV2SupplyFuseInsufficientLpTokenUnderlyingAmount(
                finalLpTokenUnderlyingAmount,
                data_.minLpTokenUnderlyingAmount
            );
        }

        ERC20(lpTokenUnderlyingAddress).forceApprove(lpTokenAddress, finalLpTokenUnderlyingAmount);

        uint256 lpTokenAmount = IERC4626(lpTokenAddress).deposit(finalLpTokenUnderlyingAmount, plasmaVault);

        ERC20(lpTokenAddress).forceApprove(data_.rewardVault, lpTokenAmount);

        uint256 rewardVaultShares = rewardVault.deposit(lpTokenAmount, plasmaVault);

        ERC20(lpTokenUnderlyingAddress).forceApprove(lpTokenAddress, 0);
        ERC20(lpTokenAddress).forceApprove(data_.rewardVault, 0);

        emit StakeDaoV2SupplyFuseEnter(
            VERSION,
            data_.rewardVault,
            rewardVaultShares,
            lpTokenAmount,
            finalLpTokenUnderlyingAmount
        );
    }

    function exit(StakeDaoV2SupplyFuseExitData calldata data_) external {
        if (data_.rewardVaultShares == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.rewardVault)) {
            revert StakeDaoV2SupplyFuseUnsupportedRewardVault("exit", data_.rewardVault);
        }

        address plasmaVault = address(this);

        uint256 finalRewardVaultShares = IporMath.min(
            ERC20(data_.rewardVault).balanceOf(plasmaVault),
            data_.rewardVaultShares
        );

        if (finalRewardVaultShares < data_.minRewardVaultShares) {
            revert StakeDaoV2SupplyFuseInsufficientRewardVaultShares(
                finalRewardVaultShares,
                data_.minRewardVaultShares
            );
        }

        IERC4626 rewardVault = IERC4626(data_.rewardVault);

        uint256 lpTokenAmount = rewardVault.redeem(finalRewardVaultShares, plasmaVault, plasmaVault);

        uint256 lpTokenUnderlyingAmount = IERC4626(rewardVault.asset()).redeem(lpTokenAmount, plasmaVault, plasmaVault);

        emit StakeDaoV2SupplyFuseExit(
            VERSION,
            data_.rewardVault,
            finalRewardVaultShares,
            lpTokenAmount,
            lpTokenUnderlyingAmount
        );
    }
}
