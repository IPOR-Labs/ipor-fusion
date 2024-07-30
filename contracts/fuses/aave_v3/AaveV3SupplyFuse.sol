// SPDX-License-Identifier: BUSL-1.1
/**
 * @title AaveV3SupplyFuseEnterData
 * This contract is used for integrating the Plasma Vault with AAVE Protocol version 3.
 * All actions performed by the code from this fuse are executed in the context of the Plasma Vault and are invoked using delegateCall.
 *
 * Deploy:
 * To deploy a new implementation, the following parameters must be provided:
 * - marketId_ - This should be selected from the IporFusionMarkets*.sol file; if the appropriate value is missing, it should be added.
 * - aavePool_ - The address of the AAVE Pool contract.
 * - aavePoolDataProviderV3_ - The address of the AAVE Pool Data Provider V3 contract.
 *
 *
 * Uses in Plasma Vault:
 * - Add fuse to Plasma Vault
 *      To use this fuse in the Plasma Vault, it should be added using one of two methods:
 *      - addFuses(address[] calldata fuses_) from PlasmaVaultGovernance, where only the fuse address is provided.
 *      - pass the address in the constructor inside PlasmaVaultInitData.fuses.
 * - Configurate Plasma Vault to use this fuse
 *      To configure the fuse on the Plasma Vault, the following steps should be performed:
 *      - Call the method grantMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) where marketId_
 *        is the value provided in the fuse constructor, and substrates_ contains the address of the token/asset that
 *        will be managed by the fuse. The address should be converted using the method PlasmaVaultConfigLib.addressToBytes32(address asset).
 *      - Adding a BalanceFuse using the method addBalanceFuse(uint256 marketId_, address fuse_) — details can be found
 *        inside the AaveV3BalanceFuse.sol file.
 *      - [Optional] Set a percentage limit on how much funds can be transferred to the market using the method
 *        setupMarketsLimits(MarketLimit[] calldata marketsLimits_). For detailed information, please refer to the method's documentation.
 *      - [Optional] If the Plasma Vault allows withdrawals without a queue, you should add it to instant withdrawal
 *         using the method configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses_).
 *      - [Optional] If invoking this fuse affects other markets whose balances are changing and you need to update the
 *        balances for other markets, call the method function updateDependencyBalanceGraphs(uint256[] memory marketIds_, uint256[][] memory dependencies_).
 * - Using the fuse by Alpha
 *   To use the fuse after configuration within the Plasma Vault, you need to call the method function execute(FuseAction[] calldata calls_), where:
 *      - When executing the enter method, the parameters that need to be provided within AaveV3SupplyFuseEnterData must be as follows:
 *        - asset - the address of the asset/token to be transferred, which must have been added during the fuse configuration.
 *        - amount - the value to be transferred, which must be specified in the asset/token's decimals.
 *        - userEModeCategoryId is a value passed to AAVE; values greater than 255 are ignored. For details, please refer to the AAVE documentation.
 *      - When executing the exit method, the parameters that need to be provided within AaveV3SupplyFuseExitData must be as follows:
 *        - asset - the address of the asset/token to be transferred, which must have been added during the fuse configuration.
 *        - amount - the value to be transferred, which must be specified in the asset/token's decimals.
 */
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuse} from "../IFuse.sol";
import {IPool} from "./ext/IPool.sol";
import {IAavePoolDataProvider} from "./ext/IAavePoolDataProvider.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct AaveV3SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
    /// @notice user eMode category if pass value bigger than 255 is ignored and not set
    uint256 userEModeCategoryId;
}

struct AaveV3SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

contract AaveV3SupplyFuse is IFuse, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    IPool public immutable AAVE_POOL;
    address public immutable AAVE_POOL_DATA_PROVIDER_V3;

    event AaveV3SupplyEnterFuse(address version, address asset, uint256 amount, uint256 userEModeCategoryId);
    event AaveV3SupplyExitFuse(address version, address asset, uint256 amount);
    event AaveV3SupplyExitFailed(address version, address asset, uint256 amount);

    error AaveV3SupplyFuseUnsupportedAsset(string action, address asset);

    constructor(uint256 marketId_, address aavePool_, address aavePoolDataProviderV3_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_POOL = IPool(aavePool_);
        AAVE_POOL_DATA_PROVIDER_V3 = aavePoolDataProviderV3_;
    }

    function enter(bytes calldata data_) external override {
        _enter(abi.decode(data_, (AaveV3SupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(AaveV3SupplyFuseEnterData memory data_) external {
        _enter(data_);
    }

    function exit(bytes calldata data_) external override {
        _exit(abi.decode(data_, (AaveV3SupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(AaveV3SupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(AaveV3SupplyFuseExitData(asset, amount));
    }

    function _enter(AaveV3SupplyFuseEnterData memory data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("enter", data_.asset);
        }

        ERC20(data_.asset).forceApprove(address(AAVE_POOL), data_.amount);

        AAVE_POOL.supply(data_.asset, data_.amount, address(this), 0);

        if (data_.userEModeCategoryId <= type(uint8).max) {
            AAVE_POOL.setUserEMode(data_.userEModeCategoryId.toUint8());
        }

        emit AaveV3SupplyEnterFuse(VERSION, data_.asset, data_.amount, data_.userEModeCategoryId);
    }

    function _exit(AaveV3SupplyFuseExitData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("exit", data.asset);
        }

        (address aTokenAddress, , ) = IAavePoolDataProvider(AAVE_POOL_DATA_PROVIDER_V3).getReserveTokensAddresses(
            data.asset
        );

        try
            AAVE_POOL.withdraw(
                data.asset,
                IporMath.min(ERC20(aTokenAddress).balanceOf(address(this)), data.amount),
                address(this)
            )
        returns (uint256 withdrawnAmount) {
            emit AaveV3SupplyExitFuse(VERSION, data.asset, withdrawnAmount);
        } catch {
            /// @dev if withdraw failed, continue with the next step
            emit AaveV3SupplyExitFailed(VERSION, data.asset, data.amount);
        }
    }
}
