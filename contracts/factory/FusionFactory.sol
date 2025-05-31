// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {RewardsManagerFactory} from "./RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "./WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "./ContextManagerFactory.sol";
import {PriceManagerFactory} from "./PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "./PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "./AccessManagerFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FeeConfig} from "../managers/fee/FeeManagerFactory.sol";
import {DataForInitialization} from "../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PlasmaVaultInitData} from "../vaults/PlasmaVault.sol";
import {IporFusionAccessManagerInitializerLibV1} from "../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {FeeManager} from "../managers/fee/FeeManager.sol";

import {IPlasmaVaultGovernance} from "../interfaces/IPlasmaVaultGovernance.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {FeeAccount} from "../managers/fee/FeeAccount.sol";
import {IRewardsClaimManager} from "../interfaces/IRewardsClaimManager.sol";
import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";
import {IporFusionMarkets} from "../libraries/IporFusionMarkets.sol";

/// @title FusionFactory
/// @notice Factory contract for creating and managing Fusion Managers
/// @dev This contract is responsible for deploying and initializing various manager contracts
contract FusionFactory is UUPSUpgradeable, OwnableUpgradeable {
    /// @notice Addresses of the individual manager factories
    address public rewardsManagerFactory;
    address public feeManagerFactory;
    address public withdrawManagerFactory;
    address public contextManagerFactory;
    address public priceManagerFactory;
    address public plasmaVaultFactory;
    address public plasmaVaultBase;
    address public accessManagerFactory;

    /// @notice Default price oracle middleware address
    address public priceOracleMiddleware;
    /// @notice Default IPOR DAO management fee in basis points
    uint16 public iporDaoManagementFee;
    /// @notice Default IPOR DAO performance fee in basis points
    uint16 public iporDaoPerformanceFee;
    /// @notice Default IPOR DAO fee recipient address
    address public iporDaoFeeRecipient;

    /// @notice Default redemption delay in seconds
    uint256 public redemptionDelayInSeconds; // default 1 second

    uint256 public withdrawWindowInSeconds; // default 24 hours

    uint256 public vestingPeriodInSeconds; // default 2 weeks

    address public balanceFuseBurnRequestFee;
    address public burnRequestFeeFuse;

    /// @notice Emitted when default price oracle middleware is updated
    event PriceOracleMiddlewareUpdated(address indexed newPriceOracleMiddleware);
    /// @notice Emitted when default IPOR DAO management fee is updated
    event IporDaoManagementFeeUpdated(uint16 newFee);
    /// @notice Emitted when default IPOR DAO performance fee is updated
    event IporDaoPerformanceFeeUpdated(uint16 newFee);
    /// @notice Emitted when default IPOR DAO fee recipient is updated
    event IporDaoFeeRecipientUpdated(address indexed newRecipient);

    error InvalidFactoryAddress();
    error InvalidFeeValue();
    error InvalidAddress();
    error BurnRequestFeeFuseNotSet();
    error BalanceFuseBurnRequestFeeNotSet();

    struct FusionInstance {
        string assetName;
        string assetSymbol;
        address underlyingToken;
        address initialOwner;
        address plasmaVault;
        address plasmaVaultBase;
        address accessManager;
        address feeManager;
        address rewardsManager;
        address withdrawManager;
        address priceManager;
        address contextManager;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address plasmaVaultBase_) {
        _disableInitializers();
        if (plasmaVaultBase_ == address(0)) revert InvalidFactoryAddress();
        plasmaVaultBase = plasmaVaultBase_;
    }

    /// @notice Initializes the FusionFactory contract
    /// @param rewardsManagerFactory_ Address of the RewardsManagerFactory
    /// @param feeManagerFactory_ Address of the FeeManagerFactory
    /// @param withdrawManagerFactory_ Address of the WithdrawManagerFactory
    /// @param contextManagerFactory_ Address of the ContextManagerFactory
    /// @param priceManagerFactory_ Address of the PriceManagerFactory
    /// @param plasmaVaultFactory_ Address of the PlasmaVaultFactory
    /// @param accessManagerFactory_ Address of the AccessManagerFactory
    /// @param priceOracleMiddleware_ Default price oracle middleware address

    function initialize(
        address rewardsManagerFactory_,
        address feeManagerFactory_,
        address withdrawManagerFactory_,
        address contextManagerFactory_,
        address priceManagerFactory_,
        address plasmaVaultFactory_,
        address accessManagerFactory_,
        address priceOracleMiddleware_
    ) external initializer {
        __Ownable_init(msg.sender);

        if (rewardsManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (feeManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (withdrawManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (contextManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (priceManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (plasmaVaultFactory_ == address(0)) revert InvalidFactoryAddress();
        if (accessManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (priceOracleMiddleware_ == address(0)) revert InvalidAddress();

        rewardsManagerFactory = rewardsManagerFactory_;
        feeManagerFactory = feeManagerFactory_;
        withdrawManagerFactory = withdrawManagerFactory_;
        contextManagerFactory = contextManagerFactory_;
        priceManagerFactory = priceManagerFactory_;
        plasmaVaultFactory = plasmaVaultFactory_;
        accessManagerFactory = accessManagerFactory_;
        priceOracleMiddleware = priceOracleMiddleware_;

        redemptionDelayInSeconds = 1; // TODO: change to default value
    }

    /// @notice Creates a complete PlasmaVault setup with all necessary managers
    /// @param assetName_ Name of the vault's share token
    /// @param assetSymbol_ Symbol of the vault's share token
    /// @param underlyingToken_ Address of the token that the vault accepts for deposits
    /// @param owner_ The owner address for access control
    /// @return fusionAddresses The addresses of the created managers
    function getInstance(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        address owner_
    ) external returns (FusionInstance memory fusionAddresses) {
        fusionAddresses.assetName = assetName_;
        fusionAddresses.assetSymbol = assetSymbol_;
        fusionAddresses.underlyingToken = underlyingToken_;
        fusionAddresses.initialOwner = owner_;
        fusionAddresses.plasmaVaultBase = plasmaVaultBase;

        fusionAddresses.accessManager = AccessManagerFactory(accessManagerFactory).getInstance(
            address(this),
            redemptionDelayInSeconds
        );
        fusionAddresses.withdrawManager = WithdrawManagerFactory(withdrawManagerFactory).getInstance(
            fusionAddresses.accessManager
        );
        fusionAddresses.priceManager = PriceManagerFactory(priceManagerFactory).getInstance(
            fusionAddresses.accessManager,
            priceOracleMiddleware
        );

        fusionAddresses.plasmaVault = PlasmaVaultFactory(plasmaVaultFactory).getInstance(
            PlasmaVaultInitData({
                assetName: assetName_,
                assetSymbol: assetSymbol_,
                underlyingToken: underlyingToken_,
                priceOracleMiddleware: priceOracleMiddleware,
                feeConfig: FeeConfig({
                    feeFactory: feeManagerFactory,
                    iporDaoManagementFee: iporDaoManagementFee,
                    iporDaoPerformanceFee: iporDaoPerformanceFee,
                    iporDaoFeeRecipientAddress: iporDaoFeeRecipient
                }),
                accessManager: fusionAddresses.accessManager,
                plasmaVaultBase: fusionAddresses.plasmaVaultBase,
                withdrawManager: fusionAddresses.withdrawManager
            })
        );
        fusionAddresses.rewardsManager = RewardsManagerFactory(rewardsManagerFactory).getInstance(
            fusionAddresses.accessManager,
            fusionAddresses.plasmaVault
        );

        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = fusionAddresses.plasmaVault;

        fusionAddresses.contextManager = ContextManagerFactory(contextManagerFactory).getInstance(
            fusionAddresses.accessManager,
            approvedAddresses
        );

        PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = IPlasmaVaultGovernance(
            fusionAddresses.plasmaVault
        ).getPerformanceFeeData();

        fusionAddresses.feeManager = FeeAccount(performanceFeeData.feeAccount).FEE_MANAGER();

        IRewardsClaimManager(fusionAddresses.rewardsManager).setupVestingTime(vestingPeriodInSeconds);

        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).setRewardsClaimManagerAddress(
            fusionAddresses.rewardsManager
        );

        WithdrawManager(fusionAddresses.withdrawManager).updateWithdrawWindow(withdrawWindowInSeconds);
        WithdrawManager(fusionAddresses.withdrawManager).updatePlasmaVaultAddress(fusionAddresses.plasmaVault);

        if (burnRequestFeeFuse == address(0)) revert BurnRequestFeeFuseNotSet();
        address[] memory fuses = new address[](1);
        fuses[0] = burnRequestFeeFuse;
        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).addFuses(fuses);

        if (balanceFuseBurnRequestFee == address(0)) revert BalanceFuseBurnRequestFeeNotSet();
        IPlasmaVaultGovernance(fusionAddresses.plasmaVault).addBalanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            balanceFuseBurnRequestFee
        );

        FeeManager(fusionAddresses.feeManager).initialize();

        DataForInitialization memory accessData;
        accessData.isPublic = false;
        accessData.owners = new address[](1);
        accessData.owners[0] = owner_;

        IporFusionAccessManager(fusionAddresses.accessManager).initialize(
            IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(accessData)
        );

        return fusionAddresses;
    }

    /// @notice Updates the default price oracle middleware address
    /// @param newPriceOracleMiddleware_ New price oracle middleware address
    function updatePriceOracleMiddleware(address newPriceOracleMiddleware_) external onlyOwner {
        if (newPriceOracleMiddleware_ == address(0)) revert InvalidAddress();
        priceOracleMiddleware = newPriceOracleMiddleware_;
        emit PriceOracleMiddlewareUpdated(newPriceOracleMiddleware_);
    }

    /// @notice Updates the default IPOR DAO management fee
    /// @param newFee_ New management fee in basis points
    function updateIporDaoManagementFee(uint16 newFee_) external onlyOwner {
        if (newFee_ > 5000) revert InvalidFeeValue(); // 50% max
        iporDaoManagementFee = newFee_;
        emit IporDaoManagementFeeUpdated(newFee_);
    }

    /// @notice Updates the default IPOR DAO performance fee
    /// @param newFee_ New performance fee in basis points
    function updateIporDaoPerformanceFee(uint16 newFee_) external onlyOwner {
        if (newFee_ > 5000) revert InvalidFeeValue(); // 50% max
        iporDaoPerformanceFee = newFee_;
        emit IporDaoPerformanceFeeUpdated(newFee_);
    }

    /// @notice Updates the default IPOR DAO fee recipient
    /// @param newRecipient_ New fee recipient address
    function updateIporDaoFeeRecipient(address newRecipient_) external onlyOwner {
        if (newRecipient_ == address(0)) revert InvalidAddress();
        iporDaoFeeRecipient = newRecipient_;
        emit IporDaoFeeRecipientUpdated(newRecipient_);
    }

    /// @dev Required by the OZ UUPS module
    /// @param newImplementation Address of the new implementation
    //TODO: add owner
    function _authorizeUpgrade(address newImplementation) internal override {}
}
