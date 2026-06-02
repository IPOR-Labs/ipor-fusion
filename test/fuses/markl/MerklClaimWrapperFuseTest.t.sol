// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MerklClaimWrapperFuse} from "../../../contracts/rewards_fuses/merkl/MerklClaimWrapperFuse.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";

// --- Base mainnet addresses ---
address constant MERKL_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;
address constant PLASMA_VAULT = 0xe883426B4fc84A7f5cc86415CAbBef43E73a4CC8;
// The vault's RewardsClaimManager is a clone (the address getRewardsClaimManagerAddress()
// returns, and the one claimRewards must be called on); 0x7924... is only the implementation.
address constant REWARDS_CLAIM_MANAGER = 0x43B4A90540CB5331C8e8423b600a8b94f535410C;
address constant ACCESS_MANAGER = 0xCC39B0A3484C41b606c93CaEC11C71F12ecfa1FF;
// Existing on-chain holder of FUSE_MANAGER_ROLE (300) for this vault; used to register the fuse
// and grant market substrates through the normal restricted entrypoints (no role minting).
address constant FUSE_MANAGER_HOLDER = 0xd556a9FA4dd83aDE79B89f4A431c57169D00D4a6;
// The vault's alpha signer (from keeper config); we grant it the claimRewards role and call
// claimRewards through the normal flow as the alpha.
address constant ALPHA = 0x48d3615d78B152819ea0367adF7b9944e399ac9a;

// Claimed wrapper token (aBascbETH wrapper) that self-unwraps on transfer.
address constant WRAPPER = 0xa1A67b55a88ab8Dcc86B765C1Cd85887e24ad7AA;
// Token actually received by the vault after the wrapper unwraps: aBascbETH, the Aave Base cbETH
// aToken (REBASING). Note it shares the "aBascbETH" symbol with the WRAPPER above.
address constant A_BAS_CB_ETH = 0xcf3D55c10DB69f28fD1A75Bd73f3D8A2d9c595ad;

uint256 constant FORK_BLOCK = 46766277;
uint256 constant CLAIM_AMOUNT = 480280871240291748;

