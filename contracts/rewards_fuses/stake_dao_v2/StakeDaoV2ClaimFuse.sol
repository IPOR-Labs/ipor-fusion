// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRewardVault} from "../../fuses/stake_dao_v2/ext/IRewardVault.sol";
import {IAccountant} from "../../fuses/stake_dao_v2/ext/IAccountant.sol";
import {StakeDaoV2SubstrateLib} from "../../fuses/stake_dao_v2/StakeDaoV2SubstrateLib.sol";
import {StakeDaoV2SubstrateType, StakeDaoV2Substrate} from "../../fuses/stake_dao_v2/StakeDaoV2SubstrateLib.sol";
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

        bytes[] memory harvestData;

        for (uint256 i = 0; i < rewardVaults.length; i++) {
            rewardVault = rewardVaults[i];

            accountant = IRewardVault(rewardVault).ACCOUNTANT();

            gauges = new address[](1);
            gauges[0] = IRewardVault(rewardVault).gauge();

            accountant.claim(gauges, harvestData, receiver);

            emit StakeDaoV2MainRewardsClaimed(VERSION, receiver, rewardVault, address(accountant), gauges[0]);
        }
    }

    /// Extra rewards (e.g., CVX, LDO)
    function claimExtraRewards(address[] calldata rewardVaults, address[][] calldata rewardVaultsTokens) public {
        address receiver = _getReceiver();

        _validateRewardVaultsTokens(rewardVaults, rewardVaultsTokens);

        uint256[] memory amounts;

        for (uint256 i = 0; i < rewardVaults.length; i++) {
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
        bytes32 substrate;

        for (uint256 i = 0; i < rewardVaults.length; i++) {
            substrate = StakeDaoV2SubstrateLib.substrateToBytes32(
                StakeDaoV2Substrate({
                    substrateType: StakeDaoV2SubstrateType.RewardVault,
                    substrateAddress: rewardVaults[i]
                })
            );

            if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, substrate)) {
                revert StakeDaoV2ClaimFuseRewardVaultNotGranted(rewardVaults[i]);
            }
        }
    }

    function _validateRewardVaultsTokens(
        address[] calldata rewardVaults,
        address[][] calldata rewardVaultsTokens
    ) internal view {
        if (rewardVaults.length != rewardVaultsTokens.length) {
            revert StakeDaoV2ClaimFuseArrayLengthMismatch(rewardVaults.length, rewardVaultsTokens.length);
        }

        _validateRewardVaults(rewardVaults);

        bytes32 substrate;

        for (uint256 i; i < rewardVaultsTokens.length; i++) {
            for (uint256 j; j < rewardVaultsTokens[i].length; j++) {
                substrate = StakeDaoV2SubstrateLib.substrateToBytes32(
                    StakeDaoV2Substrate({
                        substrateType: StakeDaoV2SubstrateType.ExtraRewardToken,
                        substrateAddress: rewardVaultsTokens[i][j]
                    })
                );

                if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, substrate)) {
                    revert StakeDaoV2ClaimFuseRewardVaultNotGranted(rewardVaultsTokens[i][j]);
                }
            }
        }
    }
}
