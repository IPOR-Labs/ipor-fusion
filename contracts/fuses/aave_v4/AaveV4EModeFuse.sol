// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {AaveV4SubstrateLib} from "./AaveV4SubstrateLib.sol";
import {IAaveV4Spoke} from "./ext/IAaveV4Spoke.sol";

/// @dev Data structure for entering (setting E-Mode) the Aave V4 protocol
struct AaveV4EModeFuseEnterData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice E-Mode category ID (0 to disable)
    uint8 eModeCategory;
}

/// @title AaveV4EModeFuse
/// @author IPOR Labs
/// @notice Fuse for Aave V4 protocol responsible for setting E-Mode categories via Spoke contracts
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      To disable E-Mode, call enter() with eModeCategory = 0.
contract AaveV4EModeFuse is IFuseCommon {
    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when E-Mode category is set
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param eModeCategory The E-Mode category ID that was set
    event AaveV4EModeFuseEnter(address version, address spoke, uint8 eModeCategory);

    /// @notice Thrown when market ID is zero or invalid
    error AaveV4EModeFuseInvalidMarketId();

    /// @notice Thrown when a substrate (spoke) is not authorized for this market
    /// @param substrate The unauthorized substrate bytes32 value
    error AaveV4EModeFuseUnsupportedSubstrate(bytes32 substrate);

    /// @notice Constructor for AaveV4EModeFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert AaveV4EModeFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Sets the E-Mode category on an Aave V4 Spoke contract
    /// @param data_ Enter data containing spoke address and E-Mode category ID
    function enter(AaveV4EModeFuseEnterData memory data_) public {
        bytes32 spokeSubstrate = AaveV4SubstrateLib.encodeSpoke(data_.spoke);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, spokeSubstrate)) {
            revert AaveV4EModeFuseUnsupportedSubstrate(spokeSubstrate);
        }

        IAaveV4Spoke(data_.spoke).setUserEMode(data_.eModeCategory);

        emit AaveV4EModeFuseEnter(VERSION, data_.spoke, data_.eModeCategory);
    }

    /// @notice Sets E-Mode category using transient storage for inputs
    /// @dev Reads spoke (0), eModeCategory (1) from transient storage
    function enterTransient() external {
        AaveV4EModeFuseEnterData memory data = AaveV4EModeFuseEnterData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(TransientStorageLib.getInput(VERSION, 0)),
            eModeCategory: SafeCast.toUint8(uint256(TransientStorageLib.getInput(VERSION, 1)))
        });

        enter(data);
    }
}
