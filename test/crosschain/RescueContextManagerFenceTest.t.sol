// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {PlasmaVault, PlasmaVaultInitData, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ContextManager, ExecuteData} from "../../contracts/managers/context/ContextManager.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    UpdateVaults,
    OutboundTransfer
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {IporFusionAccessManagerHelper} from "../test_helpers/IporFusionAccessManagerHelper.sol";
import {MutableValuePriceFeed} from "../managers/MutableValuePriceFeed.sol";

/// @title RescueContextManagerFenceTest
/// @notice IL-8770 on real contracts: a dispatcher holding tracked shares of a real `PlasmaVault` whose real
///         `ContextManager` approves the vault as a target. A rescue whose calldata is
///         `ContextManager.runWithContext({vault.approve(ADMIN, max)})` would make the dispatcher the context
///         sender, grant the rescue admin a share allowance (the share balance stays put, so the IL-8556
///         snapshot passes) and let the admin redeem outside the timelock. The attack must fail at schedule.
contract RescueContextManagerFenceTest is Test {
    using OptionsBuilder for bytes;
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant ASSET_ID = keccak256("USDC");
    bytes32 internal constant GUID = keccak256("guid");

    address internal constant ATOMIST = TestAddresses.ATOMIST;
    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    PlasmaVault internal vault;
    ContextManager internal contextManager;
    StargateCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        _deployVault();
        _deployDispatcher();

        // The dispatcher holds tracked shares: allowlist the vault, bridge assets in, DEPOSIT them.
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256("uv"),
                    sequence: 0,
                    newConfigEpoch: 1,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults
                })
            )
        );
        usdc.mint(address(dispatcher), 100e6);
        bytes memory composeMsg = LzComposeBuilder.build(
            address(dispatcher),
            EXECUTOR_EID,
            100e6,
            CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: keccak256("t1")}))
        );
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: keccak256("dep"),
                    sequence: 1,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e6, 0)
                })
            )
        );
    }

    function _runWithContextApprove() internal view returns (bytes memory) {
        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));
        return abi.encodeCall(ContextManager.runWithContext, (ExecuteData({targets: targets, datas: datas})));
    }

    /// @notice The attack must fail: the schedule is rejected, no allowance is granted, the admin cannot redeem.
    function testShouldBlockContextManagerApproveRescueOnDispatcherShares() public {
        uint256 shares = vault.balanceOf(address(dispatcher));
        assertGt(shares, 0, "dispatcher holds shares");
        assertTrue(dispatcher.isTrackedVault(address(vault)), "vault tracked");
        bytes memory cd = _runWithContextApprove();

        vm.prank(admin);
        (bool scheduled, bytes memory ret) = address(dispatcher).call(
            abi.encodeCall(dispatcher.scheduleRescue, (address(contextManager), 0, cd))
        );
        assertFalse(scheduled, "schedule must revert");
        assertEq(
            ret,
            abi.encodeWithSelector(CrosschainErrors.RescueContextCall.selector, address(contextManager)),
            "RescueContextCall(contextManager)"
        );
        assertEq(dispatcher.rescueCount(), 0, "nothing queued");

        assertEq(vault.allowance(address(dispatcher), admin), 0, "no share allowance");
        vm.prank(admin);
        (bool redeemed, ) = address(vault).call(
            abi.encodeWithSignature("redeem(uint256,address,address)", shares, admin, address(dispatcher))
        );
        assertFalse(redeemed, "admin cannot redeem the dispatcher's shares");
        assertEq(vault.balanceOf(address(dispatcher)), shares, "shares intact");
    }

    /// @notice Control: the context mechanism the attack relies on is real. A direct `runWithContext` makes
    ///         its own caller the vault's `msg.sender`, which is why the rescue host must never be that caller.
    function testRunWithContextMakesCallerTheVaultSender() public {
        uint256 shares = vault.balanceOf(address(dispatcher));
        bytes memory cd = _runWithContextApprove();
        vm.prank(address(dispatcher));
        (bool ok, ) = address(contextManager).call(cd);
        assertTrue(ok, "runWithContext has no role gate");
        assertEq(vault.allowance(address(dispatcher), admin), type(uint256).max, "caller became the sender");

        // Without the fence the admin drains the dispatcher's shares outside the timelock.
        uint256 before = usdc.balanceOf(admin);
        vm.prank(admin);
        vault.redeem(shares, admin, address(dispatcher));
        assertEq(vault.balanceOf(address(dispatcher)), 0, "dispatcher shares redeemed");
        assertEq(usdc.balanceOf(admin) - before, 50e6, "admin received the payout");
    }

    function _deliver(bytes memory envelope_) internal {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

    function _deployDispatcher() internal {
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(0xF),
            admin,
            guardian,
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);
    }

    function _deployVault() internal {
        IporFusionAccessManager accessManager = new IporFusionAccessManager(ATOMIST, 0);
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        PriceOracleMiddleware oracleImpl = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware oracle = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(oracleImpl), abi.encodeWithSignature("initialize(address)", ATOMIST)))
        );
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        address[] memory sources = new address[](1);
        sources[0] = address(new MutableValuePriceFeed(1e18));
        vm.prank(ATOMIST);
        oracle.setAssetsPricesSources(assets, sources);

        address plasmaVaultBase = vm.deployCode("PlasmaVaultBase.sol:PlasmaVaultBase");
        address feeFactory = vm.deployCode("FeeManagerFactory.sol:FeeManagerFactory");
        vault = PlasmaVault(vm.deployCode("PlasmaVault.sol:PlasmaVault"));

        vm.startPrank(ATOMIST);
        vault.proxyInitialize(
            PlasmaVaultInitData({
                assetName: "Context Fence Vault",
                assetSymbol: "cfv",
                underlyingToken: address(usdc),
                priceOracleMiddleware: address(oracle),
                feeConfig: FeeConfig({
                    iporDaoManagementFee: 0,
                    iporDaoPerformanceFee: 0,
                    feeFactory: feeFactory,
                    iporDaoFeeRecipientAddress: TestAddresses.IPOR_DAO_FEE_RECIPIENT_ADDRESS
                }),
                accessManager: address(accessManager),
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: address(withdrawManager),
                plasmaVaultVotesPlugin: address(0)
            })
        );
        RewardsClaimManager rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(vault));
        // The helper deploys a ContextManager approving the vault and grants it TECH_CONTEXT_MANAGER_ROLE.
        contextManager = accessManager.setupInitRoles(vault, address(withdrawManager), address(rewardsClaimManager));
        vm.stopPrank();
    }
}
