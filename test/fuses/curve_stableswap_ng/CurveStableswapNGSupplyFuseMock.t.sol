// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {CurveStableswapNGSupplyFuse, CurveStableswapNGSupplyFuseEnterData, CurveStableswapNGSupplyFuseExitData, CurveStableswapNGSupplyFuseExitOneCoinData} from "../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGSupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract CurveStableswapNGSupplyFuseMock {
    using Address for address;

    CurveStableswapNGSupplyFuse public fuse;

    constructor(address fuseInput) {
        fuse = CurveStableswapNGSupplyFuse(fuseInput);
    }
    //solhint-disable-next-line
    function enter(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function enter(
        //solhint-disable-next-line
        CurveStableswapNGSupplyFuseEnterData memory data
    ) external returns (bytes memory executionStatus) {
        address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function exit(
        //solhint-disable-next-line
        CurveStableswapNGSupplyFuseExitData memory data
    ) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function exitOneCoin(
        //solhint-disable-next-line
        CurveStableswapNGSupplyFuseExitOneCoinData memory data
    ) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        PlasmaVaultConfigLib.grandSubstratesAsAssetsToMarket(marketId, assets);
    }
}
