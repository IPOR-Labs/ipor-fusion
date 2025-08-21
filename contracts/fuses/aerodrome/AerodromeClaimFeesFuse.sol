// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "./ext/IPool.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "./AreodromeLib.sol";

struct AerodromeClaimFeesFuseEnterData {
    address[] pools;
}

contract AerodromeClaimFeesFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event AerodromeClaimFeesFuseEnter(address version, address pool, uint256 claimed0, uint256 claimed1);

    error AerodromeClaimFeesFuseUnsupportedPool(string operation, address pool);

    constructor(uint256 marketIdInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
    }

    function enter(AerodromeClaimFeesFuseEnterData memory data_) external {
        address poolAddress;
        uint256 claimed0;
        uint256 claimed1;
        uint256 len = data_.pools.length;

        for (uint256 i; i < len; i++) {
            poolAddress = data_.pools[i];
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    AerodromeSubstrateLib.substrateToBytes32(
                        AerodromeSubstrate({substrateAddress: poolAddress, substrateType: AerodromeSubstrateType.Pool})
                    )
                )
            ) {
                revert AerodromeClaimFeesFuseUnsupportedPool("enter", poolAddress);
            }
            (claimed0, claimed1) = IPool(poolAddress).claimFees();

            emit AerodromeClaimFeesFuseEnter(VERSION, poolAddress, claimed0, claimed1);
        }
    }
}
