// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuse} from "../IFuse.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IFarmingPool} from "./ext/IFarmingPool.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

struct GearboxV3FarmdSupplyFuseEnterData {
    /// @dev max amount to deposit
    uint256 amount;
    address farmdToken;
}

struct GearboxV3FarmdSupplyFuseExitData {
    /// @dev amount to withdraw
    uint256 amount;
    address farmdToken;
}

contract GearboxV3FarmSupplyFuse is IFuse, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    event GearboxV3FarmdEnterFuse(address version, address farmdToken, address dToken, uint256 amount);
    event GearboxV3FarmdExitFuse(address version, address farmdToken, uint256 amount);

    error GearboxV3FarmdSupplyFuseUnsupportedFarmdToken(string action, address farmdToken);

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters to the Market
    function enter(bytes calldata data_) external {
        GearboxV3FarmdSupplyFuseEnterData memory data = abi.decode(data_, (GearboxV3FarmdSupplyFuseEnterData));
        enter(data);
    }

    function enter(GearboxV3FarmdSupplyFuseEnterData memory data_) public {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.farmdToken)) {
            revert GearboxV3FarmdSupplyFuseUnsupportedFarmdToken("enter", data_.farmdToken);
        }

        address dToken = IFarmingPool(data_.farmdToken).stakingToken();
        uint256 deposit = IporMath.min(data_.amount, IFarmingPool(dToken).balanceOf(address(this)));

        IERC20(dToken).forceApprove(data_.farmdToken, deposit);
        IFarmingPool(data_.farmdToken).deposit(deposit);

        emit GearboxV3FarmdEnterFuse(VERSION, data_.farmdToken, dToken, deposit);
    }

    /// @notice Exits from the Market
    function exit(bytes calldata data_) external {
        GearboxV3FarmdSupplyFuseExitData memory data = abi.decode(data_, (GearboxV3FarmdSupplyFuseExitData));
        exit(data);
    }
    /// @notice Exits from the Market
    function exit(GearboxV3FarmdSupplyFuseExitData memory data_) public {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.farmdToken)) {
            revert GearboxV3FarmdSupplyFuseUnsupportedFarmdToken("enter", data_.farmdToken);
        }

        uint256 withdrawAmount = IporMath.min(data_.amount, IFarmingPool(data_.farmdToken).balanceOf(address(this)));

        IFarmingPool(data_.farmdToken).withdraw(withdrawAmount);
        emit GearboxV3FarmdExitFuse(VERSION, data_.farmdToken, withdrawAmount);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address farmdToken = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        exit(
            GearboxV3FarmdSupplyFuseExitData({
                farmdToken: farmdToken,
                amount: IERC4626(IFarmingPool(farmdToken).stakingToken()).convertToShares(amount)
            })
        );
    }
}
