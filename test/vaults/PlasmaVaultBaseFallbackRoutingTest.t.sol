// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultVotesPlugin} from "../../contracts/vaults/plugins/PlasmaVaultVotesPlugin.sol";
import {IPlasmaVaultVotesPlugin} from "../../contracts/interfaces/IPlasmaVaultVotesPlugin.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {CallbackHandlerLib} from "../../contracts/libraries/CallbackHandlerLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {SettableBalanceFuseMock} from "./mocks/SettableBalanceFuseMock.sol";

/// @notice Fuse that, executed by the vault through delegatecall, makes the helper call the vault back
contract CallbackPokeFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    function poke(address helper_, bytes calldata data_) external {
        CallbackHelper(helper_).poke(address(this), data_);
    }
}

/// @notice External contract that plays the role of a protocol calling back into the vault
contract CallbackHelper {
    function poke(address vault_, bytes calldata data_) external {
        (bool ok, bytes memory ret) = vault_.call(data_);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @notice Callback handler returning empty data (no follow-up actions)
contract EmptyCallbackHandler {
    uint256 public calls;

    fallback() external {
        ++calls;
    }
}

/// @notice USD price feed with a constant price of 1 and 18 decimals
contract ConstantPriceFeed {
    function decimals() external pure returns (uint8) {
        return 18;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 1e18, block.timestamp, block.timestamp, 1);
    }
}

contract TestToken is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title PlasmaVaultBaseFallbackRoutingTest
/// @notice IL-8681 T36: Votes selector routing lives in the PlasmaVaultBase fallback, the deposit fee goes through
///         the fee rate. Behaviour must be identical to the previous PlasmaVault fallback / FeeManager.calculateDepositFee
/// @dev Stands in for a PlasmaVaultBase deployed before the Votes routing moved into its fallback: it has no fallback
contract LegacyBaseWithoutFallbackStub {
    function cap() external pure returns (uint256) {
        return 0;
    }
}

contract PlasmaVaultBaseFallbackRoutingTest is Test {
    address private constant _ATOMIST = address(0x1);
    address private constant _ALPHA = address(0x5);
    address private constant _ALICE = address(0x2);
    address private constant _BOB = address(0x3);

    TestToken private _underlying;
    PlasmaVaultBase private _base;
    PlasmaVaultVotesPlugin private _plugin;
    PriceOracleMiddleware private _priceOracle;
    UsersToRoles private _usersToRoles;

    function setUp() public {
        _underlying = new TestToken();
        _underlying.mint(_ALICE, 1e30);
        _underlying.mint(_BOB, 1e30);

        _priceOracle = new PriceOracleMiddleware(address(0));
        _priceOracle.initialize(_ATOMIST);
        address[] memory assets = new address[](1);
        assets[0] = address(_underlying);
        address[] memory sources = new address[](1);
        sources[0] = address(new ConstantPriceFeed());
        vm.prank(_ATOMIST);
        _priceOracle.setAssetsPricesSources(assets, sources);
        _base = new PlasmaVaultBase();
        _plugin = new PlasmaVaultVotesPlugin();

        _usersToRoles.superAdmin = _ATOMIST;
        _usersToRoles.atomist = _ATOMIST;
        _usersToRoles.alphas = new address[](1);
        _usersToRoles.alphas[0] = _ALPHA;
        _usersToRoles.performanceFeeManagers = new address[](0);
        _usersToRoles.managementFeeManagers = new address[](0);
        _usersToRoles.feeTimelock = 0;
    }

    function _deployVault(
        bool withPlugin_
    ) private returns (PlasmaVault vault, IporFusionAccessManager accessManager, address withdrawManager) {
        accessManager = RoleLib.createAccessManager(_usersToRoles, 0, vm);
        withdrawManager = address(new WithdrawManager(address(accessManager)));

        vm.startPrank(_ATOMIST);
        vault = new PlasmaVault();
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Plasma Vault Token",
                assetSymbol: "PVT",
                underlyingToken: address(_underlying),
                priceOracleMiddleware: address(_priceOracle),
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: address(accessManager),
                plasmaVaultBase: address(_base),
                withdrawManager: withdrawManager,
                plasmaVaultVotesPlugin: withPlugin_ ? address(_plugin) : address(0)
            })
        );
        vm.stopPrank();

        RoleLib.setupPlasmaVaultRoles(_usersToRoles, vm, address(vault), accessManager, withdrawManager);
    }

    function _votesCalls() private view returns (bytes[] memory calls) {
        calls = new bytes[](10);
        calls[0] = abi.encodeCall(IVotes.getVotes, (_ALICE));
        calls[1] = abi.encodeCall(IVotes.getPastVotes, (_ALICE, 0));
        calls[2] = abi.encodeCall(IVotes.getPastTotalSupply, (0));
        calls[3] = abi.encodeCall(IVotes.delegates, (_ALICE));
        calls[4] = abi.encodeCall(IVotes.delegate, (_BOB));
        calls[5] = abi.encodeCall(IVotes.delegateBySig, (_BOB, 0, 0, 0, bytes32(0), bytes32(0)));
        calls[6] = abi.encodeCall(IERC6372.clock, ());
        calls[7] = abi.encodeCall(IERC6372.CLOCK_MODE, ());
        calls[8] = abi.encodeCall(IPlasmaVaultVotesPlugin.numCheckpoints, (_ALICE));
        calls[9] = abi.encodeCall(IPlasmaVaultVotesPlugin.checkpoints, (_ALICE, 0));
    }

    // ---------------------------------------------------------------------
    // Votes routing through PlasmaVaultBase
    // ---------------------------------------------------------------------

    function testVotesSelectorsReachPluginThroughBase() public {
        (PlasmaVault vault, , ) = _deployVault(true);
        address vaultAddr = address(vault);

        vm.startPrank(_ALICE);
        _underlying.approve(vaultAddr, 1000e18);
        uint256 shares = vault.deposit(1000e18, _ALICE);

        // state-changing and view calls with a real result
        IVotes(vaultAddr).delegate(_ALICE);
        vm.stopPrank();
        vm.roll(block.number + 1);

        assertEq(IVotes(vaultAddr).getVotes(_ALICE), shares, "getVotes");
        assertEq(IVotes(vaultAddr).delegates(_ALICE), _ALICE, "delegates");
        assertEq(IVotes(vaultAddr).getPastVotes(_ALICE, block.number - 1), shares, "getPastVotes");
        assertEq(IVotes(vaultAddr).getPastTotalSupply(block.number - 1), shares, "getPastTotalSupply");
        assertEq(IERC6372(vaultAddr).clock(), uint48(block.number), "clock");
        assertEq(IERC6372(vaultAddr).CLOCK_MODE(), "mode=blocknumber&from=default", "CLOCK_MODE");
        assertEq(IPlasmaVaultVotesPlugin(vaultAddr).numCheckpoints(_ALICE), 1, "numCheckpoints");
        assertEq(IPlasmaVaultVotesPlugin(vaultAddr).checkpoints(_ALICE, 0)._value, shares, "checkpoints");

        // delegateBySig is routed too: an expired signature is rejected by the plugin, not by the router
        (bool ok, bytes memory ret) = vaultAddr.call(
            abi.encodeCall(IVotes.delegateBySig, (_BOB, 0, 0, 0, bytes32(0), bytes32(0)))
        );
        assertFalse(ok, "expired signature must revert");
        // exact plugin-side error (OZ Votes): proves the call reached the plugin through both fallbacks
        assertEq(
            ret,
            abi.encodeWithSelector(bytes4(keccak256("VotesExpiredSignature(uint256)")), uint256(0)),
            "expired"
        );
    }

    function testEveryVotesSelectorRevertsWithoutPlugin() public {
        (PlasmaVault vault, , ) = _deployVault(false);
        bytes[] memory calls = _votesCalls();
        assertEq(calls.length, 10);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(_ALICE);
            (bool ok, bytes memory ret) = address(vault).call(calls[i]);
            assertFalse(ok, "must revert");
            assertEq(ret, abi.encodeWithSelector(PlasmaVault.VotesPluginNotEnabled.selector), "VotesPluginNotEnabled");
        }
        assertEq(PlasmaVault.VotesPluginNotEnabled.selector, PlasmaVaultBase.VotesPluginNotEnabled.selector);
    }

    function testEveryVotesSelectorIsRoutedWithPlugin() public {
        (PlasmaVault vault, , ) = _deployVault(true);
        bytes[] memory calls = _votesCalls();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(_ALICE);
            (bool ok, bytes memory ret) = address(vault).call(calls[i]);
            if (!ok) {
                // only the plugin may reject here (delegateBySig with an expired signature, checkpoints index)
                assertTrue(bytes4(ret) != PlasmaVaultBase.VotesPluginNotEnabled.selector, "not routed");
                assertTrue(bytes4(ret) != bytes4(keccak256("FailedInnerCall()")), "unrouted selector");
                assertTrue(ret.length >= 4, "plugin error data");
                // only these two may be rejected by the plugin itself
                assertTrue(i == 5 || i == 9, "unexpected revert");
            }
        }
    }

    function testUnknownSelectorRevertsEmpty() public {
        bytes memory data = abi.encodeWithSelector(bytes4(0xdeadbeef), uint256(1));

        (PlasmaVault withPlugin, , ) = _deployVault(true);
        (bool ok, bytes memory ret) = address(withPlugin).call(data);
        assertFalse(ok, "unknown selector (plugin)");
        // the base reverts with empty data, which the PlasmaVault delegatecall wrapper reports as FailedInnerCall
        assertEq(bytes4(ret), bytes4(keccak256("FailedInnerCall()")), "FailedInnerCall (plugin)");

        (PlasmaVault noPlugin, , ) = _deployVault(false);
        (ok, ret) = address(noPlugin).call(data);
        assertFalse(ok, "unknown selector (no plugin)");
        assertEq(bytes4(ret), bytes4(keccak256("FailedInnerCall()")), "FailedInnerCall (no plugin)");

        // empty calldata and a bare ETH-less call hit the same path
        (ok, ret) = address(noPlugin).call("");
        assertFalse(ok, "empty calldata");
    }

    function testDirectCallToBaseReverts() public {
        bytes[] memory calls = _votesCalls();
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = address(_base).call(calls[i]);
            assertFalse(ok, "votes selector on the bare base");
            // no plugin is stored in the implementation's own storage
            assertEq(bytes4(ret), PlasmaVaultBase.VotesPluginNotEnabled.selector);
        }
        (bool ok2, bytes memory ret2) = address(_base).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok2, "unknown selector on the bare base");
        assertEq(ret2.length, 0);
    }

    function testTransferVotingUnitsIsNotRoutedThroughVault() public {
        (PlasmaVault vault, , ) = _deployVault(true);
        address vaultAddr = address(vault);
        address attacker = address(0xBAD);

        vm.startPrank(_ALICE);
        _underlying.approve(vaultAddr, 1000e18);
        uint256 shares = vault.deposit(1000e18, _ALICE);
        IVotes(vaultAddr).delegate(_ALICE);
        vm.stopPrank();

        vm.startPrank(attacker);
        IVotes(vaultAddr).delegate(attacker);
        // the plugin's external transferVotingUnits is unprotected, so it must not be reachable through the vault
        (bool ok, bytes memory ret) = vaultAddr.call(
            abi.encodeCall(IPlasmaVaultVotesPlugin.transferVotingUnits, (address(0), attacker, 1e30))
        );
        vm.stopPrank();

        assertFalse(ok, "transferVotingUnits must not be routed");
        assertEq(bytes4(ret), bytes4(keccak256("FailedInnerCall()")), "FailedInnerCall");

        vm.roll(block.number + 1);
        assertEq(IVotes(vaultAddr).getVotes(attacker), 0, "attacker got no votes");
        assertEq(IVotes(vaultAddr).getPastTotalSupply(block.number - 1), vault.totalSupply(), "past supply");
        assertEq(vault.totalSupply(), shares, "vault supply");
    }

    function testNewVaultOnBaseWithoutFallbackRevertsFailedInnerCall() public {
        bytes memory legacyCode = address(new LegacyBaseWithoutFallbackStub()).code;
        bytes memory realCode = address(_base).code;
        bytes4 failedInnerCall = bytes4(keccak256("FailedInnerCall()"));

        // reference: the real base without a plugin reports VotesPluginNotEnabled for clock()
        (PlasmaVault realNoPlugin, , ) = _deployVault(false);
        (bool okReal, bytes memory retReal) = address(realNoPlugin).call(abi.encodeCall(IERC6372.clock, ()));
        assertFalse(okReal, "real base without plugin reverts");
        assertEq(bytes4(retReal), PlasmaVaultBase.VotesPluginNotEnabled.selector, "VotesPluginNotEnabled");
        assertEq(bytes4(retReal), bytes4(0xf95053ca), "VotesPluginNotEnabled selector");

        for (uint256 v; v < 2; ++v) {
            // initialization needs the real base, the legacy code is etched in only afterwards
            vm.etch(address(_base), realCode);
            (PlasmaVault vault, , ) = _deployVault(v == 1);
            vm.etch(address(_base), legacyCode);

            bytes[] memory calls = _votesCalls();
            for (uint256 i; i < calls.length; ++i) {
                (bool ok, bytes memory ret) = address(vault).call(calls[i]);
                assertFalse(ok, "votes selector on legacy base");
                assertEq(bytes4(ret), failedInnerCall, "FailedInnerCall");
            }

            (bool okClock, bytes memory retClock) = address(vault).call(abi.encodeCall(IERC6372.clock, ()));
            assertFalse(okClock, "clock on legacy base");
            assertEq(bytes4(retClock), bytes4(0x1425ea42), "FailedInnerCall selector");
        }
    }

    function testBaseFunctionsStillReachableThroughVault() public {
        (PlasmaVault vault, , ) = _deployVault(false);
        // totalSupplyCap is implemented by PlasmaVaultBase and must still be served via the PlasmaVault fallback
        assertEq(PlasmaVaultBase(address(vault)).cap(), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // During execute() the fallback goes to the callback handler, as before
    // ---------------------------------------------------------------------

    function testCallbackDuringExecuteGoesToHandlerNotVotesPlugin() public {
        (PlasmaVault vault, IporFusionAccessManager accessManager, ) = _deployVault(true);
        CallbackHelper helper = new CallbackHelper();
        CallbackPokeFuse fuse = new CallbackPokeFuse(777);
        SettableBalanceFuseMock balanceFuse = new SettableBalanceFuseMock(777);
        EmptyCallbackHandler handler = new EmptyCallbackHandler();

        vm.startPrank(_ATOMIST);
        bytes4[] memory sig = new bytes4[](1);
        sig[0] = PlasmaVaultGovernance.updateCallbackHandler.selector;
        accessManager.setTargetFunctionRole(address(vault), sig, Roles.ATOMIST_ROLE);
        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);
        PlasmaVaultGovernance(address(vault)).addFuses(fuses);
        PlasmaVaultGovernance(address(vault)).addBalanceFuse(777, address(balanceFuse));
        // a handler is registered for a Votes selector called by the helper
        PlasmaVaultGovernance(address(vault)).updateCallbackHandler(
            address(handler),
            address(helper),
            IVotes.getVotes.selector
        );
        vm.stopPrank();

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(fuse),
            abi.encodeCall(CallbackPokeFuse.poke, (address(helper), abi.encodeCall(IVotes.getVotes, (_ALICE))))
        );
        vm.prank(_ALPHA);
        vault.execute(actions);
        assertEq(handler.calls(), 1, "callback handler was called, not the votes plugin");

        // a Votes selector without a registered handler is a HandlerNotFound, not routed to the plugin
        actions[0] = FuseAction(
            address(fuse),
            abi.encodeCall(CallbackPokeFuse.poke, (address(helper), abi.encodeCall(IVotes.delegates, (_ALICE))))
        );
        vm.prank(_ALPHA);
        vm.expectRevert(CallbackHandlerLib.HandlerNotFound.selector);
        vault.execute(actions);

        // outside execute the same Votes selector is routed to the plugin again
        assertEq(IVotes(address(vault)).delegates(_ALICE), address(0));
    }

    // ---------------------------------------------------------------------
    // Deposit fee: identical to FeeManager.calculateDepositFee
    // ---------------------------------------------------------------------

    function _feeManagerOf(PlasmaVault vault_) private view returns (FeeManager) {
        return
            FeeManager(
                FeeAccount(PlasmaVaultGovernance(address(vault_)).getPerformanceFeeData().feeAccount).FEE_MANAGER()
            );
    }

    function _setDepositFee(PlasmaVault vault_, IporFusionAccessManager accessManager_, uint256 fee_) private {
        FeeManager feeManager = _feeManagerOf(vault_);
        bytes4[] memory sig = new bytes4[](1);
        sig[0] = FeeManager.setDepositFee.selector;
        vm.startPrank(_ATOMIST);
        accessManager_.setTargetFunctionRole(address(feeManager), sig, Roles.ATOMIST_ROLE);
        feeManager.setDepositFee(fee_);
        vm.stopPrank();
    }

    function testFuzz_depositFeeMatchesFeeManager(uint256 fee_, uint256 assets_, uint256 seed_) public {
        fee_ = bound(fee_, 0, 1e17);
        assets_ = bound(assets_, 1e6, 1e27);
        seed_ = bound(seed_, 1e18, 1e24);

        (PlasmaVault vault, IporFusionAccessManager accessManager, address withdrawManager) = _deployVault(false);
        _setDepositFee(vault, accessManager, fee_);
        FeeManager feeManager = _feeManagerOf(vault);

        // a prior depositor makes the share price non-trivial; the fee recipient is the withdraw manager
        vm.startPrank(_BOB);
        _underlying.approve(address(vault), type(uint256).max);
        vault.deposit(seed_, _BOB);
        vm.stopPrank();
        _underlying.mint(address(vault), seed_ / 7);

        uint256 previewNet = vault.previewDeposit(assets_);
        uint256 recipientBefore = vault.balanceOf(withdrawManager);

        vm.startPrank(_ALICE);
        _underlying.approve(address(vault), type(uint256).max);
        uint256 net = vault.deposit(assets_, _ALICE);
        vm.stopPrank();

        uint256 feeShares = vault.balanceOf(withdrawManager) - recipientBefore;
        assertEq(net, previewNet, "preview equals deposit");
        assertEq(
            feeShares,
            feeManager.calculateDepositFee(net + feeShares),
            "fee equals FeeManager.calculateDepositFee"
        );
        assertEq(feeShares, fee_ == 0 ? 0 : ((net + feeShares) * fee_) / 1e18, "fee equals mulDiv(gross, rate, 1e18)");
    }

    function testDepositFeeReadFromZeroFeeManagerReverts() public {
        (PlasmaVault vault, IporFusionAccessManager accessManager, ) = _deployVault(false);
        _setDepositFee(vault, accessManager, 1e16);
        address feeAccount = PlasmaVaultGovernance(address(vault)).getPerformanceFeeData().feeAccount;

        vm.mockCall(feeAccount, abi.encodeWithSignature("FEE_MANAGER()"), abi.encode(address(0)));
        vm.expectRevert(bytes(""));
        vault.previewDeposit(1e18);
        vm.expectRevert(bytes(""));
        vault.maxDeposit(_ALICE);
    }
}
