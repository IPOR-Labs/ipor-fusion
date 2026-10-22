// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {CrosschainConstants} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {VaultSweepHarness} from "../VaultRemovalSweepTest.t.sol";

/// @title VaultSweepIdleRedeemForkTest
/// @notice IL-8784 smoke test and idle-served LOWER BOUND of the sweep `redeem` gas on Ethereum: the shared
///         `sweepShares` helper redeems a position that was just deposited into live vaults (a PlasmaVault with 3
///         markets: ERC20 vault balance, Morpho, Euler V2; a PlasmaVault with Morpho positions; a MetaMorpho vault with
///         12 markets). Because the deposit stays in the vault's idle cash, the redeem is served from idle and costs
///         far less than the redeem of a position that sits in allocated markets. This is NOT a calibration of real
///         positions: those can cost 3M or more (see `CrosschainConstants.VAULT_SWEEP_GAS`), and the sweep over a real
///         CCIP transport on a 3M route is covered by `VaultRemovalDustForkTest`. Own fork block (see
///         `CcipForkBase._forkBlocks`): suites must not share a backend. Needs ETHEREUM_PROVIDER_URL (archive node).
contract VaultSweepIdleRedeemForkTest is Test {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant TESSERACT_USDC_OPTIMIZER = 0xc2A119EA6De75e4B1451330321CB2474Eb8D82d4; // PlasmaVault, 3 markets
    address internal constant TESS_USDC_OPTIMISER = 0xc825779C89120eeEf746C51130B362478E181d39; // PlasmaVault, Morpho
    address internal constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB; // MetaMorpho, 12 markets
    uint256 internal constant FORK_BLOCK = 26_186_350;
    uint256 internal constant DEPOSIT = 1_000e6;

    VaultSweepHarness internal host;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);
        host = new VaultSweepHarness(USDC);
    }

    /// @dev PlasmaVault `deposit` / `redeem` are `restricted`, but `redeem` is `PUBLIC_ROLE` by default, so the
    ///      dispatcher does not need a special role to sweep (a vault can restrict it, which is then a normal failed
    ///      sweep). The test only grants the depositor and the sweeping host both selectors by mocking the vault's
    ///      access authority for exactly those (caller, selector) pairs, so it does not depend on the live role setup.
    function _authorize(address vault_) private {
        (bool ok, bytes memory ret) = vault_.staticcall(abi.encodeWithSignature("authority()"));
        if (!ok) return; // not access managed (MetaMorpho)
        address authority = abi.decode(ret, (address));
        address[2] memory callers = [address(this), address(host)];
        bytes4[2] memory selectors = [IERC4626.deposit.selector, IERC4626.redeem.selector];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                vm.mockCall(
                    authority,
                    abi.encodeWithSignature("canCall(address,address,bytes4)", callers[i], vault_, selectors[j]),
                    abi.encode(true, uint32(0))
                );
            }
        }
    }

    function _sweepGas(address vault_) private returns (uint256 gasUsed) {
        _authorize(vault_);
        deal(USDC, address(this), DEPOSIT);
        IERC20(USDC).approve(vault_, DEPOSIT);
        IERC4626(vault_).deposit(DEPOSIT, address(host));
        skip(1 minutes); // past a short redemption delay; stays inside oracle staleness windows
        uint256 shares = IERC20(vault_).balanceOf(address(host));
        assertGt(shares, 0, "position opened");
        uint256 before = gasleft();
        (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) = host.sweep{gas: 6_000_000}(
            vault_
        );
        gasUsed = before - gasleft();
        emit log_named_uint("sweep gas", gasUsed);
        emit log_named_bytes32("redeem error", bytes32(err));
        emit log_named_uint("sweep reason", reason);
        assertEq(reason, 0, "clean sweep");
        assertEq(err, bytes4(0), "no revert");
        assertEq(left, 0, "nothing left");
        assertEq(redeemed, shares, "whole position redeemed");
        assertApproxEqRel(assetsLD, DEPOSIT, 0.02e18, "about the deposit back (fees and rounding)");
        // Measured at this block with the redeem served from idle: MetaMorpho (12 markets) about 0.52M, 3-market
        // PlasmaVault about 1.40M. A position allocated into markets costs more; this only bounds the idle-served case.
        assertLt(
            gasUsed,
            (CrosschainConstants.VAULT_SWEEP_GAS * 85) / 100,
            "idle-served redeem: at least 15% headroom below VAULT_SWEEP_GAS"
        );
    }

    function testShouldSweepAThreeMarketPlasmaVaultWithinTheCap() public {
        _sweepGas(TESSERACT_USDC_OPTIMIZER);
    }

    function testShouldSweepAMorphoPlasmaVaultWithinTheCap() public {
        _sweepGas(TESS_USDC_OPTIMISER);
    }

    function testShouldSweepATwelveMarketMetaMorphoVaultWithinTheCap() public {
        _sweepGas(STEAKHOUSE_USDC);
    }
}
