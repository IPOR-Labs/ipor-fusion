// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PlasmaVaultDeployData, FeeConfig, MarketSubstratesConfig, BalanceFuseConfig} from "./PlasmaVaultTypes.sol";

/// @dev Contract responsible for deploying proxies for PlasmaVault and its managers
contract PlasmaVaultDeployer {
    /// @dev Implementation addresses for all components
    address public immutable plasmaVaultImplementation;
address public immutable accessManagerImplementation;
    address public immutable withdrawManagerImplementation;
    address public immutable rewardsManagerImplementation;
    address public immutable feeManagerImplementation;

    event ProxiesDeployed(
        address indexed plasmaVault,
        address indexed accessManager,
        address rewardsManager,
        address feeManager,
        address withdrawManager,
        bytes32 salt
    );

    constructor(
        address plasmaVaultImpl_,
        address accessManagerImpl_,
        address withdrawManagerImpl_,
        address rewardsManagerImpl_,
        address feeManagerImpl_
    ) {
        require(plasmaVaultImpl_ != address(0), "Invalid PlasmaVault implementation");
        require(accessManagerImpl_ != address(0), "Invalid AccessManager implementation");
        require(withdrawManagerImpl_ != address(0), "Invalid WithdrawManager implementation");
        require(rewardsManagerImpl_ != address(0), "Invalid RewardsManager implementation");
        require(feeManagerImpl_ != address(0), "Invalid FeeManager implementation");

        plasmaVaultImplementation = plasmaVaultImpl_;
        accessManagerImplementation = accessManagerImpl_;
        withdrawManagerImplementation = withdrawManagerImpl_;
        rewardsManagerImplementation = rewardsManagerImpl_;
        feeManagerImplementation = feeManagerImpl_;
    }

    /// @dev Deploys all proxies using CREATE2 for deterministic addresses
    /// @param salt Unique identifier for this deployment
    /// @return vault Address of deployed PlasmaVault proxy
    /// @return accessManager Address of deployed AccessManager proxy
    /// @return rewardsManager Address of deployed RewardsManager proxy
    /// @return feeManager Address of deployed FeeManager proxy
    /// @return withdrawManager Address of deployed WithdrawManager proxy (or address(0))
    function deployProxies(bytes32 salt) external returns (
        address vault,
        address accessManager,
        address rewardsManager,
        address feeManager,
        address withdrawManager
    ) {
        // Deploy AccessManager first
        accessManager = Clones.cloneDeterministic(accessManagerImplementation, _saltFor(salt, "ACCESS"));

        // Deploy WithdrawManager if needed (salt parameter will determine this)
        if (uint256(salt) & 1 == 1) { // Use last bit of salt to determine if WithdrawManager is needed
            withdrawManager = Clones.cloneDeterministic(withdrawManagerImplementation, _saltFor(salt, "WITHDRAW"));
        }

        // Deploy remaining components
        vault = Clones.cloneDeterministic(plasmaVaultImplementation, _saltFor(salt, "VAULT"));
        rewardsManager = Clones.cloneDeterministic(rewardsManagerImplementation, _saltFor(salt, "REWARDS"));
        feeManager = Clones.cloneDeterministic(feeManagerImplementation, _saltFor(salt, "FEE"));

        emit ProxiesDeployed(
            vault,
            accessManager,
            rewardsManager,
            feeManager,
            withdrawManager,
            salt
        );
    }

    /// @dev Computes deterministic addresses for all proxies before deployment
    /// @param salt Unique identifier for this deployment
    /// @return vault Expected address of PlasmaVault proxy
    /// @return accessManager Expected address of AccessManager proxy
    /// @return rewardsManager Expected address of RewardsManager proxy
    /// @return feeManager Expected address of FeeManager proxy
    /// @return withdrawManager Expected address of WithdrawManager proxy
    function computeAddresses(bytes32 salt) external view returns (
        address vault,
        address accessManager,
        address rewardsManager,
        address feeManager,
        address withdrawManager
    ) {
        accessManager = Clones.predictDeterministicAddress(
            accessManagerImplementation,
            _saltFor(salt, "ACCESS"),
            address(this)
        );

        if (uint256(salt) & 1 == 1) {
            withdrawManager = Clones.predictDeterministicAddress(
                withdrawManagerImplementation,
                _saltFor(salt, "WITHDRAW"),
                address(this)
            );
        }

        vault = Clones.predictDeterministicAddress(
            plasmaVaultImplementation,
            _saltFor(salt, "VAULT"),
            address(this)
        );
        rewardsManager = Clones.predictDeterministicAddress(
            rewardsManagerImplementation,
            _saltFor(salt, "REWARDS"),
            address(this)
        );
        feeManager = Clones.predictDeterministicAddress(
            feeManagerImplementation,
            _saltFor(salt, "FEE"),
            address(this)
        );
    }

    /// @dev Creates a unique salt for each component
    function _saltFor(bytes32 baseSalt, string memory component) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(baseSalt, component));
    }
}