// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IDistributor} from "./ext/IDistributor.sol";

/**
 * @title MerklClaimWrapperFuse
 * @notice A fuse for claiming self-unwrapping Merkl rewards, where the claimed token (a wrapper)
 *         unwraps on transfer into one or more different "received" tokens.
 * @dev Unlike MerklClaimFuse, the balance delta is measured on the caller-supplied receivedTokens_
 *      (the final tokens that actually land on the vault), not on the claimed wrapper tokens.
 *      Every received token with a positive delta is always forwarded to the RewardsClaimManager,
 *      so unwrapped tokens never linger on the vault (which would otherwise inflate share price
 *      if the token is a market substrate). Each received token must be granted as a
 *      substrate-as-asset on MARKET_ID, so the caller cannot forward an arbitrary token.
 */
contract MerklClaimWrapperFuse {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when an unwrapped reward token is forwarded to the RewardsClaimManager
     * @param version Address of this contract instance
     * @param receivedToken Address of the token actually received by the vault after unwrapping
     * @param receivedTokenAmount Amount of received token forwarded
     * @param rewardsClaimManager Address of the RewardsClaimManager receiving the rewards
     */
    event MerklClaimWrapperFuseRewardsClaimed(
        address version, address receivedToken, uint256 receivedTokenAmount, address rewardsClaimManager
    );

    /**
     * @notice Thrown when the RewardsClaimManager address is zero
     * @param version Address of this contract instance
     */
    error MerklClaimWrapperFuseRewardsClaimManagerZeroAddress(address version);

    /**
     * @notice Thrown when the Distributor address is zero
     * @param version Address of this contract instance
     */
    error MerklClaimWrapperFuseDistributorZeroAddress(address version);

    /**
     * @notice Thrown when the claim input arrays (tokens, amounts, proofs) have mismatched lengths
     * @param version Address of this contract instance
     */
    error MerklClaimWrapperFuseInvalidInputLengths(address version);

    /**
     * @notice Thrown when a received token is not granted as a substrate-as-asset on this market
     * @param receivedToken Address of the received token that is not allowed
     */
    error MerklClaimWrapperFuseUnsupportedReceivedToken(address receivedToken);

    /// @notice The address of this contract instance, used for version tracking
    address public immutable VERSION;

    /// @notice The address of the Merkl Distributor contract
    address public immutable DISTRIBUTOR;

    /// @notice The market ID whose granted substrates-as-assets define the allowed received tokens
    uint256 public immutable MARKET_ID;

    /**
     * @notice Constructs a new MerklClaimWrapperFuse instance
     * @param marketId_ The market ID whose granted substrates-as-assets gate the received tokens
     * @param distributor_ The address of the Merkl Distributor contract
     */
    constructor(uint256 marketId_, address distributor_) {
        if (distributor_ == address(0)) {
            revert MerklClaimWrapperFuseDistributorZeroAddress(address(this));
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        DISTRIBUTOR = distributor_;
    }

    /**
     * @notice Claims self-unwrapping rewards from Merkl and forwards the unwrapped tokens
     *         to the RewardsClaimManager
     * @param tokens_ Array of claimed (wrapper) token addresses, passed to Distributor.claim
     * @param amounts_ Array of claimable amounts for each claimed token
     * @param proofs_ Array of merkle proofs for each claimed token
     * @param receivedTokens_ Array of final token addresses that land on the vault after
     *        unwrapping; the balance delta of each is measured and forwarded
     */
    function claim(
        address[] calldata tokens_,
        uint256[] calldata amounts_,
        bytes32[][] calldata proofs_,
        address[] calldata receivedTokens_
    ) external {
        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert MerklClaimWrapperFuseRewardsClaimManagerZeroAddress(VERSION);
        }

        if (tokens_.length != amounts_.length || tokens_.length != proofs_.length) {
            revert MerklClaimWrapperFuseInvalidInputLengths(VERSION);
        }

        _claimRewards(tokens_, amounts_, proofs_, receivedTokens_, rewardsClaimManager);
    }

    /**
     * @notice Internal function to handle the actual claiming logic
     * @param tokens_ Array of claimed (wrapper) token addresses
     * @param amounts_ Array of claimable amounts for each claimed token
     * @param proofs_ Array of merkle proofs for each claimed token
     * @param receivedTokens_ Array of final token addresses to measure and forward
     * @param rewardsClaimManager_ Address of the rewards claim manager
     */
    function _claimRewards(
        address[] calldata tokens_,
        uint256[] calldata amounts_,
        bytes32[][] calldata proofs_,
        address[] calldata receivedTokens_,
        address rewardsClaimManager_
    ) internal {
        // Record balances of the RECEIVED tokens before claiming
        uint256[] memory balancesBefore = _snapshotBalances(receivedTokens_);

        // Build users array and call Distributor
        _callDistributor(tokens_, amounts_, proofs_);

        // Forward the delta of each received token to the rewards claim manager
        uint256 receivedLength = receivedTokens_.length;
        for (uint256 i; i < receivedLength; ++i) {
            _forwardReceivedToken(receivedTokens_[i], balancesBefore[i], rewardsClaimManager_);
        }
    }

    /**
     * @notice Validates and snapshots the current balances of the given received tokens
     * @dev Each token must be granted as a substrate-as-asset on MARKET_ID; validating before the
     *      claim makes an unsupported token revert deterministically, independent of its delta.
     * @param tokens_ Array of received token addresses to validate and snapshot
     * @return balances Array of current balances
     */
    function _snapshotBalances(address[] calldata tokens_) internal view returns (uint256[] memory balances) {
        uint256 length = tokens_.length;
        balances = new uint256[](length);
        for (uint256 i; i < length; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, tokens_[i])) {
                revert MerklClaimWrapperFuseUnsupportedReceivedToken(tokens_[i]);
            }
            balances[i] = IERC20(tokens_[i]).balanceOf(address(this));
        }
    }

    /**
     * @notice Builds the users array and calls the Merkl Distributor
     * @param tokens_ Array of claimed (wrapper) token addresses
     * @param amounts_ Array of claimable amounts for each claimed token
     * @param proofs_ Array of merkle proofs for each claimed token
     */
    function _callDistributor(address[] calldata tokens_, uint256[] calldata amounts_, bytes32[][] calldata proofs_)
        internal
    {
        uint256 tokensLength = tokens_.length;
        address[] memory users = new address[](tokensLength);
        for (uint256 i; i < tokensLength; ++i) {
            users[i] = address(this);
        }
        // Call the Merkl Distributor to claim rewards (the wrappers unwrap on transfer)
        IDistributor(DISTRIBUTOR).claim(users, tokens_, amounts_, proofs_);
    }

    /**
     * @notice Internal function to forward a single received token's delta to the rewards manager
     * @param token_ The received token address
     * @param balanceBefore_ The token balance before claiming
     * @param rewardsClaimManager_ Address of the rewards claim manager
     */
    function _forwardReceivedToken(address token_, uint256 balanceBefore_, address rewardsClaimManager_) internal {
        // Saturating subtraction: a received token may be a rebasing aToken whose balance can
        // decrease between the snapshot and this read; treat a decrease as zero delta rather than
        // reverting the whole claim batch on checked-arithmetic underflow.
        uint256 balanceAfter = IERC20(token_).balanceOf(address(this));
        uint256 receivedAmount = balanceAfter > balanceBefore_ ? balanceAfter - balanceBefore_ : 0;

        if (receivedAmount > 0) {
            IERC20(token_).safeTransfer(rewardsClaimManager_, receivedAmount);
            emit MerklClaimWrapperFuseRewardsClaimed(VERSION, token_, receivedAmount, rewardsClaimManager_);
        }
    }
}
