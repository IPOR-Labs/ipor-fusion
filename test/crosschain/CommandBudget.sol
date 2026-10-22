// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev IL-8625: default `Command.minExecutionGas` / `UpdateVaults.minExecutionGas` of the crosschain tests that
///      deliver a hand-built command straight to a dispatcher. Above `COMMAND_EXECUTION_MIN_GAS` (1,000,000) and well
///      below the gas those tests deliver with, so the budget check never decides their outcome. Tests of the budget
///      itself set their own value.
uint64 constant DEFAULT_COMMAND_BUDGET = 1_500_000;
