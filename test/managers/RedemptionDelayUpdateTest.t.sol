// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";

/// @notice Tests for IL-7910 - the redemption delay is mutable after vault creation and the new
/// value governs every account immediately, existing depositors included (in both directions).
/// @dev The access manager exposes setRedemptionDelay only to the TECH_PLASMA_VAULT_ROLE - governance changes
/// the delay through PlasmaVaultGovernance.setRedemptionDelay so the OWNER_ROLE timelock applies (see
/// RedemptionDelayTimelockTest). Here the PLASMA_VAULT address plays the vault and calls the setter directly.
contract RedemptionDelayUpdateTest is Test {
    uint256 private constant INITIAL_REDEMPTION_DELAY = 1 days;
    uint256 private constant BASE_TIMESTAMP = 1_700_000_000;

    /// @dev Account holding TECH_PLASMA_VAULT_ROLE, simulates the PlasmaVault calling canCallAndUpdate
    address private constant PLASMA_VAULT = address(0x999);

    address private admin = address(0x1);
    address private owner = address(0x2);
    address private atomist = address(0x3);
    address private userOne = address(0x777);
    address private userTwo = address(0x888);

    IporFusionAccessManager private accessManager;

    event RedemptionDelayUpdated(uint256 newRedemptionDelayInSeconds);
    event RedemptionDelayForAccountUpdated(address account, uint256 redemptionDelay);

    function setUp() public {
        vm.warp(BASE_TIMESTAMP);
        accessManager = new IporFusionAccessManager(admin, INITIAL_REDEMPTION_DELAY);
        vm.prank(admin);
        accessManager.initialize(_generateInitializationData());
    }

    function testShouldPlasmaVaultSetRedemptionDelayAndEmitEvent() public {
        //given
        uint256 newRedemptionDelay = 2 days;

        //when
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayUpdated(newRedemptionDelay);
        _setRedemptionDelay(newRedemptionDelay);

        //then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), newRedemptionDelay);
    }

    function testShouldPlasmaVaultSetRedemptionDelayToMaximum() public {
        //given
        uint256 maxRedemptionDelay = accessManager.MAX_REDEMPTION_DELAY_IN_SECONDS();

        //when
        _setRedemptionDelay(maxRedemptionDelay);

        //then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), maxRedemptionDelay);
    }

    function testShouldNotSetRedemptionDelayAboveMaximum() public {
        //given
        uint256 tooLongRedemptionDelay = accessManager.MAX_REDEMPTION_DELAY_IN_SECONDS() + 1;

        //when
        vm.expectRevert(abi.encodeWithSignature("TooLongRedemptionDelay(uint256)", tooLongRedemptionDelay));
        _setRedemptionDelay(tooLongRedemptionDelay);

        //then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), INITIAL_REDEMPTION_DELAY);
    }

    function testShouldNotSetRedemptionDelayWhenNotPlasmaVault() public {
        //given: the owner included - it must go through PlasmaVaultGovernance.setRedemptionDelay (timelock-capable)
        address[] memory unauthorizedCallers = new address[](4);
        unauthorizedCallers[0] = owner;
        unauthorizedCallers[1] = atomist;
        unauthorizedCallers[2] = admin;
        unauthorizedCallers[3] = address(0xdead);

        for (uint256 i; i < unauthorizedCallers.length; i++) {
            //when
            vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", unauthorizedCallers[i]));
            vm.prank(unauthorizedCallers[i]);
            accessManager.setRedemptionDelay(0);
        }

        //then
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), INITIAL_REDEMPTION_DELAY);
    }

    function testShouldConstructorRevertWhenRedemptionDelayAboveMaximum() public {
        //when
        vm.expectRevert(abi.encodeWithSignature("TooLongRedemptionDelay(uint256)", 7 days + 1));
        new IporFusionAccessManager(admin, 7 days + 1);
    }

    function testShouldEmitRedemptionDelayUpdatedOnConstruction() public {
        //when
        vm.expectEmit();
        emit RedemptionDelayUpdated(3 days);
        new IporFusionAccessManager(admin, 3 days);
    }

    function testShouldReleaseExistingDepositorWhenRedemptionDelayLoweredToZero() public {
        //given: the ticket's worked example - deposit under 1 day delay, the delay is set to 0, withdraw in the same block
        uint256 depositTimestamp = block.timestamp;
        _deposit(userOne);

        vm.expectRevert(
            abi.encodeWithSignature("AccountIsLocked(uint256)", depositTimestamp + INITIAL_REDEMPTION_DELAY)
        );
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        //when
        _setRedemptionDelay(0);

        //then: all gated operations pass immediately, without any time passing
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
        _withdrawCheck(userOne, PlasmaVault.redeem.selector);
        _withdrawCheck(userOne, PlasmaVault.transfer.selector);
        _withdrawCheck(userOne, PlasmaVault.transferFrom.selector);
    }

    function testShouldLockExistingDepositorWhenRedemptionDelayRaisedFromZero() public {
        //given: deposit made while the delay is 0 must still record the lock start
        _setRedemptionDelay(0);

        uint256 depositTimestamp = block.timestamp;
        _deposit(userOne);
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        //when
        _setRedemptionDelay(1 days);

        //then: the lock is measured from the original deposit
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTimestamp + 1 days));
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        vm.warp(depositTimestamp + 1 days);
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
    }

    function testShouldExtendLockWhenRedemptionDelayRaisedMidLock() public {
        //given
        _setRedemptionDelay(1 hours);

        uint256 depositTimestamp = block.timestamp;
        _deposit(userOne);

        vm.warp(depositTimestamp + 30 minutes);

        //when
        _setRedemptionDelay(2 hours);

        //then
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTimestamp + 2 hours));
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        vm.warp(depositTimestamp + 2 hours);
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
    }

    function testShouldRelockNoLongerLockedAccountWhenRedemptionDelayRaised() public {
        //given: account deposited under a short delay and its lock has already expired
        _setRedemptionDelay(1 hours);

        uint256 depositTimestamp = block.timestamp;
        _deposit(userOne);

        vm.warp(depositTimestamp + 90 minutes);
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        //when
        _setRedemptionDelay(3 hours);

        //then: the lock returns, measured from the account's own deposit
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTimestamp + 3 hours));
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
    }

    function testShouldUnlockMidLockWhenRedemptionDelayLoweredBelowElapsedTime() public {
        //given
        uint256 depositTimestamp = block.timestamp;
        _deposit(userOne);

        vm.warp(depositTimestamp + 2 hours);

        //when
        _setRedemptionDelay(1 hours);

        //then
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
        assertEq(accessManager.getAccountLockTime(userOne), depositTimestamp + 1 hours);
    }

    function testShouldNeverLockAccountThatNeverDeposited() public {
        //given
        _setRedemptionDelay(7 days);

        //then
        assertEq(accessManager.getAccountLockTime(userTwo), 0);
        _withdrawCheck(userTwo, PlasmaVault.withdraw.selector);
        _withdrawCheck(userTwo, PlasmaVault.redeem.selector);
        _withdrawCheck(userTwo, PlasmaVault.transfer.selector);
        _withdrawCheck(userTwo, PlasmaVault.transferFrom.selector);
    }

    function testShouldGateAllFourRestrictedSelectorsWhileLocked() public {
        //given
        uint256 depositTimestamp = block.timestamp;
        _deposit(userOne);

        bytes4[] memory gatedSelectors = new bytes4[](4);
        gatedSelectors[0] = PlasmaVault.withdraw.selector;
        gatedSelectors[1] = PlasmaVault.redeem.selector;
        gatedSelectors[2] = PlasmaVault.transfer.selector;
        gatedSelectors[3] = PlasmaVault.transferFrom.selector;

        for (uint256 i; i < gatedSelectors.length; i++) {
            //then
            vm.expectRevert(
                abi.encodeWithSignature("AccountIsLocked(uint256)", depositTimestamp + INITIAL_REDEMPTION_DELAY)
            );
            _withdrawCheck(userOne, gatedSelectors[i]);
        }
    }

    function testShouldRecordLockStartForMintAndDepositWithPermit() public {
        //given
        uint256 depositTimestamp = block.timestamp;

        //when
        vm.prank(PLASMA_VAULT);
        accessManager.canCallAndUpdate(userOne, PLASMA_VAULT, PlasmaVault.mint.selector);
        vm.prank(PLASMA_VAULT);
        accessManager.canCallAndUpdate(userTwo, PLASMA_VAULT, PlasmaVault.depositWithPermit.selector);

        //then
        assertEq(accessManager.getAccountLockTime(userOne), depositTimestamp + INITIAL_REDEMPTION_DELAY);
        assertEq(accessManager.getAccountLockTime(userTwo), depositTimestamp + INITIAL_REDEMPTION_DELAY);
    }

    function testShouldResetLockStartOnSubsequentDeposit() public {
        //given
        uint256 firstDepositTimestamp = block.timestamp;
        _deposit(userOne);

        vm.warp(firstDepositTimestamp + 12 hours);
        uint256 secondDepositTimestamp = block.timestamp;

        //when
        _deposit(userOne);

        //then
        assertEq(accessManager.getAccountLockTime(userOne), secondDepositTimestamp + INITIAL_REDEMPTION_DELAY);

        vm.warp(firstDepositTimestamp + INITIAL_REDEMPTION_DELAY);
        vm.expectRevert(
            abi.encodeWithSignature("AccountIsLocked(uint256)", secondDepositTimestamp + INITIAL_REDEMPTION_DELAY)
        );
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
    }

    function testShouldGetAccountLockTimeFollowCurrentRedemptionDelay() public {
        //given: the frontend scenario - the returned unlock time moves as soon as the delay changes
        uint256 depositTimestamp = block.timestamp;
        _deposit(userOne);

        assertEq(accessManager.getAccountLockTime(userOne), depositTimestamp + INITIAL_REDEMPTION_DELAY);

        //when/then
        _setRedemptionDelay(2 days);
        assertEq(accessManager.getAccountLockTime(userOne), depositTimestamp + 2 days);

        _setRedemptionDelay(0);
        assertEq(accessManager.getAccountLockTime(userOne), depositTimestamp);
    }

    function testShouldEmitRedemptionDelayForAccountUpdatedOnDeposit() public {
        //when/then
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayForAccountUpdated(userOne, block.timestamp + INITIAL_REDEMPTION_DELAY);
        _deposit(userOne);
    }

    function testShouldRecordLockStartAndEmitEventWhenRedemptionDelayIsZero() public {
        //given: no early return on delay == 0 anymore - the deposit is recorded so a later raise applies
        _setRedemptionDelay(0);

        //when
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayForAccountUpdated(userOne, block.timestamp);
        _deposit(userOne);

        //then
        assertEq(accessManager.getAccountLockTime(userOne), block.timestamp);
    }

    /// @dev Plays PlasmaVaultGovernance.setRedemptionDelay - the vault holds TECH_PLASMA_VAULT_ROLE
    function _setRedemptionDelay(uint256 redemptionDelayInSeconds_) private {
        vm.prank(PLASMA_VAULT);
        accessManager.setRedemptionDelay(redemptionDelayInSeconds_);
    }

    function _deposit(address account_) private {
        vm.prank(PLASMA_VAULT);
        accessManager.canCallAndUpdate(account_, PLASMA_VAULT, PlasmaVault.deposit.selector);
    }

    function _withdrawCheck(address account_, bytes4 selector_) private {
        vm.prank(PLASMA_VAULT);
        accessManager.canCallAndUpdate(account_, PLASMA_VAULT, selector_);
    }

    function _generateInitializationData() private returns (InitializationData memory) {
        DataForInitialization memory data;

        data.admins = new address[](1);
        data.admins[0] = admin;
        data.owners = new address[](1);
        data.owners[0] = owner;
        data.atomists = new address[](1);
        data.atomists[0] = atomist;
        data.iporDaos = new address[](0);
        data.alphas = new address[](0);
        data.whitelist = new address[](0);
        data.guardians = new address[](0);
        data.fuseManagers = new address[](0);
        data.claimRewards = new address[](0);
        data.transferRewardsManagers = new address[](0);
        data.configInstantWithdrawalFusesManagers = new address[](0);
        data.updateMarketsBalancesAccounts = new address[](0);
        data.updateRewardsBalanceAccounts = new address[](0);
        data.withdrawManagerRequestFeeManagers = new address[](0);
        data.withdrawManagerWithdrawFeeManagers = new address[](0);
        data.priceOracleMiddlewareManagers = new address[](0);
        data.preHooksManagers = new address[](0);

        /// @dev Dummy non-zero addresses, the initializer requires every manager address to be set
        address dummyManager = address(0x123);
        data.plasmaVaultAddress = PlasmaVaultAddress({
            plasmaVault: PLASMA_VAULT,
            accessManager: address(accessManager),
            rewardsClaimManager: dummyManager,
            withdrawManager: dummyManager,
            feeManager: dummyManager,
            contextManager: dummyManager,
            priceOracleMiddlewareManager: dummyManager
        });

        return IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(data);
    }
}
