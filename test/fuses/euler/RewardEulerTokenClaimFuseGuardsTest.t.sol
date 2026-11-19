// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultLib} from "../../../contracts/libraries/PlasmaVaultLib.sol";
import {
    RewardEulerTokenClaimFuse,
    ClaimData
} from "../../../contracts/rewards_fuses/euler/RewardEulerTokenClaimFuse.sol";

contract GuardsMockEul is ERC20 {
    constructor() ERC20("EUL", "EUL") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function burn(address from_, uint256 amount_) external {
        _burn(from_, amount_);
    }
}

/// @dev rEUL stand-in: pays `payout` EUL to the account, or burns `drain` EUL from it when `drain` is set.
contract GuardsMockREul {
    GuardsMockEul public immutable eul;
    uint256 public payout;
    uint256 public drain;

    constructor(GuardsMockEul eul_) {
        eul = eul_;
    }

    function configure(uint256 payout_, uint256 drain_) external {
        payout = payout_;
        drain = drain_;
    }

    function withdrawToByLockTimestamps(address account_, uint256[] memory, bool) external returns (bool) {
        if (drain > 0) {
            eul.burn(account_, drain);
        } else {
            eul.mint(account_, payout);
        }
        return true;
    }
}

/// @dev Plays the PlasmaVault: delegatecalls the fuse so the manager address is read from this contract's storage.
contract GuardsFuseHost {
    function setRewardsClaimManager(address manager_) external {
        PlasmaVaultLib.setRewardsClaimManagerAddress(manager_);
    }

    function execute(address fuse_, bytes memory data_) external {
        (bool success, bytes memory result) = fuse_.delegatecall(data_);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

contract RewardEulerTokenClaimFuseGuardsTest is Test {
    event RewardEulerTokenClaimFuseClaimed(address rewardsClaimManager, uint256 eulerRewardsManagerBalance);

    address private constant MANAGER = address(0xBEEF);

    GuardsMockEul private _eul;
    GuardsMockREul private _rEul;
    GuardsFuseHost private _host;
    RewardEulerTokenClaimFuse private _fuse;

    function setUp() public {
        _eul = new GuardsMockEul();
        _rEul = new GuardsMockREul(_eul);
        _host = new GuardsFuseHost();
        _fuse = new RewardEulerTokenClaimFuse(address(_rEul), address(_eul));
    }

    function _claimData() private pure returns (ClaimData memory) {
        return ClaimData({lockTimestamps: new uint256[](1), allowRemainderLoss: true});
    }

    function testShouldRevertWhenREulIsZeroAddress() public {
        vm.expectRevert(RewardEulerTokenClaimFuse.RewardEulerTokenClaimFuseInvalidAddress.selector);
        new RewardEulerTokenClaimFuse(address(0), address(_eul));
    }

    function testShouldRevertWhenEulIsZeroAddress() public {
        vm.expectRevert(RewardEulerTokenClaimFuse.RewardEulerTokenClaimFuseInvalidAddress.selector);
        new RewardEulerTokenClaimFuse(address(_rEul), address(0));
    }

    function testShouldRevertWhenRewardsClaimManagerNotSet() public {
        // given - the host storage holds no rewards claim manager
        bytes memory data = abi.encodeWithSelector(RewardEulerTokenClaimFuse.claim.selector, _claimData());

        // when / then
        vm.expectRevert(RewardEulerTokenClaimFuse.RewardEulerTokenClaimFuseRewardsClaimManagerNotSet.selector);
        _host.execute(address(_fuse), data);
    }

    function testShouldEmitClaimedWithReceivedDeltaNotBalanceAfter() public {
        // given - the manager already holds EUL, so the event must carry the delta and not the balance after
        _host.setRewardsClaimManager(MANAGER);
        _eul.mint(MANAGER, 1_000e18);
        _rEul.configure(250e18, 0);

        // when / then
        vm.expectEmit(true, true, true, true, address(_host));
        emit RewardEulerTokenClaimFuseClaimed(MANAGER, 250e18);
        _host.execute(address(_fuse), abi.encodeWithSelector(RewardEulerTokenClaimFuse.claim.selector, _claimData()));

        assertEq(_eul.balanceOf(MANAGER), 1_250e18, "manager should receive the claimed EUL");
    }

    function testShouldRevertWhenManagerBalanceDecreasesDuringClaim() public {
        // given
        _host.setRewardsClaimManager(MANAGER);
        _eul.mint(MANAGER, 1_000e18);
        _rEul.configure(0, 1e18);

        // when / then
        vm.expectRevert(RewardEulerTokenClaimFuse.RewardEulerTokenClaimFuseInvalidBalanceAfter.selector);
        _host.execute(address(_fuse), abi.encodeWithSelector(RewardEulerTokenClaimFuse.claim.selector, _claimData()));
    }
}
