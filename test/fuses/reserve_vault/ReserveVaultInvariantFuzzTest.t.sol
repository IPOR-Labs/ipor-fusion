// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {ReserveVaultSupplyFuse} from "../../../contracts/fuses/reserve_vault/ReserveVaultSupplyFuse.sol";

import {ReserveVaultTestBase} from "./ReserveVaultTestBase.sol";

/// @dev Stateful fuzz of the reserve vault family: random sequences of user deposits, funding of C, reserve enters and
///      exits, losses and gains on both member vaults A and B. A step is decoded from one seed (operation, member, size).
///      After every step the ledger, boost and share price invariants are checked. Exits that the liquidity rule of the
///      fuse refuses are expected reverts: they are asserted by selector and arguments and counted, not skipped.
contract ReserveVaultInvariantFuzzTest is ReserveVaultTestBase {
    uint256 internal constant STEPS = 12;
    uint256 internal constant OPS = 7;
    uint256 internal constant MIN_AMOUNT = 1_000_000; // 1 USDC
    uint256 internal constant MAX_DEPOSIT = 10_000_000_000; // 10_000 USDC
    uint256 internal constant MAX_GAIN = 1_000_000_000; // 1_000 USDC
    uint256 internal constant WITHDRAW_OFFSET = 10;
    uint256 internal constant C_PRICE = 1_000_000;

    /// @dev Ghost ledger of C per member vault (index 0 = A, 1 = B)
    uint256[2] internal deposited;
    uint256[2] internal withdrawn;

    /// @dev Coverage counters
    uint256 internal enters;
    uint256 internal exits;
    uint256 internal fullExitsAtLoss;
    uint256 internal idleReverts;
    uint256 internal surplusReverts;

    // ---------------------------------------------------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzShouldKeepLedgerBoostAndPriceInvariantsOverRandomSequences(uint256[STEPS] memory seeds_) public {
        for (uint256 i; i < STEPS; ++i) {
            _step(seeds_[i]);
            _checkInvariants();
        }
    }

    function testShouldReachBoostedFullExitAtLossInSequence() public {
        _checkInvariants();
        _stepUserDeposit(vaultA, 1_000_000_000);
        _stepFundC(100_000_000);
        _stepEnter(0, 100_000_000);
        _stepLoss(0, 10_000_000);
        _stepExit(0, 100_000_000);
        _checkInvariants();

        assertEq(fullExitsAtLoss, 1, "full exit at loss reached");
        assertEq(exits, 1, "one exit");
        assertEq(_principal(vaultA), 0, "principal zero");
        assertEq(vaultA.balanceOf(address(vaultC)), 0, "no shares left");
    }

    function testShouldRejectFullExitWhenSurplusRedeemWouldPullInSequence() public {
        // C is the only holder of A: after the principal is paid, the surplus is nearly all of A's idle assets
        _stepFundC(100_000_000);
        _stepEnter(0, 100_000_000);
        _stepGain(0, 10_000_000);
        _stepExit(0, 100_000_000);
        _checkInvariants();

        assertEq(surplusReverts, 1, "surplus liquidity revert reached");
        assertEq(exits, 0, "no successful exit");
        assertEq(_principal(vaultA), 100_000_000, "principal untouched");
    }

    function testShouldRejectExitWhenIdleIsNotAboveAmountPlusOffsetInSequence() public {
        _stepUserDeposit(vaultB, 100_000_000);
        _stepFundC(50_000_000);
        _stepEnter(1, 50_000_000);
        // B holds 150_000_000 idle; the loss is capped at 80% = 120_000_000, which leaves 30_000_000 < 50_000_000
        _stepLoss(1, 119_999_999);
        _stepExit(1, 50_000_000);
        _checkInvariants();

        assertEq(idleReverts, 1, "idle revert reached");
        assertEq(exits, 0, "no successful exit");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Step dispatch
    // ---------------------------------------------------------------------------------------------------------------

    function _step(uint256 seed_) internal {
        uint256 op = seed_ % OPS;
        uint256 member = (seed_ >> 8) & 1;
        uint256 size = seed_ >> 16;

        if (op == 0) {
            _stepUserDeposit(_vault(member), MIN_AMOUNT + (size % MAX_DEPOSIT));
        } else if (op == 1) {
            _stepFundC(MIN_AMOUNT + (size % MAX_DEPOSIT));
        } else if (op == 2) {
            uint256 idle = usdc.balanceOf(address(vaultC));
            if (idle >= MIN_AMOUNT) {
                _stepEnter(member, MIN_AMOUNT + (size % (idle - MIN_AMOUNT + 1)));
            }
        } else if (op == 3 || op == 4) {
            uint256 principal = _principal(_vault(member));
            if (principal > 0) {
                // op 4 is always a full exit, op 3 a random partial one
                uint256 amount = op == 4 || principal <= MIN_AMOUNT
                    ? principal
                    : MIN_AMOUNT + (size % (principal - MIN_AMOUNT + 1));
                _stepExit(member, amount);
            }
        } else if (op == 5) {
            _stepLoss(member, size);
        } else {
            _stepGain(member, MIN_AMOUNT + (size % MAX_GAIN));
        }
    }

    function _vault(uint256 member_) internal view returns (PlasmaVault) {
        return member_ == 0 ? vaultA : vaultB;
    }

    function _stepUserDeposit(PlasmaVault vault_, uint256 assets_) internal {
        _deposit(vault_, USER, assets_);
    }

    function _stepFundC(uint256 assets_) internal {
        _fundC(assets_);
    }

    function _stepEnter(uint256 member_, uint256 amount_) internal {
        _reserveEnter(_vault(member_), amount_);
        deposited[member_] += amount_;
        ++enters;
    }

    /// @dev Loss of `size_` bounded to 80% of the member vault's idle USDC, so the vault never drains completely
    function _stepLoss(uint256 member_, uint256 size_) internal {
        PlasmaVault vault = _vault(member_);
        uint256 maxLoss = (usdc.balanceOf(address(vault)) * 80) / 100;
        if (maxLoss == 0) {
            return;
        }
        _loss(vault, 1 + (size_ % maxLoss));
    }

    function _stepGain(uint256 member_, uint256 amount_) internal {
        _gain(_vault(member_), amount_);
    }

    /// @dev Exit of `amount_` (at most the principal). Checks the effects of a successful exit, or that a revert is one
    ///      of the two documented liquidity refusals with the exact arguments, and that a revert changed nothing.
    function _stepExit(uint256 member_, uint256 amount_) internal {
        PlasmaVault member = _vault(member_);
        uint256 principalBefore = _principal(member);
        uint256 sharesBefore = member.balanceOf(address(vaultC));
        uint256 idleBefore = usdc.balanceOf(address(member));
        uint256 cUsdcBefore = usdc.balanceOf(address(vaultC));
        bool atLoss = member.convertToAssets(sharesBefore) < principalBefore;

        try this.exitExternal(member, amount_) {
            // then: C received exactly the requested amount, whatever the position was worth
            assertEq(usdc.balanceOf(address(vaultC)) - cUsdcBefore, amount_, "C receives exactly the amount");
            assertEq(_principal(member), principalBefore - amount_, "principal decreased by the amount");
            withdrawn[member_] += amount_;
            ++exits;
            if (atLoss && amount_ == principalBefore) {
                ++fullExitsAtLoss;
                assertEq(member.balanceOf(address(vaultC)), 0, "all shares burned on a full exit at loss");
            }
        } catch (bytes memory err) {
            assertEq(bytes4(err), ReserveVaultSupplyFuse.ReserveVaultSupplyFuseInsufficientIdleLiquidity.selector);
            (address vault, uint256 idle, uint256 required) = this.decodeIdleRevert(err);
            assertEq(vault, address(member), "revert names the member vault");
            assertLe(idle, required, "revert only when idle is not above the threshold");
            if (idleBefore <= amount_ + WITHDRAW_OFFSET) {
                assertEq(idle, idleBefore, "withdraw check: idle");
                assertEq(required, amount_ + WITHDRAW_OFFSET, "withdraw check: required");
                ++idleReverts;
            } else {
                // only the surplus redeem of a full exit can refuse after the withdraw check passed
                assertEq(amount_, principalBefore, "surplus check only on a full exit");
                assertEq(idle, idleBefore - amount_, "surplus check: idle after the withdrawal");
                assertGt(required, idle, "surplus check: required");
                ++surplusReverts;
            }
            // a refused exit changed nothing
            assertEq(_principal(member), principalBefore, "principal after refused exit");
            assertEq(member.balanceOf(address(vaultC)), sharesBefore, "shares after refused exit");
            assertEq(usdc.balanceOf(address(member)), idleBefore, "member idle after refused exit");
            assertEq(usdc.balanceOf(address(vaultC)), cUsdcBefore, "C balance after refused exit");
        }
    }

    /// @dev External so that `try/catch` can catch the exit; only the test itself may call it
    function exitExternal(PlasmaVault member_, uint256 amount_) external {
        require(msg.sender == address(this), "only self");
        _reserveExit(member_, amount_);
    }

    function decodeIdleRevert(bytes calldata err_) external pure returns (address, uint256, uint256) {
        return abi.decode(err_[4:], (address, uint256, uint256));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------------------------------------------------------

    function _checkInvariants() internal {
        uint256 principalSum;

        for (uint256 i; i < 2; ++i) {
            PlasmaVault member = _vault(i);
            uint256 principal = _principal(member);
            principalSum += principal;

            // 1: C never takes out more than it put in
            assertLe(withdrawn[i], deposited[i], "withdrawn <= deposited");
            // 2: ledger
            assertEq(principal, deposited[i] - withdrawn[i], "principal == deposited - withdrawn");
            // 3: no boost outside an exit
            assertEq(_boost(member), 0, "boost is zero");
            assertEq(member.totalAssetsInMarket(BOOST_MARKET), 0, "market 62 is zero");
            // 5: principal is always backed by shares
            if (principal > 0) {
                assertGt(member.balanceOf(address(vaultC)), 0, "principal has shares");
            }
        }

        // 4: C total assets (stored market balances, no fee drift): idle + principal
        assertEq(
            vaultC.totalAssets(),
            usdc.balanceOf(address(vaultC)) + principalSum,
            "C total assets = idle + principal (stored)"
        );
        // and again after C's markets are refreshed from the fuses
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = RESERVE_MARKET;
        vm.prank(ATOMIST);
        vaultC.updateMarketsBalances(marketIds);
        assertEq(
            vaultC.totalAssets(),
            usdc.balanceOf(address(vaultC)) + principalSum,
            "C total assets = idle + principal (refreshed)"
        );

        // 6: C stays 1:1
        assertEq(_sharePrice(vaultC), C_PRICE, "C share price unchanged");
    }
}
