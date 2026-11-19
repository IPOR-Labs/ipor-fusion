// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

/// @title EulerV2SupplyFuseEnterForkTest
/// @notice Fork test (IL-9277): EulerV2SupplyFuse.enter against the real EVC and the real Euler Prime USDC vault.
///         The test contract plays the PlasmaVault: the fuse runs through delegatecall, so substrates, balances and
///         allowances are the test contract's own. Pins the returned shares, the emitted event, the clamp to the idle
///         balance and the allowance reset after the deposit.
contract EulerV2SupplyFuseEnterForkTest is Test {
    /// @dev Own fork block (see the Euler test plan): suites sharing a fork URL and block share a backend
    uint256 private constant _FORK_BLOCK = 20990350;

    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;
    address private constant _EULER_VAULT_PRIME_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 private constant _MARKET_ID = 7_000_001;
    bytes1 private constant _SUB = bytes1(0x01);

    EulerV2SupplyFuse private _fuse;
    address private _subAccount;

    // Same declaration as in the fuse, needed for expectEmit
    event EulerV2SupplyEnterFuse(address version, address eulerVault, uint256 mintedShares, address subAccount);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), _FORK_BLOCK);

        _fuse = new EulerV2SupplyFuse(_MARKET_ID, _EVC);
        _subAccount = EulerFuseLib.generateSubAccountAddress(address(this), _SUB);

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: _EULER_VAULT_PRIME_USDC,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB
            })
        );
        PlasmaVaultConfigLib.grantMarketSubstrates(_MARKET_ID, substrates);
    }

    function testEnterReturnsSharesEmitsEventAndResetsAllowance() public {
        // given
        uint256 amount = 1_000e6;
        deal(_USDC, address(this), amount);
        uint256 expectedShares = IERC4626(_EULER_VAULT_PRIME_USDC).previewDeposit(amount);
        assertGt(expectedShares, 0, "preview must be non-zero");
        uint256 subSharesBefore = IERC20(_EULER_VAULT_PRIME_USDC).balanceOf(_subAccount);

        // then: the reset to zero must be an explicit approve call (the deposit alone consumes the allowance)
        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT_PRIME_USDC, amount)), 1);
        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT_PRIME_USDC, 0)), 1);
        vm.expectEmit(true, true, true, true, address(this));
        emit EulerV2SupplyEnterFuse(address(_fuse), _EULER_VAULT_PRIME_USDC, expectedShares, _subAccount);

        // when
        uint256 minted = _enter(amount);

        // then
        assertEq(minted, expectedShares, "return value is the minted shares");
        assertEq(
            IERC20(_EULER_VAULT_PRIME_USDC).balanceOf(_subAccount) - subSharesBefore,
            expectedShares,
            "sub-account receives exactly the minted shares"
        );
        assertEq(IERC20(_EULER_VAULT_PRIME_USDC).balanceOf(address(this)), 0, "vault itself holds no shares");
        assertEq(IERC20(_USDC).balanceOf(address(this)), 0, "all idle assets were deposited");
        assertEq(IERC20(_USDC).allowance(address(this), _EULER_VAULT_PRIME_USDC), 0, "allowance reset to zero");
    }

    function testEnterClampsMaxAmountToIdleBalance() public {
        // given: maxAmount far above the idle balance
        uint256 idle = 400e6;
        deal(_USDC, address(this), idle);
        uint256 expectedShares = IERC4626(_EULER_VAULT_PRIME_USDC).previewDeposit(idle);

        // then: the approval and the deposit use the idle balance, not maxAmount
        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT_PRIME_USDC, idle)), 1);
        vm.expectCall(_USDC, abi.encodeCall(IERC20.approve, (_EULER_VAULT_PRIME_USDC, 0)), 1);
        vm.expectEmit(true, true, true, true, address(this));
        emit EulerV2SupplyEnterFuse(address(_fuse), _EULER_VAULT_PRIME_USDC, expectedShares, _subAccount);

        // when
        uint256 minted = _enter(type(uint256).max);

        // then
        assertEq(minted, expectedShares, "shares of the idle balance only");
        assertEq(IERC20(_USDC).balanceOf(address(this)), 0, "idle balance fully deposited");
        assertEq(IERC20(_USDC).allowance(address(this), _EULER_VAULT_PRIME_USDC), 0, "allowance reset to zero");
    }

    function testEnterBelowIdleBalanceDepositsOnlyMaxAmount() public {
        // given: maxAmount below the idle balance
        deal(_USDC, address(this), 1_000e6);
        uint256 amount = 300e6;
        uint256 expectedShares = IERC4626(_EULER_VAULT_PRIME_USDC).previewDeposit(amount);

        // when
        uint256 minted = _enter(amount);

        // then
        assertEq(minted, expectedShares, "shares of maxAmount");
        assertEq(IERC20(_USDC).balanceOf(address(this)), 700e6, "remaining idle balance untouched");
        assertEq(IERC20(_USDC).allowance(address(this), _EULER_VAULT_PRIME_USDC), 0, "allowance reset to zero");
    }

    function testEnterWithNoIdleBalanceReturnsZeroWithoutEvent() public {
        // given: no idle assets
        vm.recordLogs();

        // when
        uint256 minted = _enter(1_000e6);

        // then
        assertEq(minted, 0, "nothing to deposit");
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(IERC20(_USDC).allowance(address(this), _EULER_VAULT_PRIME_USDC), 0, "no allowance");
    }

    function _enter(uint256 maxAmount_) private returns (uint256 minted) {
        (bool ok, bytes memory ret) = address(_fuse).delegatecall(
            abi.encodeCall(
                EulerV2SupplyFuse.enter,
                (
                    EulerV2SupplyFuseEnterData({
                        eulerVault: _EULER_VAULT_PRIME_USDC,
                        maxAmount: maxAmount_,
                        subAccount: _SUB
                    })
                )
            )
        );
        assertTrue(ok, "delegatecall enter failed");
        minted = abi.decode(ret, (uint256));
    }
}
