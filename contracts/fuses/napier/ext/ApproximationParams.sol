// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.26;

/// @notice Parameters for the binary search algorithm
/// @dev If eps is zero, the binary search will use default binary search configuration.
/// @param guessMin The minimum value of the guess
/// @param guessMax The maximum value of the guess (guessMin < guessMax)
/// @param eps The relative error tolerance (0.01e18 = 1%). Binary search will run until the relative error is less than eps.
struct ApproximationParams {
    int256 guessMin;
    int256 guessMax;
    uint256 eps;
}
