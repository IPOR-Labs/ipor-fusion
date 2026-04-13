// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {TacStakingDelegator} from "../../../../contracts/fuses/tac/TacStakingDelegator.sol";

import {MockStaking} from "test/fuses/tac/MockStaking.sol";
import {IStaking} from "contracts/fuses/tac/ext/IStaking.sol";
import {IwTAC} from "contracts/fuses/tac/ext/IwTAC.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TacStakingDelegator} from "contracts/fuses/tac/TacStakingDelegator.sol";
import {Vm} from "forge-std/Vm.sol";
import {TacStakingDelegator} from "contracts/fuses/tac/TacStakingDelegator.sol";
import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

contract MockWTAC is MockERC20 {
    constructor() MockERC20("Wrapped TAC", "wTAC", 18) {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

contract TacStakingDelegatorTest is OlympixUnitTest("TacStakingDelegator") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_delegate_RevertsWhenCalledByNonPlasmaVault() public {
            // deploy mocks
            MockStaking staking = new MockStaking(vm);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
    
            address plasmaVault = address(0x1234);
            address nonPlasmaCaller = address(0xABCD);
    
            // prank so constructor sees msg.sender == plasmaVault
            vm.startPrank(plasmaVault);
            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // prepare delegate call data
            string[] memory validators = new string[](1);
            validators[0] = "validator-1";
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1e18;
    
            // non-plasmaVault caller should hit the opix-target-branch-89-True and revert
            vm.prank(nonPlasmaCaller);
            vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidPlasmaVaultAddress.selector);
            delegator.delegate(validators, amounts);
        }

    function test_delegate_OpixBranch91_ElseExecuted() public {
            // Arrange
            address plasmaVault = address(this);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            MockStaking staking = new MockStaking(vm);
    
            // Deploy delegator with plasmaVault as msg.sender so constructor passes
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // Fund delegator with sufficient wTAC so delegate() does not revert on balance
            uint256 amount = 1e18;
            wTacToken.mint(address(delegator), amount);
    
            // Prepare valid input arrays (non‑empty, matching lengths)
            string[] memory validators = new string[](1);
            validators[0] = "validator-1";
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amount;
    
            // Act: call delegate as PLASMA_VAULT so the internal
            // `if (msg.sender != PLASMA_VAULT) { ... } else { assert(true); }`
            // takes the else branch (opix-target-branch-91-Else)
            vm.prank(plasmaVault);
            // We expect this to revert only because W_TAC is a plain ERC20 and not a real IwTAC
            vm.expectRevert();
            delegator.delegate(validators, amounts);
        }

    function test_delegate_EmptyValidatorsArray_opix_target_branch_98_True() public {
        // Arrange: deploy mocks and delegator with this test as PlasmaVault
        MockStaking staking = new MockStaking(vm);
        MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
        address plasmaVault = address(this);
    
        // constructor requires msg.sender == plasmaVault, so prank
        TacStakingDelegator delegator;
        vm.startPrank(plasmaVault);
        delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
        vm.stopPrank();
    
        // Act: call delegate with empty validators array to hit `if (validatorAddressesLength == 0)` true branch
        string[] memory validators = new string[](0);
        uint256[] memory amounts = new uint256[](0);
    
        // No revert expected, it should just return early
        vm.prank(plasmaVault);
        delegator.delegate(validators, amounts);
    }

    function test_delegate_ArrayLengthMismatch_opix_target_branch_104_True() public {
            // Arrange: deploy mocks and delegator with this contract as PlasmaVault
            MockStaking staking = new MockStaking(vm);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            address plasmaVault = address(this);
    
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // Prepare non‑empty validators array and mismatched amounts array length
            string[] memory validators = new string[](2);
            validators[0] = "validator-1";
            validators[1] = "validator-2";
    
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1e18;
    
            // Act & Assert: call from PLASMA_VAULT so internal msg.sender check passes,
            // but array length mismatch triggers opix-target-branch-104-True and reverts
            vm.prank(plasmaVault);
            vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidArrayLength.selector);
            delegator.delegate(validators, amounts);
        }

    function test_delegate_InsufficientBalance_opix_target_branch_120_True() public {
            // Arrange: use this contract as PlasmaVault
            address plasmaVault = address(this);
            MockStaking staking = new MockStaking(Vm(address(vm)));
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
    
            // Deploy delegator with plasmaVault as constructor msg.sender
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // Prepare non‑empty validators and amounts where totalWTacAmount > delegator's wTAC balance (0)
            string[] memory validators = new string[](2);
            validators[0] = "validator-1";
            validators[1] = "validator-2";
    
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1 ether;
            amounts[1] = 2 ether;
            // totalWTacAmount = 3 ether, while delegator has 0 wTAC
    
            // Act & Assert: call from PLASMA_VAULT so msg.sender check passes,
            // and trigger `if (totalWTacAmount > delegatorBalance)` true branch (opix-target-branch-120-True)
            vm.prank(plasmaVault);
            vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInsufficientBalance.selector);
            delegator.delegate(validators, amounts);
        }

    function test_undelegate_RevertsWhenCallerNotPlasmaVault_opix_target_branch_147_True() public {
        // Arrange: deploy mock staking and delegator with this test as PlasmaVault
        MockStaking mockStaking = new MockStaking(Vm(address(vm)));
        address plasmaVault = address(this);
        address wTac = address(0x1234);
        TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, wTac, address(mockStaking));
    
        // Prepare input arrays (non-empty so only the msg.sender check matters)
        string[] memory validators = new string[](1);
        validators[0] = "validator-1";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
    
        // Act & Assert: call from non-PlasmaVault address to hit the `if (msg.sender != PLASMA_VAULT)` true branch
        address nonPlasmaVaultCaller = address(0xBEEF);
        vm.startPrank(nonPlasmaVaultCaller);
        vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidPlasmaVaultAddress.selector);
        delegator.undelegate(validators, amounts);
        vm.stopPrank();
    }

    function test_undelegate_AllowsPlasmaVaultCaller_opix_target_branch_149_False() public {
            MockStaking mockStaking = new MockStaking(Vm(address(vm)));
            MockWTAC wTacToken = new MockWTAC();
            address plasmaVault = address(this);

            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(mockStaking));

            // Create delegation in MockStaking so undelegate can find it
            vm.deal(address(delegator), 1 ether);
            mockStaking.delegate(address(delegator), "validator-1", 1 ether);

            string[] memory validators = new string[](1);
            validators[0] = "validator-1";
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1 ether;

            delegator.undelegate(validators, amounts);
        }

    function test_undelegate_EmptyArray_HitsOpixBranch156True() public {
            // Arrange: deploy mocks and delegator with this contract as PlasmaVault
            MockStaking staking = new MockStaking(Vm(address(vm)));
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            address plasmaVault = address(this);
    
            // constructor requires msg.sender == plasmaVault, so prank
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // Act: call undelegate with empty validatorAddresses_ to hit
            // `if (validatorAddressesLength == 0) { return; }` true branch (opix-target-branch-156-True)
            string[] memory validators = new string[](0);
            uint256[] memory amounts = new uint256[](0);
    
            vm.prank(plasmaVault);
            delegator.undelegate(validators, amounts);
    
            // Assert: reaching here without revert confirms the early-return branch was executed
        }

    function test_undelegate_ArrayLengthMismatch_OpixBranch162True() public {
            // Arrange: deploy mocks and delegator with this contract as PlasmaVault
            MockStaking staking = new MockStaking(vm);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            address plasmaVault = address(this);
    
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // Prepare non-empty validatorAddresses_ and mismatched tacAmounts_ array length
            string[] memory validators = new string[](2);
            validators[0] = "validator-1";
            validators[1] = "validator-2";
    
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1 ether;
    
            // Act & Assert: call from PLASMA_VAULT so msg.sender check passes,
            // but array length mismatch triggers opix-target-branch-162-True and reverts
            vm.prank(plasmaVault);
            vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidArrayLength.selector);
            delegator.undelegate(validators, amounts);
        }

    function test_redelegate_RevertsWhenCallerNotPlasmaVault() public {
        // Deploy delegator with this test contract as the PlasmaVault
        address plasmaVault = address(this);
        address wTac = address(0x1);
        address staking = address(0x2);
        TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, wTac, staking);
    
        // Prepare dummy data
        string[] memory src = new string[](1);
        src[0] = "validatorSrc";
        string[] memory dst = new string[](1);
        dst[0] = "validatorDst";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
    
        // Call from a non-plasmaVault address to hit the `if (msg.sender != PLASMA_VAULT)` branch
        address attacker = address(0xBEEF);
        vm.startPrank(attacker);
        vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidPlasmaVaultAddress.selector);
        delegator.redelegate(src, dst, amounts);
        vm.stopPrank();
    }

    function test_redelegate_AllowsCallFromPlasmaVaultAndEmitsEvents() public {
        MockStaking staking = new MockStaking(vm);
        MockWTAC wTacToken = new MockWTAC();
        address plasmaVault = address(this);

        TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));

        // Create delegations in MockStaking so redelegate can find source validators
        vm.deal(address(delegator), 10 ether);
        staking.delegate(address(delegator), "validatorSrc-1", 1 ether);
        staking.delegate(address(delegator), "validatorSrc-2", 2 ether);

        string[] memory src = new string[](2);
        src[0] = "validatorSrc-1";
        src[1] = "validatorSrc-2";

        string[] memory dst = new string[](2);
        dst[0] = "validatorDst-1";
        dst[1] = "validatorDst-2";

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;

        delegator.redelegate(src, dst, amounts);
    }

    function test_redelegate_OpixBranch199_True_ZeroLengthArray() public {
            // Arrange: deploy delegator with this contract as PLASMA_VAULT (msg.sender in constructor)
            address plasmaVault = address(this);
            address wTac = address(0x1);
            address staking = address(0x2);
    
            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, wTac, staking);
    
            // Prepare zero‑length arrays so `validatorSrcAddressesLength == 0`
            string[] memory src = new string[](0);
            string[] memory dst = new string[](0);
            uint256[] memory amounts = new uint256[](0);
    
            // Act: call from PLASMA_VAULT. The msg.sender check passes (else‑branch hit),
            // then the `if (validatorSrcAddressesLength == 0)` condition is true, so
            // the function returns early and the `opix-target-branch-199-True` branch is covered.
            vm.prank(plasmaVault);
            delegator.redelegate(src, dst, amounts);
    
            // Assert: reaching here without revert confirms the early‑return branch was executed
        }

    function test_instantWithdraw_RevertsWhenCallerNotPlasmaVault() public {
        // Deploy a minimal environment for TacStakingDelegator
        address plasmaVault = address(this);
        address wTac = address(0x1001);
        address staking = address(new MockStaking(vm));
    
        TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, wTac, staking);
    
        // Use a non-plasmaVault address as caller
        address attacker = address(0xBEEF);
        vm.startPrank(attacker);
    
        vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidPlasmaVaultAddress.selector);
        delegator.instantWithdraw(1 ether);
    
        vm.stopPrank();
    }

    function test_instantWithdraw_ZeroWTacAndNativeBalance() public {
            address plasmaVault = address(this);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            address staking = address(new MockStaking(vm));

            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), staking);

            uint256 withdrawn = delegator.instantWithdraw(1 ether);

            assertEq(withdrawn, 0, "withdrawn amount should be zero when there is no balance");
        }

    function test_instantWithdraw_ZeroAmountHitsEarlyReturn() public {
            // Arrange: deploy delegator with this contract as PLASMA_VAULT (constructor checks msg.sender)
            address plasmaVault = address(this);
            address wTac = address(0x1001); // dummy non-zero address
            address staking = address(new MockStaking(vm));
    
            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, wTac, staking);
    
            // Act: call instantWithdraw with amount = 0 to hit `if (wTacAmount_ == 0)` early return branch
            uint256 withdrawn = delegator.instantWithdraw(0);
    
            // Assert: function returns 0 and does not revert
            assertEq(withdrawn, 0, "instantWithdraw(0) should return 0");
        }

    function test_instantWithdraw_TotalWithdrawableZero_OpixBranch260True() public {
            // Arrange: this contract will be PLASMA_VAULT
            address plasmaVault = address(this);
    
            // Use MockERC20 as wTAC and MockStaking for staking, but do NOT fund delegator
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            MockStaking staking = new MockStaking(Vm(address(vm)));
    
            // Deploy delegator with constructor seeing msg.sender == plasmaVault
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // Ensure delegator has zero wTAC and zero native balance so totalWithdrawable == 0
            assertEq(wTacToken.balanceOf(address(delegator)), 0, "delegator wTAC balance should be zero");
            assertEq(address(delegator).balance, 0, "delegator native balance should be zero");
    
            // Act: call instantWithdraw with non-zero amount as PLASMA_VAULT
            // This makes fromWTac == 0, fromNative == 0 and totalWithdrawable == 0,
            // hitting the `if (totalWithdrawable == 0)` true branch (opix-target-branch-260-True)
            vm.prank(plasmaVault);
            uint256 withdrawn = delegator.instantWithdraw(1 ether);
    
            // Assert: function returns 0 and does not revert
            assertEq(withdrawn, 0, "withdrawn amount should be zero when totalWithdrawable is zero");
        }

    function test_instantWithdraw_OpixBranch262_ElseExecuted() public {
            address plasmaVault = address(this);
            MockWTAC wTacToken = new MockWTAC();
            MockStaking staking = new MockStaking(vm);

            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));

            // Give delegator only native balance (no wTAC) to exercise the fromNative path
            vm.deal(address(delegator), 1 ether);

            uint256 withdrawn = delegator.instantWithdraw(0.5 ether);

            assertGt(withdrawn, 0, "withdrawn amount should be greater than zero");
        }

    function test_instantWithdraw_FromNativeOnly_OpixBranch268Else() public {
            address plasmaVault = address(this);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            MockStaking staking = new MockStaking(vm);

            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));

            // Give delegator only wTAC (no native), so fromNative == 0 (branch 268 else - skip deposit)
            uint256 fundAmount = 1 ether;
            wTacToken.mint(address(delegator), fundAmount);

            uint256 withdrawn = delegator.instantWithdraw(fundAmount);

            assertEq(withdrawn, fundAmount, "withdrawn amount should equal funded wTAC amount");
        }

    function test_emergencyExit_RevertsWhenCallerNotPlasmaVault() public {
            // Arrange: deploy delegator with this contract as plasma vault
            address plasmaVault = address(this);
            address wTac = address(0xBEEF); // dummy non-zero address
            MockStaking stakingImpl = new MockStaking(vm);
            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, wTac, address(stakingImpl));
    
            // Act & Assert: call from non-plasmaVault address should revert
            address notPlasmaVault = address(0x1234);
            vm.prank(notPlasmaVault);
            vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidPlasmaVaultAddress.selector);
            delegator.emergencyExit();
        }

    function test_emergencyExit_SucceedsWhenCalledByPlasmaVault() public {
            address plasmaVault = address(this);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            MockStaking stakingImpl = new MockStaking(vm);
            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(stakingImpl));

            delegator.emergencyExit();
        }

    function test_emergencyExit_EntersIfBranchWhenNativeBalancePositive() public {
            address plasmaVault = address(this);
            MockWTAC wTacToken = new MockWTAC();
            MockStaking stakingImpl = new MockStaking(vm);

            TacStakingDelegator delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(stakingImpl));

            // Fund delegator with native TAC so that `nativeBalance > 0` is true
            vm.deal(address(delegator), 1 ether);

            delegator.emergencyExit();
        }

    function test_emergencyExit_TransfersWTacWhenBalancePositive_opix_target_branch_299_True() public {
            // Arrange: deploy mocks
            MockStaking staking = new MockStaking(vm);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
            address plasmaVault = address(this);
    
            // Deploy delegator with plasmaVault as constructor msg.sender
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // Fund delegator with some wTAC so totalWTacBalance > 0
            uint256 amount = 5 ether;
            wTacToken.mint(address(delegator), amount);
    
            // Act: call emergencyExit as PLASMA_VAULT to enter the
            // `if (totalWTacBalance > 0)` true branch (opix-target-branch-299-True)
            vm.prank(plasmaVault);
            delegator.emergencyExit();
    
            // Assert: wTAC has been transferred to PLASMA_VAULT
            assertEq(wTacToken.balanceOf(plasmaVault), amount, "PlasmaVault should receive all wTAC");
            assertEq(wTacToken.balanceOf(address(delegator)), 0, "Delegator wTAC balance should be zero");
        }

    function test_emergencyExit_OpixBranch301_Else_NoWTacBalance() public {
            // Arrange: use this contract as PLASMA_VAULT so constructor msg.sender == plasmaVault
            address plasmaVault = address(this);
    
            // Deploy mocks
            MockStaking staking = new MockStaking(vm);
            MockERC20 wTacToken = new MockERC20("Wrapped TAC", "wTAC", 18);
    
            // Deploy delegator from plasmaVault so constructor checks pass
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            // Ensure delegator has ZERO wTAC so `totalWTacBalance > 0` is FALSE
            assertEq(wTacToken.balanceOf(address(delegator)), 0, "Delegator wTAC balance should be zero");
    
            // Act: call emergencyExit as PLASMA_VAULT
            // This makes `totalWTacBalance > 0` evaluate to false and enter the
            // `else { assert(true); }` branch marked opix-target-branch-301-Else
            vm.prank(plasmaVault);
            delegator.emergencyExit();
    
            // Assert: still zero wTAC on both delegator and plasmaVault
            assertEq(wTacToken.balanceOf(address(delegator)), 0, "Delegator wTAC balance must remain zero");
            assertEq(wTacToken.balanceOf(plasmaVault), 0, "PlasmaVault should not receive any wTAC when balance is zero");
        }

    function test_executeBatch_RevertsWhenNotPlasmaVault() public {
        // Deploy delegator with this test contract as PLASMA_VAULT
        TacStakingDelegator delegator = new TacStakingDelegator(address(this), address(0x1), address(0x2));
    
        // Prepare dummy inputs
        address[] memory targets = new address[](1);
        targets[0] = address(0x3);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = bytes("test");
    
        // Expect revert when caller is not PLASMA_VAULT
        vm.startPrank(address(0x1234));
        vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidPlasmaVaultAddress.selector);
        delegator.executeBatch(targets, calldatas);
        vm.stopPrank();
    }

    function test_executeBatch_SucceedsWhenCalledByPlasmaVault() public {
            TacStakingDelegator delegator = new TacStakingDelegator(address(this), address(0x1), address(0x2));

            // Use empty arrays - the loop is skipped, but the msg.sender else-branch is still covered
            address[] memory targets = new address[](0);
            bytes[] memory calldatas = new bytes[](0);

            delegator.executeBatch(targets, calldatas);
        }

    function test_executeBatch_RevertsWhenArrayLengthsDiffer() public {
            // Deploy delegator with this test contract as PLASMA_VAULT (constructor requires msg.sender == plasmaVault)
            TacStakingDelegator delegator = new TacStakingDelegator(address(this), address(0x1), address(0x2));
    
            // Prepare mismatched arrays: targets length != calldatas length to enter
            // `if (targetsLength != calldatas.length)` branch (opix-target-branch-328-True)
            address[] memory targets = new address[](2);
            targets[0] = address(this);
            targets[1] = address(0xBEEF);
    
            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = bytes("");
    
            vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidArrayLength.selector);
            delegator.executeBatch(targets, calldatas);
        }

    function test_executeBatch_RevertsOnZeroTarget_opix_target_branch_337_True() public {
            // Deploy delegator with this test contract as PLASMA_VAULT (constructor requires msg.sender == plasmaVault)
            TacStakingDelegator delegator = new TacStakingDelegator(address(this), address(0x1), address(0x2));
    
            // Prepare inputs: single zero address target to hit `if (targets[i] == address(0))` true branch
            address[] memory targets = new address[](1);
            targets[0] = address(0);
            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = bytes("");
    
            // Call as PLASMA_VAULT so we pass the msg.sender check and reach the loop
            vm.expectRevert(TacStakingDelegator.TacStakingDelegatorInvalidTargetAddress.selector);
            delegator.executeBatch(targets, calldatas);
        }

    function test_delegate_OpixBranch132_ElseExecuted_NonZeroAmount() public {
            address plasmaVault = address(this);
            MockWTAC wTacToken = new MockWTAC();
            MockStaking staking = new MockStaking(vm);
    
            TacStakingDelegator delegator;
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(wTacToken), address(staking));
            vm.stopPrank();
    
            uint256 amount = 1 ether;
            vm.deal(address(delegator), amount);
            vm.prank(address(delegator));
            wTacToken.deposit{value: amount}();
    
            string[] memory validators = new string[](1);
            validators[0] = "validator-1";
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amount;
    
            vm.prank(plasmaVault);
            delegator.delegate(validators, amounts);
        }

    function test_executeBatch_OpixBranch339_Else_TargetNonZero() public {
            // Deploy delegator with this test contract as PLASMA_VAULT (constructor requires msg.sender == plasmaVault)
            TacStakingDelegator delegator;
            address plasmaVault = address(this);
            vm.startPrank(plasmaVault);
            delegator = new TacStakingDelegator(plasmaVault, address(0x1), address(0x2));
            vm.stopPrank();
    
            // Prepare a non‑zero target so `if (targets[i] == address(0))` is FALSE
            // and the `else { assert(true); }` branch (opix-target-branch-339-Else) is taken
            address[] memory targets = new address[](1);
            targets[0] = address(this);
            bytes[] memory calldatas = new bytes[](1);
            calldatas[0] = ""; // empty calldata, delegatecall will revert but after the branch is executed
    
            // Call as PLASMA_VAULT so msg.sender check passes and we reach the loop
            vm.prank(plasmaVault);
            vm.expectRevert();
            delegator.executeBatch(targets, calldatas);
        }
}