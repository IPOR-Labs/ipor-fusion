// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {Errors} from "../../../../libraries/errors/Errors.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IBorrowerOperations} from "./ext/IBorrowerOperations.sol";
import {FuseStorageLib} from "../../../../libraries/FuseStorageLib.sol";
import {IActivePool} from "./ext/IActivePool.sol";
import {ITroveManager} from "./ext/ITroveManager.sol";
import {LiquityMath} from "./ext/LiquityMath.sol";
import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";

contract LiquityStabilityPoolFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    // We fix only one registry for each vault, to allow more granularity
    IAddressesRegistry public immutable registry;
    IStabilityPool public immutable stabilityPool;
    address public immutable boldToken;

    struct LiquitySPData {
        uint256 amount;
        bool doClaim;
    }

    error InvalidRegistry();

    event LiquityStabilityPoolFuseEnter(address version, address stabilityPool, uint256 amount, bool doClaim);

    constructor(uint256 marketId_, address _registry) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        registry = IAddressesRegistry(_registry);
        stabilityPool = registry.stabilityPool();
        boldToken = registry.boldToken();
    }

    function enter(LiquitySPData calldata data) external {
        ERC20(boldToken).forceApprove(address(stabilityPool), data.amount);
        stabilityPool.provideToSP(data.amount, data.doClaim);
        ERC20(boldToken).forceApprove(address(stabilityPool), 0);

        emit LiquityStabilityPoolFuseEnter(VERSION, address(stabilityPool), data.amount, data.doClaim);
    }

    function exit(LiquitySPData calldata data) external {
        stabilityPool.withdrawFromSP(data.amount, data.doClaim);
    }
}
