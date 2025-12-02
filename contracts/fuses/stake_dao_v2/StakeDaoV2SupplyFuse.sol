// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
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

contract StakeDaoV2SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
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
    event StakeDaoV2SupplyFuseExitFailed(
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

    /// @notice Supplies assets to Stake DAO V2 reward vault
    /// @dev Alpha have to prepare lp token underlying asset in the vault before entering
    /// @param data_ Struct containing reward vault address, lp token underlying amount, and minimum amount
    /// @return rewardVault Reward vault address
    /// @return rewardVaultShares Amount of reward vault shares received
    /// @return lpTokenAmount Amount of lp tokens deposited
    /// @return finalLpTokenUnderlyingAmount Final amount of lp token underlying asset supplied
    function enter(
        StakeDaoV2SupplyFuseEnterData memory data_
    )
        public
        returns (
            address rewardVault,
            uint256 rewardVaultShares,
            uint256 lpTokenAmount,
            uint256 finalLpTokenUnderlyingAmount
        )
    {
        if (data_.lpTokenUnderlyingAmount == 0) {
            return (address(0), 0, 0, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.rewardVault)) {
            revert StakeDaoV2SupplyFuseUnsupportedRewardVault("enter", data_.rewardVault);
        }

        IERC4626 rewardVaultContract = IERC4626(data_.rewardVault);

        address lpTokenAddress = rewardVaultContract.asset();

        address lpTokenUnderlyingAddress = IERC4626(lpTokenAddress).asset();

        address plasmaVault = address(this);

        finalLpTokenUnderlyingAmount = IporMath.min(
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

        lpTokenAmount = IERC4626(lpTokenAddress).deposit(finalLpTokenUnderlyingAmount, plasmaVault);

        ERC20(lpTokenAddress).forceApprove(data_.rewardVault, lpTokenAmount);

        rewardVaultShares = rewardVaultContract.deposit(lpTokenAmount, plasmaVault);

        ERC20(lpTokenUnderlyingAddress).forceApprove(lpTokenAddress, 0);
        ERC20(lpTokenAddress).forceApprove(data_.rewardVault, 0);

        rewardVault = data_.rewardVault;

        emit StakeDaoV2SupplyFuseEnter(
            VERSION,
            rewardVault,
            rewardVaultShares,
            lpTokenAmount,
            finalLpTokenUnderlyingAmount
        );
    }

    /// @notice Exits the Stake DAO V2 reward vault
    /// @param data_ Struct containing reward vault address, reward vault shares, and minimum shares
    /// @return rewardVault Reward vault address
    /// @return finalRewardVaultShares Final amount of reward vault shares withdrawn
    /// @return lpTokenAmount Amount of lp tokens received
    /// @return lpTokenUnderlyingAmount Amount of lp token underlying asset received
    function exit(
        StakeDaoV2SupplyFuseExitData memory data_
    )
        public
        returns (
            address rewardVault,
            uint256 finalRewardVaultShares,
            uint256 lpTokenAmount,
            uint256 lpTokenUnderlyingAmount
        )
    {
        return _exit(data_, false);
    }

    function _exit(
        StakeDaoV2SupplyFuseExitData memory data_,
        bool catchExceptions_
    )
        internal
        returns (
            address rewardVault,
            uint256 finalRewardVaultShares,
            uint256 lpTokenAmount,
            uint256 lpTokenUnderlyingAmount
        )
    {
        if (data_.rewardVaultShares == 0) {
            return (address(0), 0, 0, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.rewardVault)) {
            revert StakeDaoV2SupplyFuseUnsupportedRewardVault("exit", data_.rewardVault);
        }

        address plasmaVault = address(this);

        finalRewardVaultShares = IporMath.min(ERC20(data_.rewardVault).balanceOf(plasmaVault), data_.rewardVaultShares);

        if (finalRewardVaultShares < data_.minRewardVaultShares) {
            revert StakeDaoV2SupplyFuseInsufficientRewardVaultShares(
                finalRewardVaultShares,
                data_.minRewardVaultShares
            );
        }

        IERC4626 rewardVaultContract = IERC4626(data_.rewardVault);

        rewardVault = data_.rewardVault;

        if (catchExceptions_) {
            try rewardVaultContract.redeem(finalRewardVaultShares, plasmaVault, plasmaVault) returns (
                uint256 lpTokenAmountTemp
            ) {
                lpTokenAmount = lpTokenAmountTemp;
                try IERC4626(rewardVaultContract.asset()).redeem(lpTokenAmountTemp, plasmaVault, plasmaVault) returns (
                    uint256 lpTokenUnderlyingAmountTemp
                ) {
                    lpTokenUnderlyingAmount = lpTokenUnderlyingAmountTemp;
                } catch {
                    /// @dev if redeem failed, continue with the next step
                    emit StakeDaoV2SupplyFuseExitFailed(
                        VERSION,
                        rewardVault,
                        finalRewardVaultShares,
                        lpTokenAmount,
                        lpTokenUnderlyingAmount
                    );
                }
            } catch {
                /// @dev if redeem failed, continue with the next step
                emit StakeDaoV2SupplyFuseExitFailed(
                    VERSION,
                    rewardVault,
                    finalRewardVaultShares,
                    lpTokenAmount,
                    lpTokenUnderlyingAmount
                );
            }
        } else {
            lpTokenAmount = rewardVaultContract.redeem(finalRewardVaultShares, plasmaVault, plasmaVault);

            lpTokenUnderlyingAmount = IERC4626(rewardVaultContract.asset()).redeem(
                lpTokenAmount,
                plasmaVault,
                plasmaVault
            );
        }

        emit StakeDaoV2SupplyFuseExit(
            VERSION,
            rewardVault,
            finalRewardVaultShares,
            lpTokenAmount,
            lpTokenUnderlyingAmount
        );
    }

    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        if (amount == 0) {
            return;
        }

        IERC4626 rewardVault = IERC4626(PlasmaVaultConfigLib.bytes32ToAddress(params_[1]));

        if (address(rewardVault) == address(0)) {
            return;
        }

        uint256 sharesAsset = IERC4626(rewardVault.asset()).convertToShares(amount);
        uint256 sharesShouldRequest = rewardVault.convertToShares(sharesAsset);

        uint256 plasmaVaultBalance = rewardVault.balanceOf(address(this));

        uint256 sharesToRequest = sharesShouldRequest > plasmaVaultBalance ? plasmaVaultBalance : sharesShouldRequest;

        _exit(StakeDaoV2SupplyFuseExitData(address(rewardVault), sharesToRequest, sharesToRequest), true);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address rewardVault = TypeConversionLib.toAddress(inputs[0]);
        uint256 lpTokenUnderlyingAmount = TypeConversionLib.toUint256(inputs[1]);
        uint256 minLpTokenUnderlyingAmount = TypeConversionLib.toUint256(inputs[2]);

        (
            address returnedRewardVault,
            uint256 returnedRewardVaultShares,
            uint256 returnedLpTokenAmount,
            uint256 returnedFinalLpTokenUnderlyingAmount
        ) = enter(StakeDaoV2SupplyFuseEnterData(rewardVault, lpTokenUnderlyingAmount, minLpTokenUnderlyingAmount));

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedRewardVault);
        outputs[1] = TypeConversionLib.toBytes32(returnedRewardVaultShares);
        outputs[2] = TypeConversionLib.toBytes32(returnedLpTokenAmount);
        outputs[3] = TypeConversionLib.toBytes32(returnedFinalLpTokenUnderlyingAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address rewardVault = TypeConversionLib.toAddress(inputs[0]);
        uint256 rewardVaultShares = TypeConversionLib.toUint256(inputs[1]);
        uint256 minRewardVaultShares = TypeConversionLib.toUint256(inputs[2]);

        (
            address returnedRewardVault,
            uint256 returnedFinalRewardVaultShares,
            uint256 returnedLpTokenAmount,
            uint256 returnedLpTokenUnderlyingAmount
        ) = exit(StakeDaoV2SupplyFuseExitData(rewardVault, rewardVaultShares, minRewardVaultShares));

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedRewardVault);
        outputs[1] = TypeConversionLib.toBytes32(returnedFinalRewardVaultShares);
        outputs[2] = TypeConversionLib.toBytes32(returnedLpTokenAmount);
        outputs[3] = TypeConversionLib.toBytes32(returnedLpTokenUnderlyingAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
