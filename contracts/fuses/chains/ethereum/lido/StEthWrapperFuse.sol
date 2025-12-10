// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../../../libraries/TypeConversionLib.sol";
import {Errors} from "../../../../libraries/errors/Errors.sol";
import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {TransientStorageLib} from "../../../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {IWstETH} from "./ext/IWstETH.sol";

/// @title StEthWrapperFuse
/// @notice Fuse for Lido protocol responsible for wrapping and unwrapping stETH
/// @author IPOR Labs
contract StEthWrapperFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Address of stETH token
    address public constant ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice Address of wstETH token
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Address of this fuse contract
    address public immutable VERSION;

    /// @notice Market ID for the fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the strategy (wrapping stETH to wstETH)
    /// @param version Address of the fuse
    /// @param stEthAmount Amount of stETH provided
    /// @param wstEthAmount Amount of wstETH received
    event StEthWrapperFuseEnter(address version, uint256 stEthAmount, uint256 wstEthAmount);

    /// @notice Emitted when exiting the strategy (unwrapping wstETH to stETH)
    /// @param version Address of the fuse
    /// @param wstEthAmount Amount of wstETH provided
    /// @param stEthAmount Amount of stETH received
    event StEthWrapperFuseExit(address version, uint256 wstEthAmount, uint256 stEthAmount);

    /// @notice Error thrown when asset is not supported
    /// @param action Action name for error reporting
    /// @param asset Asset address that is not supported
    error StEthWrapperFuseUnsupportedAsset(string action, address asset);

    /// @notice Constructor
    /// @param marketId_ Market ID
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters the strategy by wrapping stETH to wstETH
    /// @param stEthAmount Amount of stETH to wrap
    /// @return finalAmount Amount of stETH actually wrapped
    /// @return wstEthAmount Amount of wstETH received
    function enter(uint256 stEthAmount) public returns (uint256 finalAmount, uint256 wstEthAmount) {
        if (stEthAmount == 0) {
            return (0, 0);
        }
        _validateSubstrates("enter");

        uint256 finalAmount = IporMath.min(ERC20(ST_ETH).balanceOf(address(this)), stEthAmount);

        if (finalAmount == 0) {
            return (0, 0);
        }

        ERC20(ST_ETH).forceApprove(address(WST_ETH), finalAmount);

        wstEthAmount = IWstETH(WST_ETH).wrap(finalAmount);

        ERC20(ST_ETH).forceApprove(address(WST_ETH), 0);

        emit StEthWrapperFuseEnter(VERSION, finalAmount, wstEthAmount);

        return (finalAmount, wstEthAmount);
    }

    /// @notice Enters the strategy using transient storage for input/output
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 stEthAmount = TypeConversionLib.toUint256(inputs[0]);

        (uint256 finalAmount, uint256 wstEthAmount) = enter(stEthAmount);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(finalAmount);
        outputs[1] = TypeConversionLib.toBytes32(wstEthAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the strategy by unwrapping wstETH to stETH
    /// @param wstEthAmount Amount of wstETH to unwrap
    /// @return finalAmount Amount of wstETH actually unwrapped
    /// @return stEthAmount Amount of stETH received
    function exit(uint256 wstEthAmount) public returns (uint256 finalAmount, uint256 stEthAmount) {
        if (wstEthAmount == 0) {
            return (0, 0);
        }
        _validateSubstrates("exit");

        uint256 finalAmount = IporMath.min(ERC20(WST_ETH).balanceOf(address(this)), wstEthAmount);

        if (finalAmount == 0) {
            return (0, 0);
        }

        stEthAmount = IWstETH(WST_ETH).unwrap(finalAmount);

        emit StEthWrapperFuseExit(VERSION, finalAmount, stEthAmount);

        return (finalAmount, stEthAmount);
    }

    /// @notice Exits the strategy using transient storage for input/output
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 wstEthAmount = TypeConversionLib.toUint256(inputs[0]);

        (uint256 finalAmount, uint256 stEthAmount) = exit(wstEthAmount);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(finalAmount);
        outputs[1] = TypeConversionLib.toBytes32(stEthAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Validates that the asset is supported
    /// @param action Action name for error reporting
    function _validateSubstrates(string memory action) internal view {
        address underlyingAsset = IERC4626(address(this)).asset();

        if (underlyingAsset != ST_ETH && !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, ST_ETH)) {
            revert StEthWrapperFuseUnsupportedAsset(action, ST_ETH);
        }
        if (underlyingAsset != WST_ETH && !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, WST_ETH)) {
            revert StEthWrapperFuseUnsupportedAsset(action, WST_ETH);
        }
    }
}
