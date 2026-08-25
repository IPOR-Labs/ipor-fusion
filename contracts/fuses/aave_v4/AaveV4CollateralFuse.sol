// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {AaveV4SubstrateLib} from "./AaveV4SubstrateLib.sol";
import {IAaveV4Spoke} from "./ext/IAaveV4Spoke.sol";

/// @dev Data structure for entering (enabling a reserve as collateral) the Aave V4 protocol
struct AaveV4CollateralFuseEnterData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
}

/// @dev Data structure for exiting (disabling a reserve as collateral) the Aave V4 protocol
struct AaveV4CollateralFuseExitData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
}

/// @title AaveV4CollateralFuse
/// @author IPOR Labs
/// @notice Fuse for Aave V4 protocol responsible for enabling and disabling reserves as collateral of the Plasma Vault
/// @dev In Aave V4 supplying does not enable collateral: only reserves flagged via setUsingAsCollateral count
///      towards the health factor, so without this fuse every borrow reverts with HealthFactorBelowThreshold.
///      Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Permissions come from Reserve substrates (spoke, reserveId, flags) encoded with AaveV4SubstrateLib:
///      - enter requires a granted substrate for the (spoke, reserveId) pair with isCollateral,
///      - exit requires any granted substrate for the pair (the Spoke enforces the health factor).
contract AaveV4CollateralFuse is IFuseCommon {
    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when a reserve is enabled as collateral
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param reserveId The reserve identifier
    event AaveV4CollateralFuseEnter(address version, address spoke, uint256 reserveId);

    /// @notice Emitted when a reserve is disabled as collateral
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param reserveId The reserve identifier
    event AaveV4CollateralFuseExit(address version, address spoke, uint256 reserveId);

    /// @notice Thrown when market ID is zero or invalid
    /// @custom:error AaveV4CollateralFuseInvalidMarketId
    error AaveV4CollateralFuseInvalidMarketId();

    /// @notice Thrown when the (spoke, reserveId) pair is not granted for the action
    /// @param action The action being performed ("enter" requires isCollateral, "exit" requires any grant)
    /// @param spoke The Spoke contract address
    /// @param reserveId The reserve identifier
    error AaveV4CollateralFuseUnsupportedSubstrate(string action, address spoke, uint256 reserveId);

    /// @notice Constructor for AaveV4CollateralFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert AaveV4CollateralFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enables a reserve as collateral of the Plasma Vault
    /// @param data_ Enter data containing spoke and reserveId
    /// @custom:revert AaveV4CollateralFuseUnsupportedSubstrate When (spoke, reserveId) is not granted with isCollateral
    function enter(AaveV4CollateralFuseEnterData memory data_) public {
        if (!AaveV4SubstrateLib.canCollateral(MARKET_ID, data_.spoke, data_.reserveId)) {
            revert AaveV4CollateralFuseUnsupportedSubstrate("enter", data_.spoke, data_.reserveId);
        }

        IAaveV4Spoke(data_.spoke).setUsingAsCollateral(data_.reserveId, true, address(this));

        emit AaveV4CollateralFuseEnter(VERSION, data_.spoke, data_.reserveId);
    }

    /// @notice Enables a reserve as collateral using transient storage for inputs
    /// @dev Reads spoke (0), reserveId (1) from transient storage; writes [spoke, reserveId] to outputs
    function enterTransient() external {
        AaveV4CollateralFuseEnterData memory data = AaveV4CollateralFuseEnterData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 0)),
            reserveId: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 1))
        });

        enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(data.spoke);
        outputs[1] = TypeConversionLib.toBytes32(data.reserveId);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Disables a reserve as collateral of the Plasma Vault
    /// @dev The Spoke reverts with HealthFactorBelowThreshold if outstanding debt would become under-collateralized
    /// @param data_ Exit data containing spoke and reserveId
    /// @custom:revert AaveV4CollateralFuseUnsupportedSubstrate When (spoke, reserveId) is not granted
    function exit(AaveV4CollateralFuseExitData memory data_) public {
        if (!AaveV4SubstrateLib.canSupply(MARKET_ID, data_.spoke, data_.reserveId)) {
            revert AaveV4CollateralFuseUnsupportedSubstrate("exit", data_.spoke, data_.reserveId);
        }

        IAaveV4Spoke(data_.spoke).setUsingAsCollateral(data_.reserveId, false, address(this));

        emit AaveV4CollateralFuseExit(VERSION, data_.spoke, data_.reserveId);
    }

    /// @notice Disables a reserve as collateral using transient storage for inputs
    /// @dev Reads spoke (0), reserveId (1) from transient storage; writes [spoke, reserveId] to outputs
    function exitTransient() external {
        AaveV4CollateralFuseExitData memory data = AaveV4CollateralFuseExitData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 0)),
            reserveId: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 1))
        });

        exit(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(data.spoke);
        outputs[1] = TypeConversionLib.toBytes32(data.reserveId);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
