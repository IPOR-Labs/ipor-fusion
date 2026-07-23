// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {RewardsRouter} from "../../contracts/managers/rewards/RewardsRouter.sol";
import {RewardsRouterFactory} from "../../contracts/factory/RewardsRouterFactory.sol";
import {IRewardsRouter} from "../../contracts/interfaces/IRewardsRouter.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {MockToken} from "./MockToken.sol";

/// @title RewardsRouterTest
/// @notice Unit suite for the IL-7636 rewards "claim-in-one-transaction" router.
/// @dev Uses a REAL IporFusionAccessManager + REAL RewardsClaimManager (with a mock PlasmaVault) so
/// the access-control wiring — the security-critical part — is exercised end to end, no fork needed.
/// See AUDIT_IL-7636.md for the findings these tests back.
contract RewardsRouterTest is Test {
    // Local copies of the router events, so vm.expectEmit can match by signature.
    event BatchExecuted(address caller, uint256 callsCount);
    event Rescued(address asset, address to, uint256 amount);

    address private _atomist = address(0x1111);
    address private _alpha = address(0x2222);
    address private _attacker = address(0x3333);
    address private _recipient = address(0xBEEF);

    MockToken private _underlying;
    MockToken private _rewardToken;

    IporFusionAccessManager private _accessManager;
    MockVaultForRouter private _vault;
    RewardsClaimManager private _rewardsManager;
    RewardsRouter private _router;

    function setUp() public {
        _underlying = new MockToken("Underlying", "UND");
        _rewardToken = new MockToken("Reward", "RWD");

        // atomist is the AccessManager ADMIN (ADMIN_ROLE = 0); fresh manager => all role delays are 0.
        _accessManager = new IporFusionAccessManager(_atomist, 0);

        _vault = new MockVaultForRouter(address(_underlying), address(_accessManager));
        _rewardsManager = new RewardsClaimManager(address(_accessManager), address(_vault));
        _vault.setRewardsClaimManager(address(_rewardsManager));

        _router = new RewardsRouter(address(_vault));

        _wireRoles();
    }

    /// @dev Configures roles for the in-contract auth model: the alpha/keeper that drives {execute} holds
    /// ALPHA_ROLE, the router holds the three rewards roles (to drive the RewardsClaimManager), and rescue
    /// is gated on ATOMIST_ROLE. No execute/rescue selector mapping is needed — the router self-checks.
    function _wireRoles() private {
        vm.startPrank(_atomist);

        // Atomist (also the AccessManager admin) — needed for rescue's ATOMIST_ROLE check.
        _accessManager.grantRole(Roles.ATOMIST_ROLE, _atomist, 0);

        // The alpha/keeper that calls execute must hold ALPHA_ROLE (execute's in-contract gate).
        _accessManager.grantRole(Roles.ALPHA_ROLE, _alpha, 0);

        // The router must hold the rewards roles so the RewardsClaimManager accepts it as caller.
        _accessManager.grantRole(Roles.CLAIM_REWARDS_ROLE, address(_router), 0);
        _accessManager.grantRole(Roles.TRANSFER_REWARDS_ROLE, address(_router), 0);
        _accessManager.grantRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, address(_router), 0);

        // RewardsClaimManager selector -> role mapping (standard vault wiring).
        _mapManager(RewardsClaimManager.transfer.selector, Roles.TRANSFER_REWARDS_ROLE);
        _mapManager(RewardsClaimManager.claimRewards.selector, Roles.CLAIM_REWARDS_ROLE);
        _mapManager(RewardsClaimManager.updateBalance.selector, Roles.UPDATE_REWARDS_BALANCE_ROLE);
        // addRewardFuses stays behind FUSE_MANAGER_ROLE, which the router deliberately does NOT hold.
        _mapManager(RewardsClaimManager.addRewardFuses.selector, Roles.FUSE_MANAGER_ROLE);

        vm.stopPrank();
    }

    function _mapManager(bytes4 selector, uint64 role) private {
        bytes4[] memory sel = new bytes4[](1);
        sel[0] = selector;
        _accessManager.setTargetFunctionRole(address(_rewardsManager), sel, role);
    }

    function _one(
        address target,
        bytes memory data
    ) private pure returns (IRewardsRouter.ExecuteCall[] memory c) {
        c = new IRewardsRouter.ExecuteCall[](1);
        c[0] = IRewardsRouter.ExecuteCall({target: target, data: data});
    }

    /*//////////////////////////////////////////////////////////////
                          CONSTRUCTOR / FACTORY
    //////////////////////////////////////////////////////////////*/

    function testConstructorBindsImmutables() public view {
        assertEq(_router.PLASMA_VAULT(), address(_vault), "PLASMA_VAULT");
        assertEq(_router.ACCESS_MANAGER(), address(_accessManager), "ACCESS_MANAGER");
    }

    function testConstructorRevertsOnZeroVault() public {
        vm.expectRevert(RewardsRouter.ZeroAddress.selector);
        new RewardsRouter(address(0));
    }

    function testConstructorRevertsWhenVaultReturnsZeroAccessManager() public {
        MockVaultZeroAccessManager badVault = new MockVaultZeroAccessManager(address(_underlying));
        vm.expectRevert(RewardsRouter.ZeroAddress.selector);
        new RewardsRouter(address(badVault));
    }

    function testFactoryCreatesBoundRouter() public {
        RewardsRouterFactory factory = new RewardsRouterFactory();
        address created = factory.create(address(_vault));

        RewardsRouter e = RewardsRouter(payable(created));
        assertEq(e.PLASMA_VAULT(), address(_vault), "factory PLASMA_VAULT");
        assertEq(e.ACCESS_MANAGER(), address(_accessManager), "factory ACCESS_MANAGER");
    }

    function testFactoryAutoIncrementsIndex() public {
        RewardsRouterFactory factory = new RewardsRouterFactory();
        assertEq(factory.nextIndex(), 0, "next index starts at 0");

        factory.create(address(_vault));
        assertEq(factory.nextIndex(), 1, "next index after first create");

        factory.create(address(_vault));
        assertEq(factory.nextIndex(), 2, "next index after second create");
    }

    /*//////////////////////////////////////////////////////////////
                          execute — VALIDATION
    //////////////////////////////////////////////////////////////*/

    function testExecuteRevertsForNonAlpha() public {
        CallTarget t = new CallTarget();
        IRewardsRouter.ExecuteCall[] memory calls = _one(address(t), abi.encodeCall(CallTarget.ping, (1)));

        vm.prank(_attacker);
        vm.expectRevert(abi.encodeWithSelector(RewardsRouter.NotAlpha.selector, _attacker));
        _router.execute(calls);
    }

    function testExecuteRevertsOnEmptyCalls() public {
        IRewardsRouter.ExecuteCall[] memory calls = new IRewardsRouter.ExecuteCall[](0);

        vm.prank(_alpha);
        vm.expectRevert(RewardsRouter.EmptyCalls.selector);
        _router.execute(calls);
    }

    function testExecuteRevertsOnZeroTarget() public {
        IRewardsRouter.ExecuteCall[] memory calls = _one(address(0), abi.encodeCall(CallTarget.ping, (1)));

        vm.prank(_alpha);
        vm.expectRevert(abi.encodeWithSelector(RewardsRouter.ZeroTarget.selector, 0));
        _router.execute(calls);
    }

    function testExecuteRejectsNonContractTarget() public {
        address eoa = address(0xDEAD);
        IRewardsRouter.ExecuteCall[] memory calls = _one(eoa, abi.encodeCall(CallTarget.ping, (1)));

        vm.prank(_alpha);
        vm.expectRevert(abi.encodeWithSelector(Address.AddressEmptyCode.selector, eoa));
        _router.execute(calls);
    }

    function testExecuteBubblesRevertFromTarget() public {
        CallTarget t = new CallTarget();
        IRewardsRouter.ExecuteCall[] memory calls = _one(address(t), abi.encodeCall(CallTarget.boom, ()));

        vm.prank(_alpha);
        vm.expectRevert(CallTarget.Boom.selector);
        _router.execute(calls);
    }

    /*//////////////////////////////////////////////////////////////
                          execute — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function testExecuteRunsBatchInOrderAndReturnsResults() public {
        CallTarget t = new CallTarget();
        IRewardsRouter.ExecuteCall[] memory calls = new IRewardsRouter.ExecuteCall[](2);
        calls[0] = IRewardsRouter.ExecuteCall(address(t), abi.encodeCall(CallTarget.ping, (10)));
        calls[1] = IRewardsRouter.ExecuteCall(address(t), abi.encodeCall(CallTarget.ping, (21)));

        vm.prank(_alpha);
        bytes[] memory results = _router.execute(calls);

        assertEq(results.length, 2, "results length");
        assertEq(abi.decode(results[0], (uint256)), 20, "result[0] = 10*2");
        assertEq(abi.decode(results[1], (uint256)), 42, "result[1] = 21*2");
        assertEq(t.callCount(), 2, "target called twice");
        assertEq(t.lastValue(), 21, "calls executed in order");
    }

    function testExecuteEmitsEvent() public {
        CallTarget t = new CallTarget();
        IRewardsRouter.ExecuteCall[] memory calls = _one(address(t), abi.encodeCall(CallTarget.ping, (1)));

        vm.expectEmit(false, false, false, true, address(_router));
        emit BatchExecuted(_alpha, 1);

        vm.prank(_alpha);
        _router.execute(calls);
    }

    /*//////////////////////////////////////////////////////////////
       execute — SECURITY / role wiring
    //////////////////////////////////////////////////////////////*/

    /// @dev Happy-path of the intended privilege: the router CAN move a non-underlying reward token
    /// out of the RewardsClaimManager because it holds TRANSFER_REWARDS_ROLE (this is the F-2 surface).
    function testRouterCanTransferRewardTokenThroughManager() public {
        deal(address(_rewardToken), address(_rewardsManager), 1_000e18);

        IRewardsRouter.ExecuteCall[] memory calls = _one(
            address(_rewardsManager),
            abi.encodeCall(RewardsClaimManager.transfer, (address(_rewardToken), _recipient, 1_000e18))
        );

        vm.prank(_alpha);
        _router.execute(calls);

        assertEq(_rewardToken.balanceOf(_recipient), 1_000e18, "reward token delivered");
        assertEq(_rewardToken.balanceOf(address(_rewardsManager)), 0, "manager drained");
    }

    /// @dev The base capital is unreachable: transferring the underlying always reverts in the manager.
    function testRouterCannotTransferUnderlyingThroughManager() public {
        deal(address(_underlying), address(_rewardsManager), 1_000e18);

        IRewardsRouter.ExecuteCall[] memory calls = _one(
            address(_rewardsManager),
            abi.encodeCall(RewardsClaimManager.transfer, (address(_underlying), _attacker, 1_000e18))
        );

        vm.prank(_alpha);
        vm.expectRevert(RewardsClaimManager.UnableToTransferUnderlyingToken.selector);
        _router.execute(calls);

        assertEq(_underlying.balanceOf(_attacker), 0, "underlying untouched");
    }

    /// @dev Blast radius == granted roles: a manager function gated by a role the router lacks
    /// (FUSE_MANAGER_ROLE) reverts, with the router itself reported as the unauthorized caller.
    function testRouterCannotCallManagerFunctionWithoutRole() public {
        address[] memory fuses = new address[](1);
        fuses[0] = address(0xF00D);

        IRewardsRouter.ExecuteCall[] memory calls = _one(
            address(_rewardsManager),
            abi.encodeCall(RewardsClaimManager.addRewardFuses, (fuses))
        );

        vm.prank(_alpha);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(_router)));
        _router.execute(calls);
    }

    function testRouterCanCallClaimRewardsThroughManager() public {
        IRewardsRouter.ExecuteCall[] memory calls = _one(
            address(_rewardsManager),
            abi.encodeCall(RewardsClaimManager.claimRewards, (new FuseAction[](0)))
        );

        vm.prank(_alpha);
        _router.execute(calls);

        assertEq(_vault.claimRewardsCallCount(), 1, "claim routed to vault");
    }

    function testRouterCanCallUpdateBalanceThroughManager() public {
        // vestingTime == 0 => balanceOf() is the live underlying balance; updateBalance sweeps it to the vault.
        deal(address(_underlying), address(_rewardsManager), 250e18);

        IRewardsRouter.ExecuteCall[] memory calls = _one(
            address(_rewardsManager),
            abi.encodeCall(RewardsClaimManager.updateBalance, ())
        );

        vm.prank(_alpha);
        _router.execute(calls);

        assertEq(_underlying.balanceOf(address(_vault)), 250e18, "vested underlying moved to vault");
        assertEq(_underlying.balanceOf(address(_rewardsManager)), 0, "manager drained to vault");
    }

    /// @dev KEY escalation guard: ALPHA cannot reach `rescue` by self-targeting the router,
    /// because the router does not hold ATOMIST_ROLE.
    function testAlphaCannotEscalateToRescueViaExecute() public {
        deal(address(_rewardToken), address(_router), 500e18);

        IRewardsRouter.ExecuteCall[] memory calls = _one(
            address(_router),
            abi.encodeCall(RewardsRouter.rescue, (address(_rewardToken), _attacker, 500e18))
        );

        vm.prank(_alpha);
        vm.expectRevert(abi.encodeWithSelector(RewardsRouter.NotAtomist.selector, address(_router)));
        _router.execute(calls);

        assertEq(_rewardToken.balanceOf(_attacker), 0, "rescue not reachable via execute");
        assertEq(_rewardToken.balanceOf(address(_router)), 500e18, "router balance intact");
    }

    /// @dev Escalation guard: the router cannot grant itself a privileged role — it is not the admin of
    /// any role, so an ALPHA-driven execute() into AccessManager.grantRole reverts and no role is gained.
    function testRouterCannotGrantItselfPrivilegedRoleViaExecute() public {
        IRewardsRouter.ExecuteCall[] memory calls = _one(
            address(_accessManager),
            abi.encodeWithSignature(
                "grantRole(uint64,address,uint32)",
                uint64(Roles.ALPHA_ROLE),
                address(_router),
                uint32(0)
            )
        );

        vm.prank(_alpha);
        vm.expectRevert();
        _router.execute(calls);

        (bool isMember, ) = _accessManager.hasRole(Roles.ALPHA_ROLE, address(_router));
        assertFalse(isMember, "router must not be able to grant itself ALPHA_ROLE");
    }

    /// @dev Escalation guard: the router cannot re-map a function selector to a role it already holds
    /// (setTargetFunctionRole requires ADMIN_ROLE) — so it cannot, e.g., open up its own `rescue` to itself.
    function testRouterCannotRemapSelectorsViaExecute() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = RewardsRouter.rescue.selector;

        IRewardsRouter.ExecuteCall[] memory calls = _one(
            address(_accessManager),
            abi.encodeWithSignature(
                "setTargetFunctionRole(address,bytes4[],uint64)",
                address(_router),
                sels,
                uint64(Roles.CLAIM_REWARDS_ROLE)
            )
        );

        vm.prank(_alpha);
        vm.expectRevert();
        _router.execute(calls);
    }

    /*//////////////////////////////////////////////////////////////
                                rescue
    //////////////////////////////////////////////////////////////*/

    function testRescueErc20ByAtomist() public {
        deal(address(_rewardToken), address(_router), 500e18);

        vm.expectEmit(false, false, false, true, address(_router));
        emit Rescued(address(_rewardToken), _recipient, 500e18);

        vm.prank(_atomist);
        _router.rescue(address(_rewardToken), _recipient, 500e18);

        assertEq(_rewardToken.balanceOf(_recipient), 500e18, "rescued to recipient");
        assertEq(_rewardToken.balanceOf(address(_router)), 0, "router swept");
    }

    function testRescueRevertsForNonAtomist() public {
        deal(address(_rewardToken), address(_router), 1e18);

        vm.prank(_alpha);
        vm.expectRevert(abi.encodeWithSelector(RewardsRouter.NotAtomist.selector, _alpha));
        _router.rescue(address(_rewardToken), _recipient, 1e18);
    }

    function testRescueRevertsOnZeroRecipient() public {
        vm.prank(_atomist);
        vm.expectRevert(RewardsRouter.ZeroAddress.selector);
        _router.rescue(address(_rewardToken), address(0), 1e18);
    }

    function testRejectsNativeCoin() public {
        (bool ok, ) = address(_router).call{value: 1 ether}("");
        assertFalse(ok, "router must reject native coin (no receive/payable fallback)");
        assertEq(address(_router).balance, 0, "no ether held");
    }
}

