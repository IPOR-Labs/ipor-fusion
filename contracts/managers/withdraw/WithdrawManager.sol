// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {WithdrawManagerStorageLib} from "./WithdrawManagerStorageLib.sol";

    struct WithdrawRequest {
        uint256 amount;
        uint256 endWithdrawWindow;
        uint256 withdrawAvailable;
    }


contract WithdrawManager is AccessManaged {

    function canWithdraw(address account) external view returns (uint256) {
        return 0;
    }

    function request(uint256 amount) external {
        WithdrawManagerStorageLib.updateWithdrawRequest(amount);
    }

    function releaseFounds() external restricted {
        WithdrawManagerStorageLib.releaseFounds();
    }

    function updateWithdrawWindow(uint256 window) external restricted {}

    function requestInfo(address account) external view returns (uint256, uint256) {
        return (0, 0);
    }

}