// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {Errors} from "../../../../libraries/errors/Errors.sol";
import {IporMath} from "../../../../libraries/math/IporMath.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {IWstETH} from "./ext/IWstETH.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Fuse for Lido protocol responsible for wrapping and unwrapping stETH
contract StEthWrapperFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    address public constant ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event StEthWrapperFuseEnter(address version, uint256 stEthAmount, uint256 wstEthAmount);
    event StEthWrapperFuseExit(address version, uint256 wstEthAmount, uint256 stEthAmount);

    error StEthWrapperFuseUnsupportedAsset(string action, address asset);

    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(uint256 stEthAmount) external {
        if (stEthAmount == 0) {
            return;
        }
        _validateSubstrates("enter");

        uint256 finalAmount = IporMath.min(ERC20(ST_ETH).balanceOf(address(this)), stEthAmount);

        ERC20(ST_ETH).forceApprove(address(WST_ETH), finalAmount);

        uint256 wstEthAmount = IWstETH(WST_ETH).wrap(finalAmount);

        ERC20(ST_ETH).forceApprove(address(WST_ETH), 0);

        emit StEthWrapperFuseEnter(VERSION, finalAmount, wstEthAmount);
    }

    function exit(uint256 wstEthAmount) external {
        if (wstEthAmount == 0) {
            return;
        }
        _validateSubstrates("exit");

        uint256 finalAmount = IporMath.min(ERC20(WST_ETH).balanceOf(address(this)), wstEthAmount);

        uint256 stEthAmount = IWstETH(WST_ETH).unwrap(finalAmount);

        emit StEthWrapperFuseExit(VERSION, finalAmount, stEthAmount);
    }

    function _validateSubstrates(string memory action) internal {
        address underlyingAsset = IERC4626(address(this)).asset();

        if (underlyingAsset != ST_ETH && !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, ST_ETH)) {
            revert StEthWrapperFuseUnsupportedAsset(action, ST_ETH);
        }
        if (underlyingAsset != WST_ETH && !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, WST_ETH)) {
            revert StEthWrapperFuseUnsupportedAsset(action, WST_ETH);
        }
    }
}