/// @notice Fork test for a self-unwrapping Merkl reward (a wrapper that unwraps into a rebasing
///         Aave aToken on transfer): it must be forwarded in full to the RewardsClaimManager and
///         must NOT linger on the PlasmaVault. Lingering on the vault would inflate share price
///         (the aToken is a market substrate).
contract MerklClaimWrapperFuseTest is Test {
    MerklClaimWrapperFuse public fuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK);

        fuse = new MerklClaimWrapperFuse(IporFusionMarkets.MERKL, MERKL_DISTRIBUTOR);

        // Register the fuse via the existing on-chain FUSE_MANAGER_ROLE holder (no role minting).
        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);
        vm.prank(FUSE_MANAGER_HOLDER);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).addRewardFuses(fuses);

        // Grant A_BAS_CB_ETH as a substrate-as-asset on the MERKL market so the fuse may forward it.
        address[] memory granted = new address[](1);
        granted[0] = A_BAS_CB_ETH;
        _grantReceivedTokens(granted);

        // claimRewards has no active role holder on this fork, so grant its target role to the
        // vault's real alpha signer, then drive the normal flow as the alpha.
        uint64 claimRole = IAccessManager(ACCESS_MANAGER)
            .getTargetFunctionRole(REWARDS_CLAIM_MANAGER, RewardsClaimManager.claimRewards.selector);
        _grantRoleViaStorage(claimRole, ALPHA);
    }

    function testClaimWrapperForwardsUnwrappedTokenAndDoesNotInflateVault() public {
        // given
        address[] memory tokens = new address[](1);
        tokens[0] = WRAPPER;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = CLAIM_AMOUNT;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = _proof();

        address[] memory receivedTokens = new address[](1);
        receivedTokens[0] = A_BAS_CB_ETH;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(fuse),
            data: abi.encodeWithSignature(
                "claim(address[],uint256[],bytes32[][],address[])", tokens, amounts, proofs, receivedTokens
            )
        });

        uint256 rcmBefore = IERC20(A_BAS_CB_ETH).balanceOf(REWARDS_CLAIM_MANAGER);
        uint256 vaultBefore = IERC20(A_BAS_CB_ETH).balanceOf(PLASMA_VAULT);

        // when
        vm.prank(ALPHA);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);

        // then
        uint256 rcmAfter = IERC20(A_BAS_CB_ETH).balanceOf(REWARDS_CLAIM_MANAGER);
        uint256 vaultAfter = IERC20(A_BAS_CB_ETH).balanceOf(PLASMA_VAULT);

        // KEY regression assertion: the unwrapped underlying must NOT linger on the vault.
        // Tight tolerance of 1 wei accounts only for aToken rebase rounding noise.
        assertApproxEqAbs(vaultAfter, vaultBefore, 1, "Vault underlying must not grow (no share-price inflation)");

        // The fork is pinned, so the forwarded amount is deterministic: CLAIM_AMOUNT + 1 wei (the
        // aToken's rebasing balanceOf rounds the measured delta 1 wei above the transferred amount).
        assertEq(rcmAfter - rcmBefore, CLAIM_AMOUNT + 1, "Forwarded amount mismatch");
    }

    /// @notice Constructor must revert when the Distributor address is zero (covers the
    ///         constructor zero-address branch).
    function testConstructorRevertsOnZeroDistributor() public {
        // The error carries address(this) of the contract under construction. Predict that
        // CREATE address from this test contract's current nonce so we can match the full error.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(
            abi.encodeWithSelector(
                MerklClaimWrapperFuse.MerklClaimWrapperFuseDistributorZeroAddress.selector, predicted
            )
        );
        new MerklClaimWrapperFuse(IporFusionMarkets.MERKL, address(0));
    }

    /// @notice claim() must revert when the executing context has no RewardsClaimManager set
    ///         (covers the rewardsClaimManager == address(0) branch). Calling fuse.claim()
    ///         directly makes address(this)==fuse, whose ERC-7201 RCM slot is unset (zero).
    function testClaimRevertsWhenRewardsClaimManagerUnset() public {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);
        address[] memory receivedTokens = new address[](0);

        vm.expectRevert(
            abi.encodeWithSelector(
                MerklClaimWrapperFuse.MerklClaimWrapperFuseRewardsClaimManagerZeroAddress.selector, address(fuse)
            )
        );
        fuse.claim(tokens, amounts, proofs, receivedTokens);
    }

    /// @notice claim() must revert when tokens_/amounts_/proofs_ lengths mismatch (covers the
    ///         input-length validation branch). Routed through the vault context (via the
    ///         RewardsClaimManager) so the RCM-zero check passes and we reach the length check.
    function testClaimRevertsOnMismatchedInputLengths() public {
        address[] memory tokens = new address[](1);
        tokens[0] = WRAPPER;

        // amounts has length 0 while tokens has length 1 -> mismatch.
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = _proof();
        address[] memory receivedTokens = new address[](1);
        receivedTokens[0] = A_BAS_CB_ETH;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(fuse),
            data: abi.encodeWithSignature(
                "claim(address[],uint256[],bytes32[][],address[])", tokens, amounts, proofs, receivedTokens
            )
        });

        // The fuse reverts with its own error; PlasmaVault bubbles the revert data up, so we
        // assert the selector is present in the revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                MerklClaimWrapperFuse.MerklClaimWrapperFuseInvalidInputLengths.selector, address(fuse)
            )
        );
        vm.prank(ALPHA);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
    }

    /// @notice claim() must revert when a received token is not granted as a substrate-as-asset on
    ///         the MERKL market (covers the substrate-gating branch). WRAPPER is intentionally not
    ///         granted in setUp, so listing it as a received token must revert.
    function testClaimRevertsOnUnsupportedReceivedToken() public {
        address[] memory tokens = new address[](1);
        tokens[0] = WRAPPER;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = CLAIM_AMOUNT;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = _proof();

        // WRAPPER is not granted on the MERKL market -> the received-token gate must reject it.
        address[] memory receivedTokens = new address[](1);
        receivedTokens[0] = WRAPPER;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(fuse),
            data: abi.encodeWithSignature(
                "claim(address[],uint256[],bytes32[][],address[])", tokens, amounts, proofs, receivedTokens
            )
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                MerklClaimWrapperFuse.MerklClaimWrapperFuseUnsupportedReceivedToken.selector, WRAPPER
            )
        );
        vm.prank(ALPHA);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
    }

    /// @notice A received token with zero delta (one the claim does not deliver) must be a no-op:
    ///         no transfer, no event (covers the receivedAmount > 0 == false branch). Uses the
    ///         same successful claim as the happy path, with WRAPPER added as a second received
    ///         token — after unwrapping the wrapper balance is 0, so its delta is 0.
    function testZeroDeltaReceivedTokenIsNoOp() public {
        // Both received tokens must be granted (grantMarketSubstrates replaces the list, so pass
        // A_BAS_CB_ETH and WRAPPER together). WRAPPER's delta is zero after unwrap -> no-op branch.
        address[] memory granted = new address[](2);
        granted[0] = A_BAS_CB_ETH;
        granted[1] = WRAPPER;
        _grantReceivedTokens(granted);

        address[] memory tokens = new address[](1);
        tokens[0] = WRAPPER;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = CLAIM_AMOUNT;

        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = _proof();

        // Two received tokens: A_BAS_CB_ETH (positive delta) and WRAPPER (zero delta after unwrap).
        address[] memory receivedTokens = new address[](2);
        receivedTokens[0] = A_BAS_CB_ETH;
        receivedTokens[1] = WRAPPER;

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({
            fuse: address(fuse),
            data: abi.encodeWithSignature(
                "claim(address[],uint256[],bytes32[][],address[])", tokens, amounts, proofs, receivedTokens
            )
        });

        uint256 rcmWrapperBefore = IERC20(WRAPPER).balanceOf(REWARDS_CLAIM_MANAGER);
        uint256 rcmRewardBefore = IERC20(A_BAS_CB_ETH).balanceOf(REWARDS_CLAIM_MANAGER);

        vm.recordLogs();
        vm.prank(ALPHA);
        RewardsClaimManager(REWARDS_CLAIM_MANAGER).claimRewards(calls);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The zero-delta WRAPPER must not have been forwarded.
        assertEq(
            IERC20(WRAPPER).balanceOf(REWARDS_CLAIM_MANAGER), rcmWrapperBefore, "Zero-delta token must not be forwarded"
        );

        // The positive-delta token must have been forwarded to the RCM. The fork is pinned, so the
        // amount is deterministic: CLAIM_AMOUNT + 1 wei (the aToken's rebasing balanceOf rounds the
        // measured delta 1 wei above the wrapper's transferred amount).
        assertEq(
            IERC20(A_BAS_CB_ETH).balanceOf(REWARDS_CLAIM_MANAGER) - rcmRewardBefore,
            CLAIM_AMOUNT + 1,
            "Reward token forwarded amount mismatch"
        );

        // Exactly one MerklClaimWrapperFuseRewardsClaimed event (for A_BAS_CB_ETH only), proving the
        // WRAPPER (zero delta) took the no-op branch.
        bytes32 claimedTopic = MerklClaimWrapperFuse.MerklClaimWrapperFuseRewardsClaimed.selector;
        uint256 claimedEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == claimedTopic) {
                ++claimedEvents;
            }
        }
        assertEq(claimedEvents, 1, "Only the positive-delta token should emit a claimed event");
    }

    /// @dev Grants `roleId` to `account` immediately by writing the AccessManager's
    ///      _roles[roleId].members[account] Access slot. In OZ AccessManager (non-upgradeable,
    ///      as used by IporFusionAccessManager), `_roles` is the 2nd state variable => slot 1.
    ///      Access packs {uint48 since; Time.Delay delay} in one slot; writing 1 sets since=1
    ///      (a past timepoint => active now) and delay=0.
    function _grantRoleViaStorage(uint64 roleId, address account) internal {
        bytes32 roleBase = keccak256(abi.encode(roleId, uint256(1)));
        bytes32 accessSlot = keccak256(abi.encode(account, roleBase));
        vm.store(ACCESS_MANAGER, accessSlot, bytes32(uint256(1)));
        (bool ok,) = IAccessManager(ACCESS_MANAGER).hasRole(roleId, account);
        require(ok, "role grant via storage failed");
    }

    /// @dev Grants `tokens` as substrates-as-assets on the MERKL market via the existing on-chain
    ///      FUSE_MANAGER_ROLE holder (no role minting). NOTE: grantMarketSubstrates revokes the
    ///      existing list first, so callers must pass the FULL set of tokens in one call.
    function _grantReceivedTokens(address[] memory tokens) internal {
        bytes32[] memory substrates = new bytes32[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            substrates[i] = bytes32(uint256(uint160(tokens[i])));
        }
        vm.prank(FUSE_MANAGER_HOLDER);
        PlasmaVaultGovernance(PLASMA_VAULT).grantMarketSubstrates(IporFusionMarkets.MERKL, substrates);
    }

    function _proof() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](20);
        p[0] = 0x8881ed89944863e9fa4444106149b612b72d52a6fe527e9b423a0c971e56903f;
        p[1] = 0x47cc40690a04f7e483aec30fd75ba3f201f535cfdfddfb4f4f16b7765ed01fbc;
        p[2] = 0x30869b377f2897d0d381e80f1b68797f28656e4ca306b8e765f76c558505b67e;
        p[3] = 0x62d20777c8bf3688fb72868bb60ef1e24c8a99c317d5100c84cf2ae61f4c40c9;
        p[4] = 0x0fd393a7b8ed13e8ec313ab44c0f408996f14fd5d3ae42fad3fe043bf3f4a246;
        p[5] = 0x0bac710962a5711f07174c62375758cda642db0e130af21058cd8db0b296cb23;
        p[6] = 0x8ba60e3f51a6072226b0f65eb506cb82835296bf57cba1459cc80731fec7d8dd;
        p[7] = 0x40de0d9c12d8a4578649171b85aa44f1e98ffbdb56b2020bfac3f2b15e27fc97;
        p[8] = 0x23dad8d9155505c61345e33d382b2964a414191f404f0b86a94f9684b23528d1;
        p[9] = 0x9e318c333d30d9aaeb48906088febf824caad6fb3b0613d38af2d5f5e8dc7f7b;
        p[10] = 0xe6ad5d2d3a3c000792c2ce568178355b09793819bc34892dc85cadda2e17467a;
        p[11] = 0x584bb3a00cf9167d00867e88562798f024b4c1ad6f0eb89230353c45cc9d22e7;
        p[12] = 0x739c138837f9cca36fef2c9f8e827f7ef73e3885c4fdd948a2be710c8fe214b4;
        p[13] = 0xdad9299e5e627735ad13124d1ddabdf504b4d5dcce8ce1f40d6dfea6b52a261e;
        p[14] = 0x762459f1d0ff419029a8c3fc429bcb3fb73378e10cae65e84f765f348ca32be4;
        p[15] = 0x7e861a3d59aba2f9bdcb8cc9df6002ca939a5777c0734d6e53ee2b9cbe0a47da;
        p[16] = 0x4e97f332c6f947fd4a0c876916eba7bd55e7d6491484cccfccf5fa959c9bd678;
        p[17] = 0x4cb561cb4c2fb897721d536ad161997d0aadb00040d6ae4ed3316de09e56a1ca;
        p[18] = 0x41715bd59cfae1d86c8c4ecba32d39be6babb3130ef626a2fb4646d5f9b27ac2;
        p[19] = 0xb4df1dbeb127166522caaf08a4a78fcb7346ce69eb5864d4a5fbc5eaa5a1d49c;
    }
}
