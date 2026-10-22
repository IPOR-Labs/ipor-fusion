// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipRouteConfig} from "../../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";

contract MockCcipRouteValidator {
    mapping(uint256 => CcipRouteConfig) private _routes;

    function setRoute(uint256 chainId_, CcipRouteConfig calldata route_) external {
        _routes[chainId_] = route_;
    }

    function registerExecutorRoute(address executor_, uint256 chainId_, CcipRouteConfig calldata route_) external {
        CcipRouteConfig storage configured = _routes[chainId_];
        require(
            configured.peer == route_.peer && configured.enabled && route_.enabled
                && configured.chainSelector == route_.chainSelector && configured.feeToken == route_.feeToken
                && configured.messageGasLimit == route_.messageGasLimit
                && configured.tokenGasLimit == route_.tokenGasLimit && configured.maxFee == route_.maxFee,
            "route mismatch"
        );
        (bool success,) = executor_.call(
            abi.encodeWithSignature(
                "registerRoute(uint256,(uint64,address,address,uint96,uint96,uint256,bool))", chainId_, route_
            )
        );
        require(success, "register failed");
    }
}
