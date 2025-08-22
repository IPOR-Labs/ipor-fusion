// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRewardVault} from "../../fuses/stake_dao_v2/ext/IRewardVault.sol";
import {IAccountant} from "../../fuses/stake_dao_v2/ext/IAccountant.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

contract StakeDaoV2ClaimFuse {
    using SafeERC20 for IERC20;

    event StakeDaoV2MainRewardsClaimed(
        address indexed version,
        address receiver,
        address rewardVault,
        address accountant,
        address gauge
    );
    event StakeDaoV2ExtraRewardsClaimed(
        address indexed version,
        address receiver,
        address rewardVault,
        address[] tokens,
        uint256[] amounts
    );
    error StakeDaoV2ClaimFuseRewardVaultNotGranted(address vault);
    error StakeDaoV2ClaimFuseArrayLengthMismatch(uint256 vaultsLength, uint256 tokensLength);
    error StakeDaoV2ClaimFuseRewardsClaimManagerNotSet();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// Main Protocol Rewards (e.g., CRV, BAL)
    function claimMainRewards(address[] calldata rewardVaults) public {
        address receiver = _getReceiver();

        _validateRewardVaults(rewardVaults);

        address[] memory gauges;
        IAccountant accountant;
        address rewardVault;
        uint256 length = rewardVaults.length;

        for (uint256 i; i < length; i++) {
            rewardVault = rewardVaults[i];

            accountant = IRewardVault(rewardVault).ACCOUNTANT();

            gauges = new address[](1);
            gauges[0] = IRewardVault(rewardVault).gauge();

            accountant.claim(gauges, new bytes[](0), receiver);

            emit StakeDaoV2MainRewardsClaimed(VERSION, receiver, rewardVault, address(accountant), gauges[0]);
        }
    }

    /// Extra rewards (e.g., CVX, LDO)
    function claimExtraRewards(address[] calldata rewardVaults, address[][] calldata rewardVaultsTokens) public {
        address receiver = _getReceiver();

        _validateRewardVaults(rewardVaults);

        uint256[] memory amounts;

        uint256 length = rewardVaults.length;

        for (uint256 i; i < length; i++) {
            amounts = IRewardVault(rewardVaults[i]).claim(rewardVaultsTokens[i], receiver);

            emit StakeDaoV2ExtraRewardsClaimed(VERSION, receiver, rewardVaults[i], rewardVaultsTokens[i], amounts);
        }
    }

    function _getReceiver() internal view returns (address receiver) {
        receiver = PlasmaVaultLib.getRewardsClaimManagerAddress();

        if (receiver == address(0)) {
            revert StakeDaoV2ClaimFuseRewardsClaimManagerNotSet();
        }

        return receiver;
    }

    function _validateRewardVaults(address[] calldata rewardVaults) internal view {
        uint256 length = rewardVaults.length;

        for (uint256 i; i < length; i++) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, rewardVaults[i])) {
                revert StakeDaoV2ClaimFuseRewardVaultNotGranted(rewardVaults[i]);
            }
        }
    }
}