/*//////////////////////////////////////////////////////////////
                            TEST DOUBLES
//////////////////////////////////////////////////////////////*/

/// @dev Minimal PlasmaVault stand-in: enough for the router constructor (governance getters) and for
/// RewardsClaimManager (asset() + claimRewards()).
contract MockVaultForRouter {
    address public asset;
    address public accessManager;
    address public rewardsClaimManager;
    uint256 public claimRewardsCallCount;

    constructor(address asset_, address accessManager_) {
        asset = asset_;
        accessManager = accessManager_;
    }

    function setRewardsClaimManager(address rewardsClaimManager_) external {
        rewardsClaimManager = rewardsClaimManager_;
    }

    function getAccessManagerAddress() external view returns (address) {
        return accessManager;
    }

    function getRewardsClaimManagerAddress() external view returns (address) {
        return rewardsClaimManager;
    }

    function claimRewards(FuseAction[] calldata) external {
        claimRewardsCallCount++;
    }
}

/// @dev Vault whose access manager resolves to zero, to exercise the constructor guard.
contract MockVaultZeroAccessManager {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }

    function getAccessManagerAddress() external pure returns (address) {
        return address(0);
    }

    function getRewardsClaimManagerAddress() external pure returns (address) {
        return address(0);
    }
}

/// @dev Generic call target for batch tests.
contract CallTarget {
    error Boom();

    uint256 public lastValue;
    uint256 public callCount;

    function ping(uint256 x) external returns (uint256) {
        callCount++;
        lastValue = x;
        return x * 2;
    }

    function boom() external pure {
        revert Boom();
    }
}
