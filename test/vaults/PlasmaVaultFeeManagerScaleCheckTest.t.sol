// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultFeesLib} from "../../contracts/vaults/lib/PlasmaVaultFeesLib.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeManagerFactory, FeeConfig, FeeManagerData} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManagerInitData} from "../../contracts/managers/fee/FeeManager.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @dev A FeeManager built before IL-9601: no HIGH_WATER_MARK_SCALE(), and a fallback-less contract reverts on it
contract OldStyleFeeManager {}

/// @dev A FeeManager that reports another scale than 1e12
contract WrongScaleFeeManager {
    uint256 public immutable HIGH_WATER_MARK_SCALE;

    constructor(uint256 scale_) {
        HIGH_WATER_MARK_SCALE = scale_;
    }
}

/// @dev A FeeManager whose HIGH_WATER_MARK_SCALE() returns more than one word
contract LongReturnFeeManager {
    fallback() external {
        assembly {
            mstore(0, 1000000000000)
            mstore(0x20, 0)
            return(0, 0x40)
        }
    }
}

/// @dev Factory that returns the FeeManager address of the test instead of deploying a real one
contract FeeManagerFactoryReturning {
    address public feeManager;

    constructor(address feeManager_) {
        feeManager = feeManager_;
    }

    function deployFeeManager(FeeManagerInitData memory) external view returns (FeeManagerData memory data) {
        data.feeManager = feeManager;
        data.plasmaVault = msg.sender;
        data.performanceFeeAccount = address(0x7E57);
        data.managementFeeAccount = address(0x7E58);
    }
}

/// @title PlasmaVaultFeeManagerScaleCheckTest
/// @notice IL-9601 (D-068): a new vault checks once, when it creates its FeeManager, that the FeeManager reports
///         HIGH_WATER_MARK_SCALE() = 1e12. A FeeManager of an older build (old FeeManagerFactory paired with a new
///         vault) makes the vault creation revert with FeeManagerScaleMismatch(feeManager).
contract PlasmaVaultFeeManagerScaleCheckTest is Test {
    address public atomist = address(this);
    MockERC20Decimals public asset;
    PriceOracleMiddleware public oracle;
    IporFusionAccessManager public accessManager;
    address public vaultBase;
    address public withdrawManager;

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        oracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        sources[0] = address(new FixedValuePriceFeed(1e8));
        oracle.setAssetsPricesSources(assets, sources);

        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        vaultBase = address(new PlasmaVaultBase());
        withdrawManager = address(new WithdrawManager(address(accessManager)));
    }

    function testShouldCreateVault_whenFeeManagerFactoryIsCurrent() public {
        PlasmaVault vault = _createVault(address(new FeeManagerFactory()));
        assertEq(vault.name(), "IPOR Fusion mUSDC");
    }

    function testShouldRevertWithFeeManagerAddress_whenFeeManagerHasNoScale() public {
        address oldFeeManager = address(new OldStyleFeeManager());
        _expectMismatchOnCreate(oldFeeManager);
    }

    function testShouldRevertWithFeeManagerAddress_whenFeeManagerReportsWrongScale() public {
        _expectMismatchOnCreate(address(new WrongScaleFeeManager(1e6)));
        _expectMismatchOnCreate(address(new WrongScaleFeeManager(0)));
        _expectMismatchOnCreate(address(new WrongScaleFeeManager(1e18)));
    }

    function testShouldRevertWithFeeManagerAddress_whenScaleCallReturnsMoreThanOneWord() public {
        _expectMismatchOnCreate(address(new LongReturnFeeManager()));
    }

    function testShouldRevertWithFeeManagerAddress_whenFeeManagerAddressHasNoCode() public {
        _expectMismatchOnCreate(address(0xBEEF));
    }

    function _expectMismatchOnCreate(address feeManager_) internal {
        address factory = address(new FeeManagerFactoryReturning(feeManager_));
        PlasmaVault vault = PlasmaVaultCloneLib.newPlasmaVault();
        PlasmaVaultInitData memory initData = _initData(factory);
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultFeesLib.FeeManagerScaleMismatch.selector, feeManager_));
        vault.proxyInitialize(initData);
    }

    function _createVault(address feeFactory_) internal returns (PlasmaVault vault) {
        vault = PlasmaVaultCloneLib.newPlasmaVault();
        vault.proxyInitialize(_initData(feeFactory_));
    }

    function _initData(address feeFactory_) internal view returns (PlasmaVaultInitData memory) {
        return
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(oracle),
                FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: feeFactory_,
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                vaultBase,
                withdrawManager,
                address(0)
            );
    }
}
