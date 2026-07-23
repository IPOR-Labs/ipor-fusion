// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RewardsRouter} from "../../contracts/managers/rewards/RewardsRouter.sol";
import {IRewardsRouter} from "../../contracts/interfaces/IRewardsRouter.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {RewardsRouterE2EReplayData as Data} from "./RewardsRouterE2EReplayData.sol";

interface IVaultLike {
    function totalAssets() external view returns (uint256);

    function getAccessManagerAddress() external view returns (address);

    function getRewardsClaimManagerAddress() external view returns (address);
}

interface IAccessManagerLike {
    function hasRole(uint64 roleId, address account) external view returns (bool isMember, uint32 executionDelay);
}

/// @title RewardsRouterE2EReplayTest
/// @notice Fork e2e (IL-7636): replays the EXACT live Base "Base ETH Lending Optimizer" alpha rewards
/// sequence — 10 separate keeper transactions at blocks 47455848..47455893 — but as a SINGLE
/// `RewardsRouter.execute()` batch, proving the router collapses the multi-tx keeper dance
/// into one atomic transaction.
///
/// Original on-chain sequence (alpha EOA 0x64f6…cf80c, tokens flowing through the EOA):
///   1. RewardsClaimManager.claimRewards  -> Merkl claim of USDC (1,574,060,115) + 0x91A9ED ERC4626 (376,691,315)
///   2. RewardsClaimManager.transfer(USDC,   alpha, 1,574,060,115)
///   3. RewardsClaimManager.transfer(0x91A9ED, alpha, 376,691,315)
///   4. 0x91A9ED.redeem(376,691,315, alpha, alpha)            -> USDC (~376,949,202)
///   5. USDC.approve(AugustusV6, 1,574,060,115)
///   6. AugustusV6.swapExactAmountIn  USDC->WETH (1,574,060,115)
///   7. USDC.approve(AugustusV6, 376,949,202)
///   8. AugustusV6.swapExactAmountIn  USDC->WETH (376,949,202)
///   9. WETH.transfer(RewardsClaimManager, ~1.109e18)
///  10. RewardsClaimManager.updateBalance()
///
/// In the replay the EXECUTOR takes the place of the alpha EOA as the intermediary. The whole flow
/// requires ONLY the three rewards roles (CLAIM_REWARDS, TRANSFER_REWARDS, UPDATE_REWARDS_BALANCE) on
/// the router plus generic token/swap calls — NO ALPHA_ROLE and NO PlasmaVault.execute — which is
/// exactly the minimal-privilege model asserted in AUDIT_IL-7636.md (F-1).
///
/// @dev Requires an ARCHIVE Base RPC in `BASE_PROVIDER_URL` (forks a ~2-day-old block). Run with:
///   BASE_PROVIDER_URL=<archive-rpc> forge test --match-contract RewardsRouterE2EReplayTest -vvv
contract RewardsRouterE2EReplayTest is Test {
    // ---- live Base deployment (Base ETH Lending Optimizer) ----
    address internal constant VAULT = 0x17d0f109EE895bAD0b68AA104AA72bd0b003AD8E;
    address internal constant ACCESS_MANAGER = 0x95BFDe6B00F9c35dc935ED1db98c4351D38902D0;
    address internal constant REWARDS_MANAGER = 0x97A2a2269b59DE51dB8BFA139a4103bd6Df5C118;
    address internal constant ALPHA = 0x64f648962293099B1e8A1f2728Be116a7D4cF80c;

    // ---- tokens ----
    address internal constant WETH = 0x4200000000000000000000000000000000000006; // vault underlying
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant REWARD_4626 = 0x91A9ED5d4368499B1fE41f721aB13e64760B3F05; // ERC4626 (asset = USDC)
    address internal constant AUGUSTUS = 0x6A000F20005980200259B80c5102003040001068; // Paraswap/Velora AugustusV6

    // ---- amounts captured from the on-chain sequence ----
    uint256 internal constant USDC_CLAIMED = 1_574_060_115; // Merkl USDC reward (swap #1 input)
    uint256 internal constant R4626_CLAIMED = 376_691_315; // Merkl 0x91A9ED reward (redeemed to USDC)
    uint256 internal constant SWAP2_USDC_IN = 376_949_202; // redeemed USDC (swap #2 input)

    // Block of the first keeper tx (claimRewards) is 47455848; fork the state right before it.
    uint256 internal constant FORK_BLOCK = 47_455_847;

    // Tiny USDC safety margin: the verbatim swaps spend fixed historical amounts, so this guards against
    // the ERC4626 redeem rounding down a hair at a different fork block. (Empirically the redeem matches
    // the on-chain output to the wei at FORK_BLOCK, so this slack is simply left untouched on the router.)
    uint256 internal constant USDC_BUFFER = 2_000_000; // 2 USDC

    RewardsRouter internal router;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK);

        router = new RewardsRouter(VAULT);
        assertEq(router.ACCESS_MANAGER(), ACCESS_MANAGER, "bound access manager");

        // Grant the router the three rewards roles (so the RewardsClaimManager accepts it as caller) and
        // the alpha keeper ALPHA_ROLE (execute's in-contract gate). Done via vm.store because the live
        // ATOMIST/ADMIN is an off-registry multisig; this writes the same role state a governance grant would.
        _grantRole(Roles.CLAIM_REWARDS_ROLE, address(router));
        _grantRole(Roles.TRANSFER_REWARDS_ROLE, address(router));
        _grantRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, address(router));
        _grantRole(Roles.ALPHA_ROLE, ALPHA);

        deal(USDC, address(router), USDC_BUFFER);
    }

    function testReplayAlphaRewardsSequenceInOneTransaction() public {
        // Sanity: the router wields ONLY the rewards roles — never alpha/atomist/admin/fuse-manager.
        _assertHasRole(Roles.CLAIM_REWARDS_ROLE, true);
        _assertHasRole(Roles.TRANSFER_REWARDS_ROLE, true);
        _assertHasRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, true);
        _assertHasRole(Roles.ALPHA_ROLE, false);
        _assertHasRole(Roles.ATOMIST_ROLE, false);
        _assertHasRole(Roles.ADMIN_ROLE, false);
        _assertHasRole(Roles.FUSE_MANAGER_ROLE, false);

        // --- Phase 1: measure the WETH the swaps yield at this fork block (steps 1..8), then roll back. ---
        // (snapshot/revertTo are the names exposed by this repo's forge-std; the newer *State aliases
        // are not available here.)
        uint256 snap = vm.snapshot();
        vm.prank(ALPHA);
        router.execute(_buildCalls(8, 0));
        uint256 wethOut = IERC20(WETH).balanceOf(address(router));
        // Fidelity vs the live txs: at this fork block the two swaps yield 1.109769e18 WETH against the
        // on-chain 1.109267e18 (+0.0045%) — the only drift is DEX price-time sensitivity (one fork block
        // vs the two later blocks the real swaps landed in); the claim/redeem amounts match to the wei.
        assertApproxEqRel(wethOut, 1_109_267_009_159_667_720, 0.01e18, "swap WETH within 1% of on-chain");
        vm.revertTo(snap);

        // --- Phase 2: the real thing — all 10 steps in ONE execute() call. ---
        uint256 rmWethBefore = IERC20(WETH).balanceOf(REWARDS_MANAGER);
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(VAULT);
        uint256 vaultTotalBefore = IVaultLike(VAULT).totalAssets();

        vm.prank(ALPHA);
        bytes[] memory results = router.execute(_buildCalls(10, wethOut));
        assertEq(results.length, 10, "all 10 calls executed");

        // The router is a pass-through: no rewards left stranded on it (bar the tiny USDC buffer).
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "no WETH left on router");
        assertEq(IERC20(REWARD_4626).balanceOf(address(router)), 0, "ERC4626 reward fully redeemed");
        assertLt(IERC20(USDC).balanceOf(address(router)), USDC_BUFFER + 1e6, "reward USDC fully swapped");

        // Conservation: every wei of swapped WETH landed in the rewards system (RM holds it for vesting,
        // updateBalance may have forwarded the already-vested slice to the vault).
        uint256 rmGain = IERC20(WETH).balanceOf(REWARDS_MANAGER) - rmWethBefore;
        uint256 vaultGain = IERC20(WETH).balanceOf(VAULT) - vaultWethBefore;
        assertEq(rmGain + vaultGain, wethOut, "all swapped WETH routed into RM + vault");

        // The rewards genuinely accrued to the vault (now or as it vests).
        assertGe(IVaultLike(VAULT).totalAssets(), vaultTotalBefore, "vault total assets did not drop");
    }

    /// @notice Diagnostic: replays the flow in segments and compares every intermediate amount to the
    /// real on-chain figures, quantifying how far a single-fork-block replay drifts from the live txs.
    function testDivergenceVsOnchainAmounts() public {
        IRewardsRouter.ExecuteCall[] memory all = _buildCalls(8, 0);

        uint256 rmUsdc0 = IERC20(USDC).balanceOf(REWARDS_MANAGER);
        uint256 rmEusdc0 = IERC20(REWARD_4626).balanceOf(REWARDS_MANAGER);

        // (1) claim
        vm.prank(ALPHA);
        router.execute(_slice(all, 0, 1));
        uint256 claimedUsdc = IERC20(USDC).balanceOf(REWARDS_MANAGER) - rmUsdc0;
        uint256 claimedEusdc = IERC20(REWARD_4626).balanceOf(REWARDS_MANAGER) - rmEusdc0;

        // (2-4) transfers + redeem the ERC4626 reward to USDC
        vm.prank(ALPHA);
        router.execute(_slice(all, 1, 4));
        uint256 redeemOut = IERC20(USDC).balanceOf(address(router)) - USDC_BUFFER - USDC_CLAIMED;

        // (5-6) approve + swap #1
        vm.prank(ALPHA);
        router.execute(_slice(all, 4, 6));

        // (7-8) approve + swap #2
        vm.prank(ALPHA);
        router.execute(_slice(all, 6, 8));
        uint256 wethTotal = IERC20(WETH).balanceOf(address(router));

        // Merkl reward amounts are fixed by the proof -> must equal the on-chain claim exactly.
        assertEq(claimedUsdc, USDC_CLAIMED, "claimed USDC == on-chain");
        assertEq(claimedEusdc, R4626_CLAIMED, "claimed eUSDC == on-chain");
        // Redeem + DEX swaps are block-sensitive -> only assert they stay in the same ballpark.
        assertApproxEqRel(redeemOut, SWAP2_USDC_IN, 0.01e18, "redeem within 1% of on-chain");
        assertApproxEqRel(wethTotal, 1_109_267_009_159_667_720, 0.02e18, "total WETH within 2% of on-chain");
    }

    function _slice(
        IRewardsRouter.ExecuteCall[] memory all,
        uint256 from,
        uint256 to
    ) internal pure returns (IRewardsRouter.ExecuteCall[] memory out) {
        out = new IRewardsRouter.ExecuteCall[](to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = all[i];
        }
    }

    /// @notice Builds the replay batch. `count` is 8 (measurement: through swap #2) or 10 (full flow).
    /// `wethToVest` is the exact WETH amount moved to the RewardsClaimManager in step 9.
    function _buildCalls(
        uint256 count,
        uint256 wethToVest
    ) internal view returns (IRewardsRouter.ExecuteCall[] memory calls) {
        calls = new IRewardsRouter.ExecuteCall[](count);

        // 1. claim USDC + 0x91A9ED into the RewardsClaimManager (verbatim Merkl claim calldata).
        calls[0] = IRewardsRouter.ExecuteCall(REWARDS_MANAGER, Data.claimCalldata());

        // 2-3. pull both reward tokens onto the router (alpha's role: TRANSFER_REWARDS_ROLE).
        calls[1] = IRewardsRouter.ExecuteCall(
            REWARDS_MANAGER,
            abi.encodeWithSignature("transfer(address,address,uint256)", USDC, address(router), USDC_CLAIMED)
        );
        calls[2] = IRewardsRouter.ExecuteCall(
            REWARDS_MANAGER,
            abi.encodeWithSignature("transfer(address,address,uint256)", REWARD_4626, address(router), R4626_CLAIMED)
        );

        // 4. redeem the ERC4626 reward token to USDC (router now owns the shares).
        calls[3] = IRewardsRouter.ExecuteCall(
            REWARD_4626,
            abi.encodeWithSignature(
                "redeem(uint256,address,address)",
                R4626_CLAIMED,
                address(router),
                address(router)
            )
        );

        // 5-6. approve + swap the claimed USDC -> WETH (verbatim Augustus calldata).
        calls[4] = IRewardsRouter.ExecuteCall(
            USDC,
            abi.encodeWithSignature("approve(address,uint256)", AUGUSTUS, USDC_CLAIMED)
        );
        calls[5] = IRewardsRouter.ExecuteCall(AUGUSTUS, Data.swap1Calldata());

        // 7-8. approve + swap the redeemed USDC -> WETH (verbatim Augustus calldata).
        calls[6] = IRewardsRouter.ExecuteCall(
            USDC,
            abi.encodeWithSignature("approve(address,uint256)", AUGUSTUS, SWAP2_USDC_IN)
        );
        calls[7] = IRewardsRouter.ExecuteCall(AUGUSTUS, Data.swap2Calldata());

        if (count <= 8) return calls;

        // 9. push the swapped WETH back to the RewardsClaimManager.
        calls[8] = IRewardsRouter.ExecuteCall(
            WETH,
            abi.encodeWithSignature("transfer(address,uint256)", REWARDS_MANAGER, wethToVest)
        );

        // 10. vest it into the vault (alpha's role: UPDATE_REWARDS_BALANCE_ROLE).
        calls[9] = IRewardsRouter.ExecuteCall(REWARDS_MANAGER, abi.encodeWithSignature("updateBalance()"));
    }

    /*//////////////////////////////////////////////////////////////
                    AccessManager role wiring via vm.store
    //////////////////////////////////////////////////////////////*/

    // OZ AccessManager storage (confirmed via `forge inspect`): _roles @ slot 1.

    /// @dev Sets `_roles[roleId].members[account].since = 1` (granted in the past, zero delay).
    function _grantRole(uint64 roleId, address account) internal {
        bytes32 roleSlot = keccak256(abi.encode(uint256(roleId), uint256(1))); // _roles[roleId] -> members mapping
        bytes32 accessSlot = keccak256(abi.encode(account, roleSlot)); // members[account] -> Access
        vm.store(ACCESS_MANAGER, accessSlot, bytes32(uint256(1)));
    }

    function _assertHasRole(uint64 roleId, bool expected) internal view {
        (bool isMember, ) = IAccessManagerLike(ACCESS_MANAGER).hasRole(roleId, address(router));
        assertEq(isMember, expected, "unexpected router role membership");
    }

    /*//////////////////////////////////////////////////////////////
       SECURITY: no path to the vault's base capital (live vault)
    //////////////////////////////////////////////////////////////*/

    /// @notice Adversarial: with ONLY the three rewards roles, no `execute()` batch driven by ALPHA can
    /// touch the vault's base capital (its WETH / user shares) or escalate privileges on the LIVE vault.
    /// Every extraction vector reverts and the vault's accounting is byte-for-byte unchanged.
    function testRouterCannotExtractVaultBaseCapital() public {
        uint256 vaultAssetsBefore = IVaultLike(VAULT).totalAssets();
        uint256 vaultWethBefore = IERC20(WETH).balanceOf(VAULT);
        address attacker = address(0xBAD);

        // 1. Cannot drive vault fuse execution (PlasmaVault.execute needs ALPHA_ROLE; router lacks it).
        _expectExecuteReverts(VAULT, abi.encodeWithSignature("execute((address,bytes)[])", new FuseAction[](0)));

        // 2. Cannot pull the underlying out of the RewardsClaimManager (transfer hard-blocks the underlying).
        _expectExecuteReverts(
            REWARDS_MANAGER,
            abi.encodeWithSignature("transfer(address,address,uint256)", WETH, attacker, 1 ether)
        );

        // 3. Cannot pull the vault's own WETH directly (the vault never approved the router).
        _expectExecuteReverts(
            WETH,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", VAULT, attacker, 1 ether)
        );

        // 4. Cannot redeem/withdraw anyone else's shares (no share allowance to the router).
        _expectExecuteReverts(
            VAULT,
            abi.encodeWithSignature("withdraw(uint256,address,address)", 1 ether, attacker, VAULT)
        );

        // 5. Cannot claim rewards straight on the vault (PlasmaVault.claimRewards is a TECH role held by
        //    the RewardsClaimManager, not by the router — so it cannot bypass the manager).
        _expectExecuteReverts(VAULT, abi.encodeWithSignature("claimRewards((address,bytes)[])", new FuseAction[](0)));

        // 6. Cannot grant itself a privileged role (it is not the admin of any role).
        _expectExecuteReverts(
            ACCESS_MANAGER,
            abi.encodeWithSignature(
                "grantRole(uint64,address,uint32)",
                uint64(Roles.ALPHA_ROLE),
                address(router),
                uint32(0)
            )
        );

        // 7. Cannot remap a target selector to a role it already holds (setTargetFunctionRole needs ADMIN).
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("execute((address,bytes)[])"));
        _expectExecuteReverts(
            ACCESS_MANAGER,
            abi.encodeWithSignature(
                "setTargetFunctionRole(address,bytes4[],uint64)",
                VAULT,
                sels,
                uint64(Roles.CLAIM_REWARDS_ROLE)
            )
        );

        // Invariants: nothing left the vault, no privilege was gained.
        assertEq(IVaultLike(VAULT).totalAssets(), vaultAssetsBefore, "vault totalAssets unchanged");
        assertEq(IERC20(WETH).balanceOf(VAULT), vaultWethBefore, "vault WETH unchanged");
        assertEq(IERC20(WETH).balanceOf(attacker), 0, "attacker extracted nothing");
        _assertHasRole(Roles.ALPHA_ROLE, false);
        _assertHasRole(Roles.ATOMIST_ROLE, false);
        _assertHasRole(Roles.ADMIN_ROLE, false);
        _assertHasRole(Roles.FUSE_MANAGER_ROLE, false);
    }

    /// @notice The router's entire power is confined to the rewards domain: via the SAME RewardsClaimManager
    /// transfer it CAN move a non-underlying reward token (the accepted residual surface), but it can NEVER
    /// move the vault's underlying.
    function testRouterPowerIsConfinedToRewards() public {
        address recipient = address(0xC0FFEE);

        // Allowed: a non-underlying reward token sitting on the RewardsClaimManager can be moved.
        deal(USDC, REWARDS_MANAGER, 1_000e6);
        IRewardsRouter.ExecuteCall[] memory okCall = new IRewardsRouter.ExecuteCall[](1);
        okCall[0] = IRewardsRouter.ExecuteCall(
            REWARDS_MANAGER,
            abi.encodeWithSignature("transfer(address,address,uint256)", USDC, recipient, uint256(1_000e6))
        );
        vm.prank(ALPHA);
        router.execute(okCall);
        assertEq(IERC20(USDC).balanceOf(recipient), 1_000e6, "reward token is movable (accepted rewards surface)");

        // Forbidden: the very same call for the underlying (WETH) reverts, even sitting on the manager.
        deal(WETH, REWARDS_MANAGER, 1 ether);
        _expectExecuteReverts(
            REWARDS_MANAGER,
            abi.encodeWithSignature("transfer(address,address,uint256)", WETH, recipient, 1 ether)
        );
        assertEq(IERC20(WETH).balanceOf(REWARDS_MANAGER), 1 ether, "underlying is NOT movable");
    }

    /// @dev Drives one `execute([{target,data}])` batch as ALPHA and asserts the whole batch reverts.
    function _expectExecuteReverts(address target, bytes memory data) internal {
        IRewardsRouter.ExecuteCall[] memory calls = new IRewardsRouter.ExecuteCall[](1);
        calls[0] = IRewardsRouter.ExecuteCall(target, data);
        vm.prank(ALPHA);
        vm.expectRevert();
        router.execute(calls);
    }
}
