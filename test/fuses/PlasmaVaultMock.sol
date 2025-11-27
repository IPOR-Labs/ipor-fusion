// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {AaveV2SupplyFuseEnterData, AaveV2SupplyFuseExitData} from "../../contracts/fuses/aave_v2/AaveV2SupplyFuse.sol";
import {AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {CompoundV2SupplyFuseEnterData, CompoundV2SupplyFuseExitData} from "../../contracts/fuses/compound_v2/CompoundV2SupplyFuse.sol";
import {CompoundV3SupplyFuseEnterData, CompoundV3SupplyFuseExitData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {Erc4626SupplyFuseEnterData, Erc4626SupplyFuseExitData} from "../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {MorphoSupplyFuseEnterData, MorphoSupplyFuseExitData} from "../../contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {SparkSupplyFuseEnterData, SparkSupplyFuseExitData} from "../../contracts/fuses/chains/ethereum/spark/SparkSupplyFuse.sol";
import {FusesLib} from "../../contracts/libraries/FusesLib.sol";
import {InstantWithdrawalFusesParamsStruct, PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {TransientStorageLib} from "../../contracts/transient_storage/TransientStorageLib.sol";

contract PlasmaVaultMock {
    using Address for address;

    address public fuse;
    address public balanceFuse;

    constructor(address fuse_, address balanceFuse_) {
        fuse = fuse_;
        balanceFuse = balanceFuse_;
    }

    function enterCompoundV3Supply(CompoundV3SupplyFuseEnterData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enter((address,uint256))", data));
    }

    function enterCompoundV2Supply(CompoundV2SupplyFuseEnterData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enter((address,uint256))", data));
    }

    function enterCompoundV2SupplyTransient() external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enterTransient()"));
    }

    function exitCompoundV2SupplyTransient() external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exitTransient()"));
    }

    function enterAaveV3Supply(AaveV3SupplyFuseEnterData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enter((address,uint256,uint256))", data));
    }

    function enterAaveV3SupplyTransient() external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enterTransient()"));
    }

    function enterAaveV2Supply(AaveV2SupplyFuseEnterData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enter((address,uint256))", data));
    }
    function enterErc4626Supply(Erc4626SupplyFuseEnterData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enter((address,uint256))", data));
    }
    function enterSparkSupply(SparkSupplyFuseEnterData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enter((uint256))", data));
    }

    function enterSparkSupplyTransient() external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enterTransient()"));
    }

    function exitSparkSupplyTransient() external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exitTransient()"));
    }

    function enterMorphoSupply(MorphoSupplyFuseEnterData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("enter((bytes32,uint256))", data));
    }

    function exitCompoundV3Supply(CompoundV3SupplyFuseExitData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exit((address,uint256))", data));
    }

    function exitCompoundV2Supply(CompoundV2SupplyFuseExitData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exit((address,uint256))", data));
    }

    function exitAaveV3Supply(AaveV3SupplyFuseExitData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exit((address,uint256))", data));
    }

    function exitAaveV3SupplyTransient() external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exitTransient()"));
    }

    function exitSparkSupply(SparkSupplyFuseExitData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exit((uint256))", data));
    }

    function exitAaveV2Supply(AaveV2SupplyFuseExitData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exit((address,uint256))", data));
    }

    function exitErc4626Supply(Erc4626SupplyFuseExitData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exit((address,uint256))", data));
    }

    function exitMorphoSupply(MorphoSupplyFuseExitData memory data) external {
        address(fuse).functionDelegateCall(abi.encodeWithSignature("exit((bytes32,uint256))", data));
    }

    //solhint-disable-next-line
    function enter(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    //solhint-disable-next-line
    function exit(bytes calldata data) external {
        address(fuse).functionDelegateCall(msg.data);
    }

    function instantWithdraw(bytes32[] calldata params_) external {
        address(fuse).functionDelegateCall(abi.encodeWithSelector(bytes4(0xbe1946da), params_));
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

    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses_) external {
        PlasmaVaultLib.configureInstantWithdrawalFuses(fuses_);
    }

    function addFuses(address[] calldata fuses_) external {
        for (uint256 i; i < fuses_.length; ++i) {
            FusesLib.addFuse(fuses_[i]);
        }
    }

    /// @notice Sets input parameters for a specific account in transient storage
    /// @param account_ The address of the account
    /// @param inputs_ Array of input values
    function setInputs(address account_, bytes32[] calldata inputs_) external {
        TransientStorageLib.setInputs(account_, inputs_);
    }

    /// @notice Retrieves a single input parameter for a specific account at a given index
    /// @param account_ The address of the account
    /// @param index_ The index of the input parameter
    /// @return The input value at the specified index
    function getInput(address account_, uint256 index_) external view returns (bytes32) {
        return TransientStorageLib.getInput(account_, index_);
    }

    /// @notice Retrieves all input parameters for a specific account
    /// @param account_ The address of the account
    /// @return inputs Array of input values
    function getInputs(address account_) external view returns (bytes32[] memory) {
        return TransientStorageLib.getInputs(account_);
    }

    function execute(address fuse_, bytes calldata data_) external {
        address(fuse_).functionDelegateCall(data_);
    }
}
