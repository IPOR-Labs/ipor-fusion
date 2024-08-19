// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";

/// @title Stateless extension of PlasmaVault with ERC20Votes
contract PlasmaVaultBase is ERC20VotesUpgradeable {}
