// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {
    ConfigureInstantWithdrawalFuse,
    ConfigureInstantWithdrawalFuseEnterData
} from "../../contracts/fuses/maintenance/ConfigureInstantWithdrawalFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {InstantWithdrawalFusesParamsStruct, PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

/// @title PlasmaVaultInstantWithdrawalEmptyParamsTest
/// @notice An instant withdrawal fuse entry with an empty params array must be rejected at configuration time,
///         otherwise PlasmaVaultMarketsLib.withdrawFromMarkets later panics on params[0] (IL-8836, 9rich A1)
contract PlasmaVaultInstantWithdrawalEmptyParamsTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    address public atomist = address(this);
    address public alpha = address(0x1);

    address private constant FUSE_A = address(0x1000);
    address private constant FUSE_B = address(0x1001);

    PriceOracleMiddleware private priceOracleMiddlewareProxy;
    PlasmaVault private plasmaVault;
    ConfigureInstantWithdrawalFuse private configureFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        IporFusionAccessManager accessManager = RoleLib.createAccessManager(usersToRoles, 0, vm);
        address withdrawManager = address(new WithdrawManager(address(accessManager)));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                withdrawManager,
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, withdrawManager);

        configureFuse = new ConfigureInstantWithdrawalFuse(IporFusionMarkets.ZERO_BALANCE_MARKET);

        address[] memory fuses = new address[](3);
        fuses[0] = FUSE_A;
        fuses[1] = FUSE_B;
        fuses[2] = address(configureFuse);
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        IPlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET))
        );
    }

    function testShouldRevertWhenGovernanceConfiguresEmptyParams() public {
        // given
        InstantWithdrawalFusesParamsStruct[] memory cfg = new InstantWithdrawalFusesParamsStruct[](1);
        cfg[0] = InstantWithdrawalFusesParamsStruct(FUSE_A, new bytes32[](0));

        // when / then
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultLib.InstantWithdrawalFuseEmptyParams.selector, FUSE_A));
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(cfg);
    }

    function testShouldRevertWhenMaintenanceFuseConfiguresEmptyParams() public {
        // given
        InstantWithdrawalFusesParamsStruct[] memory cfg = new InstantWithdrawalFusesParamsStruct[](1);
        cfg[0] = InstantWithdrawalFusesParamsStruct(FUSE_A, new bytes32[](0));
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(configureFuse),
            data: abi.encodeWithSelector(
                ConfigureInstantWithdrawalFuse.enter.selector,
                ConfigureInstantWithdrawalFuseEnterData({fuses: cfg})
            )
        });

        // when / then
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultLib.InstantWithdrawalFuseEmptyParams.selector, FUSE_A));
        vm.prank(alpha);
        plasmaVault.execute(actions);
    }

    function testShouldConfigureNonEmptyParamsThroughMaintenanceFuse() public {
        // given
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(uint256(1));
        params[1] = bytes32(uint256(2));
        InstantWithdrawalFusesParamsStruct[] memory cfg = new InstantWithdrawalFusesParamsStruct[](1);
        cfg[0] = InstantWithdrawalFusesParamsStruct(FUSE_A, params);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(configureFuse),
            data: abi.encodeWithSelector(
                ConfigureInstantWithdrawalFuse.enter.selector,
                ConfigureInstantWithdrawalFuseEnterData({fuses: cfg})
            )
        });

        // when
        vm.prank(alpha);
        plasmaVault.execute(actions);

        // then
        address[] memory fuses = IPlasmaVaultGovernance(address(plasmaVault)).getInstantWithdrawalFuses();
        assertEq(fuses.length, 1, "fuses length");
        assertEq(fuses[0], FUSE_A, "fuse");
        bytes32[] memory stored = IPlasmaVaultGovernance(address(plasmaVault)).getInstantWithdrawalFusesParams(
            FUSE_A,
            0
        );
        assertEq(stored.length, 2, "params length");
        assertEq(stored[0], params[0], "params[0]");
        assertEq(stored[1], params[1], "params[1]");
    }

    function testShouldKeepPreviousConfigurationWhenOneEntryHasEmptyParams() public {
        // given a valid previous configuration
        bytes32[] memory previousParams = new bytes32[](2);
        previousParams[0] = bytes32(uint256(11));
        previousParams[1] = bytes32(uint256(22));
        InstantWithdrawalFusesParamsStruct[] memory previous = new InstantWithdrawalFusesParamsStruct[](1);
        previous[0] = InstantWithdrawalFusesParamsStruct(FUSE_A, previousParams);
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(previous);

        // and a mixed list: first entry valid, second entry empty
        bytes32[] memory validParams = new bytes32[](2);
        validParams[0] = bytes32(uint256(1));
        validParams[1] = bytes32(uint256(2));
        InstantWithdrawalFusesParamsStruct[] memory mixed = new InstantWithdrawalFusesParamsStruct[](2);
        mixed[0] = InstantWithdrawalFusesParamsStruct(FUSE_B, validParams);
        mixed[1] = InstantWithdrawalFusesParamsStruct(FUSE_A, new bytes32[](0));

        // when
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultLib.InstantWithdrawalFuseEmptyParams.selector, FUSE_A));
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(mixed);

        // then the previous configuration is untouched
        address[] memory fusesAfter = IPlasmaVaultGovernance(address(plasmaVault)).getInstantWithdrawalFuses();
        assertEq(fusesAfter.length, 1, "fuses length");
        assertEq(fusesAfter[0], FUSE_A, "fuse");
        bytes32[] memory paramsAfter = IPlasmaVaultGovernance(address(plasmaVault)).getInstantWithdrawalFusesParams(
            FUSE_A,
            0
        );
        assertEq(paramsAfter.length, 2, "params length");
        assertEq(paramsAfter[0], bytes32(uint256(11)), "params[0]");
        assertEq(paramsAfter[1], bytes32(uint256(22)), "params[1]");
    }

    function testShouldConfigureInstantWithdrawalFusesWithNonEmptyParams() public {
        // given
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(uint256(1));
        params[1] = bytes32(uint256(2));
        InstantWithdrawalFusesParamsStruct[] memory cfg = new InstantWithdrawalFusesParamsStruct[](1);
        cfg[0] = InstantWithdrawalFusesParamsStruct(FUSE_A, params);

        // when
        IPlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(cfg);

        // then
        address[] memory fuses = IPlasmaVaultGovernance(address(plasmaVault)).getInstantWithdrawalFuses();
        assertEq(fuses.length, 1, "fuses length");
        assertEq(fuses[0], FUSE_A, "fuse");
        bytes32[] memory stored = IPlasmaVaultGovernance(address(plasmaVault)).getInstantWithdrawalFusesParams(
            FUSE_A,
            0
        );
        assertEq(stored.length, 2, "params length");
        assertEq(stored[0], params[0], "params[0]");
        assertEq(stored[1], params[1], "params[1]");
    }
}
