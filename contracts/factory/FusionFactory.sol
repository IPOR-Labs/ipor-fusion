// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {RewardsClaimManagerFactory} from "./RewardsClaimManagerFactory.sol";
import {WithdrawManagerFactory} from "./WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "./ContextManagerFactory.sol";
import {PriceOracleMiddlewareManagerFactory} from "./PriceOracleMiddlewareManagerFactory.sol";
import {PlasmaVaultFactory} from "./PlasmaVaultFactory.sol";
import {IporFusionAccessManagerFactory} from "./IporFusionAccessManagerFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FeeConfig} from "../managers/fee/FeeManagerFactory.sol";
import {DataForInitialization} from "../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PlasmaVaultInitData, MarketSubstratesConfig, MarketBalanceFuseConfig} from "../vaults/PlasmaVault.sol";
import {IporFusionAccessManagerInitializerLibV1} from "../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {FeeManager} from "../managers/fee/FeeManager.sol";
import {RecipientFee} from "../managers/fee/FeeManagerFactory.sol";
import {IPlasmaVaultGovernance} from "../interfaces/IPlasmaVaultGovernance.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {FeeAccount} from "../managers/fee/FeeAccount.sol";

/// @title FusionFactory
/// @notice Factory contract for creating and managing Fusion Managers
/// @dev This contract is responsible for deploying and initializing various manager contracts
contract FusionFactory is UUPSUpgradeable, OwnableUpgradeable {
    /// @notice Addresses of the individual manager factories
    address public rewardsClaimManagerFactory;
    address public feeManagerFactory;
    address public withdrawManagerFactory;
    address public contextManagerFactory;
    address public priceOracleMiddlewareManagerFactory;
    address public plasmaVaultFactory;
    address public plasmaVaultBase;
    address public iporFusionAccessManagerFactory;

    /// @notice Default price oracle middleware address
    address public priceOracleMiddleware;
    /// @notice Default IPOR DAO management fee in basis points
    uint16 public iporDaoManagementFee;
    /// @notice Default IPOR DAO performance fee in basis points
    uint16 public iporDaoPerformanceFee;
    /// @notice Default IPOR DAO fee recipient address
    address public iporDaoFeeRecipient;

    /// @notice Emitted when a new RewardsClaimManager is created
    event RewardsClaimManagerCreated(address indexed manager, address indexed plasmaVault);

    /// @notice Emitted when a new FeeManager is created
    event FeeManagerCreated(address indexed manager, address indexed plasmaVault);

    /// @notice Emitted when a new WithdrawManager is created
    event WithdrawManagerCreated(address indexed manager);

    /// @notice Emitted when a new ContextManager is created
    event ContextManagerCreated(address indexed manager);

    /// @notice Emitted when a new PriceOracleMiddlewareManager is created
    event PriceOracleMiddlewareManagerCreated(address indexed manager, address indexed priceOracleMiddleware);

    /// @notice Emitted when a new PlasmaVault is created
    event PlasmaVaultCreated(address indexed vault, address indexed underlyingToken);

    /// @notice Emitted when a new IporFusionAccessManager is created
    event IporFusionAccessManagerCreated(address indexed manager);

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

    struct FusionAddresses {
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
    /// @param rewardsClaimManagerFactory_ Address of the RewardsClaimManagerFactory
    /// @param feeManagerFactory_ Address of the FeeManagerFactory
    /// @param withdrawManagerFactory_ Address of the WithdrawManagerFactory
    /// @param contextManagerFactory_ Address of the ContextManagerFactory
    /// @param priceOracleMiddlewareManagerFactory_ Address of the PriceOracleMiddlewareManagerFactory
    /// @param plasmaVaultFactory_ Address of the PlasmaVaultFactory
    /// @param iporFusionAccessManagerFactory_ Address of the IporFusionAccessManagerFactory
    /// @param priceOracleMiddleware_ Default price oracle middleware address
    
    function initialize(
        address rewardsClaimManagerFactory_,
        address feeManagerFactory_,
        address withdrawManagerFactory_,
        address contextManagerFactory_,
        address priceOracleMiddlewareManagerFactory_,
        address plasmaVaultFactory_,
        address iporFusionAccessManagerFactory_,
        address priceOracleMiddleware_
    ) external initializer {
        __Ownable_init(msg.sender);

        if (rewardsClaimManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (feeManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (withdrawManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (contextManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (priceOracleMiddlewareManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (plasmaVaultFactory_ == address(0)) revert InvalidFactoryAddress();
        if (iporFusionAccessManagerFactory_ == address(0)) revert InvalidFactoryAddress();
        if (priceOracleMiddleware_ == address(0)) revert InvalidAddress();

        rewardsClaimManagerFactory = rewardsClaimManagerFactory_;
        feeManagerFactory = feeManagerFactory_;
        withdrawManagerFactory = withdrawManagerFactory_;
        contextManagerFactory = contextManagerFactory_;
        priceOracleMiddlewareManagerFactory = priceOracleMiddlewareManagerFactory_;
        plasmaVaultFactory = plasmaVaultFactory_;
        iporFusionAccessManagerFactory = iporFusionAccessManagerFactory_;
        priceOracleMiddleware = priceOracleMiddleware_;
    }

    /// @notice Creates a complete PlasmaVault setup with all necessary managers
    /// @param assetName_ Name of the vault's share token
    /// @param assetSymbol_ Symbol of the vault's share token
    /// @param underlyingToken_ Address of the token that the vault accepts for deposits
    /// @param owner_ The owner address for access control
    /// @return fusionAddresses The addresses of the created managers
    function createCompletePlasmaVault(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        address owner_
    ) external returns (FusionAddresses memory fusionAddresses) {
        fusionAddresses.plasmaVaultBase = plasmaVaultBase;
        fusionAddresses.accessManager = _createIporFusionAccessManager(address(this));
        fusionAddresses.withdrawManager = _createWithdrawManager(fusionAddresses.accessManager);
        fusionAddresses.priceManager = _createPriceOracleMiddlewareManager(fusionAddresses.accessManager, priceOracleMiddleware);

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: assetName_,
            assetSymbol: assetSymbol_,
            underlyingToken: underlyingToken_,
            priceOracleMiddleware: priceOracleMiddleware,
            marketSubstratesConfigs: new MarketSubstratesConfig[](0),
            fuses: new address[](0),
            balanceFuses: new MarketBalanceFuseConfig[](0),
            feeConfig: FeeConfig({
                feeFactory: feeManagerFactory,
                iporDaoManagementFee: iporDaoManagementFee,
                iporDaoPerformanceFee: iporDaoPerformanceFee,
                iporDaoFeeRecipientAddress: iporDaoFeeRecipient,
                recipientManagementFees: new RecipientFee[](0),
                recipientPerformanceFees: new RecipientFee[](0)
            }),
            accessManager: fusionAddresses.accessManager,
            plasmaVaultBase: fusionAddresses.plasmaVaultBase,
            totalSupplyCap: type(uint256).max,
            withdrawManager: fusionAddresses.withdrawManager
        });

        fusionAddresses.plasmaVault = _createPlasmaVault(initData);
        fusionAddresses.rewardsManager = _createRewardsManager(fusionAddresses.accessManager, fusionAddresses.plasmaVault);

        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = fusionAddresses.plasmaVault;

        fusionAddresses.contextManager = _createContextManager(fusionAddresses.accessManager, approvedAddresses);

         PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData = IPlasmaVaultGovernance(
            fusionAddresses.plasmaVault
        ).getPerformanceFeeData();

        fusionAddresses.feeManager = FeeAccount(performanceFeeData.feeAccount).FEE_MANAGER();

        // Prepare access data with owner
        DataForInitialization memory accessData;
        accessData.isPublic = false;
        accessData.owners = new address[](1);
        accessData.owners[0] = owner_;

        FeeManager(fusionAddresses.feeManager).initialize();

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
    function _authorizeUpgrade(address newImplementation) internal override {}

    /// @notice Creates a new RewardsClaimManager
    /// @param accessManager_ The initial authority address for access control
    /// @param plasmaVault_ Address of the plasma vault
    /// @return Address of the newly created RewardsClaimManager
    function _createRewardsManager(address accessManager_, address plasmaVault_) private returns (address) {
        address manager = RewardsClaimManagerFactory(rewardsClaimManagerFactory).createRewardsClaimManager(
            accessManager_,
            plasmaVault_
        );
        emit RewardsClaimManagerCreated(manager, plasmaVault_);
        return manager;
    }

    /// @notice Creates a new WithdrawManager
    /// @param accessManager_ The initial authority address for access control
    /// @return Address of the newly created WithdrawManager
    function _createWithdrawManager(address accessManager_) private returns (address) {
        address manager = WithdrawManagerFactory(withdrawManagerFactory).createWithdrawManager(
            accessManager_
        );
        emit WithdrawManagerCreated(manager);
        return manager;
    }

    /// @notice Creates a new ContextManager
    /// @param accessManager_ The initial authority address for access control
    /// @return Address of the newly created ContextManager
    function _createContextManager(address accessManager_, address[] memory approvedTargets_) private returns (address) {
        address manager = ContextManagerFactory(contextManagerFactory).createContextManager(accessManager_, approvedTargets_);
        emit ContextManagerCreated(manager);
        return manager;
    }

    /// @notice Creates a new PriceOracleMiddlewareManager
    /// @param accessManager_ The initial authority address for access control
    /// @param priceOracleMiddleware_ Address of the price oracle middleware
    /// @return Address of the newly created PriceOracleMiddlewareManager
    function _createPriceOracleMiddlewareManager(
        address accessManager_,
        address priceOracleMiddleware_
    ) private returns (address) {
        address manager = PriceOracleMiddlewareManagerFactory(priceOracleMiddlewareManagerFactory)
            .createPriceOracleMiddlewareManager(accessManager_, priceOracleMiddleware_);
        emit PriceOracleMiddlewareManagerCreated(manager, priceOracleMiddleware_);
        return manager;
    }

    /// @notice Creates a new PlasmaVault
    /// @param initData_ The initialization data for the PlasmaVault
    /// @return Address of the newly created PlasmaVault
    function _createPlasmaVault(PlasmaVaultInitData memory initData_) private returns (address) {
        address vault = PlasmaVaultFactory(plasmaVaultFactory).createPlasmaVault(initData_);
        emit PlasmaVaultCreated(vault, initData_.underlyingToken);
        return vault;
    }

    /// @notice Creates a new IporFusionAccessManager
    /// @param initialAuthority_ The initial authority address for access control
    /// @return Address of the newly created IporFusionAccessManager
    function _createIporFusionAccessManager(address initialAuthority_) private returns (address) {
        address manager = IporFusionAccessManagerFactory(iporFusionAccessManagerFactory).createIporFusionAccessManager(
            initialAuthority_
        );
        emit IporFusionAccessManagerCreated(manager);
        return manager;
    }
}
