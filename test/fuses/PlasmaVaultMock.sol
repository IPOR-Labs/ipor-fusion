// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";

contract PlasmaVaultMock {
    using Address for address;

    address public fuse;
    address public balanceFuse;

    constructor(address fuse_, address balanceFuse_) {
        fuse = fuse_;
        balanceFuse = balanceFuse_;
    }

    //solhint-disable-next-line
    function enter(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        PlasmaVaultConfigLib.grantSubstratesAsAssetsToMarket(marketId, assets);
    }

    function grantMarketSubstrates(uint256 marketId, bytes32[] calldata substrates) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId, substrates);
    }

    //solhint-disable-next-line
    function balanceOf() external returns (uint256) {
        return abi.decode(balanceFuse.functionDelegateCall(msg.data), (uint256));
    }

    function updateMarketConfiguration(uint256 marketId, address[] memory supportedAssets) public {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = PlasmaVaultStorageLib
            .getMarketSubstrates()
            .value[marketId];

        bytes32[] memory list = new bytes32[](supportedAssets.length);

        for (uint256 i; i < supportedAssets.length; ++i) {
            marketSubstrates.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(supportedAssets[i])] = 1;
            list[i] = PlasmaVaultConfigLib.addressToBytes32(supportedAssets[i]);
        }

        marketSubstrates.substrates = list;
    }

    function setPriceOracleMiddleware(address priceOracleMiddleware_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }
}
