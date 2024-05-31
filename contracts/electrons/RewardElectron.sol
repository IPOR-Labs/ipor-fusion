// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FusesLib} from "../libraries/FusesLib.sol";
import {FuseAction} from "../vaults/PlasmaVault.sol";
import {ElectronStorageLib, VestingData} from "./ElectronStorageLib.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";

contract RewardElectron is AccessManaged {
    error UnableToTransferUnderlineToken();

    event AmountWithdrawn(uint256 amount);

    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public immutable underlineToken;
    address public immutable plasmaVault;

    constructor(address initialAuthority_, address plasmaVault_) AccessManaged(initialAuthority_) {
        underlineToken = PlasmaVault(plasmaVault_).asset();
        plasmaVault = plasmaVault_;
    }

    /// @dev param account is not used and it is left to be aligned with ERC20 standard for this method
    function balanceOf(address account) public view returns (uint256) {
        VestingData memory data = ElectronStorageLib.getVestingData();

        if (data.updateBalanceTimestamp == 0) {
            return 0;
        }

        uint256 ratio = 1e18;
        if (block.timestamp >= data.updateBalanceTimestamp) {
            ratio = ((block.timestamp - data.updateBalanceTimestamp) * 1e18) / data.vesting;
        }

        if (ratio >= 1e18) {
            return data.balanceOnLastUpdate - data.releasedTokens;
        } else {
            return Math.mulDiv(data.balanceOnLastUpdate, ratio, 1e18) - data.releasedTokens;
        }
    }

    function isRewardFuseSupported(address fuse_) external view returns (bool) {
        return FusesLib.isFuseSupported(fuse_);
    }

    function getVestingData() external view returns (VestingData memory) {
        return ElectronStorageLib.getVestingData();
    }

    function transfer(address asset_, address to_, uint256 amount_) external restricted {
        if (asset_ == underlineToken) {
            revert UnableToTransferUnderlineToken();
        }
        IERC20(asset_).safeTransfer(to_, amount_);
    }

    function addRewardFuse(address[] calldata fuses_) external restricted {
        uint256 len = fuses_.length;
        for (uint256 i; i < len; ++i) {
            FusesLib.addFuse(fuses_[i]);
        }
    }

    function removeRewardFuse(address fuse_) external restricted {
        FusesLib.removeFuse(fuse_);
    }

    function claimRewards(FuseAction[] calldata calls_) external restricted {
        uint256 len = calls_.length;
        for (uint256 i; i < len; ++i) {
            if (!FusesLib.isFuseSupported(calls_[i].fuse)) {
                revert FusesLib.FuseUnsupported(calls_[i].fuse);
            }
        }

        PlasmaVault(plasmaVault).executeClaimRewards(calls_);
    }

    function setupVesting(uint256 releaseTokensDelay_) external restricted {
        ElectronStorageLib.setupVesting(releaseTokensDelay_);
    }

    function updateBalance() external restricted {
        VestingData memory data = ElectronStorageLib.getVestingData();
        data.updateBalanceTimestamp = block.timestamp.toUint32();
        data.balanceOnLastUpdate = IERC20(underlineToken).balanceOf(address(this)).toUint128();
        data.releasedTokens = 0;

        ElectronStorageLib.setVestingData(data);
    }

    function transferVestedTokens() external restricted {
        uint256 balance = balanceOf(plasmaVault);
        if (balance == 0) {
            return;
        }
        IERC20(underlineToken).safeTransfer(plasmaVault, balance);
        ElectronStorageLib.updateReleasedTokens(balance);
        emit AmountWithdrawn(balance);
    }
}
