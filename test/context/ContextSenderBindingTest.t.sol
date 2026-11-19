// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev IL-9533 (3sigma #6): while ContextManager relays a call, the stored context sender must be returned only to the
///      ContextManager that set it. Code that gets control during the relayed call (a malicious ERC4626 venue reached
///      through the instant-withdraw fuses, a token with a transfer hook) and calls back into the client acts as itself,
///      not as the relayed user. Before the fix the venue could approve the attacker on the user's shares (and drain
///      them in the same transaction through runWithContextAndSignature), move the user's shares with transfer, or
///      spend a RewardsClaimManager role of the relayed caller.
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {PlasmaVault, PlasmaVaultInitData, FuseAction} from "contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultCloneLib} from "test/test_helpers/PlasmaVaultCloneLib.sol";
import {PlasmaVaultBase} from "contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "contracts/vaults/PlasmaVaultGovernance.sol";
import {InstantWithdrawalFusesParamsStruct} from "contracts/libraries/PlasmaVaultLib.sol";
import {IporFusionAccessManager} from "contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "contracts/managers/rewards/RewardsClaimManager.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    DataForInitialization,
    PlasmaVaultAddress,
    InitializationData
} from "contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeAccount} from "contracts/managers/fee/FeeAccount.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {ContextManager, ExecuteData, ContextDataWithSender} from "contracts/managers/context/ContextManager.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {IporFusionMarkets} from "contracts/libraries/IporFusionMarkets.sol";
import {FeeConfigHelper} from "test/test_helpers/FeeConfigHelper.sol";

contract ContextSenderBindingMockToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

contract ContextSenderBindingMockOracle is IPriceOracleMiddleware {
    function QUOTE_CURRENCY() external pure returns (address) {
        return address(0x0000000000000000000000000000000000000348);
    }

    function QUOTE_CURRENCY_DECIMALS() external pure returns (uint256) {
        return 8;
    }

    function getAssetPrice(address) external pure returns (uint256, uint256) {
        return (1e8, 8);
    }

    function getAssetsPrices(
        address[] calldata assets_
    ) external pure returns (uint256[] memory prices, uint256[] memory decimalsList) {
        prices = new uint256[](assets_.length);
        decimalsList = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            prices[i] = 1e8;
            decimalsList[i] = 8;
        }
    }

    function getSourceOfAssetPrice(address) external pure returns (address) {
        return address(0);
    }

    function setAssetsPricesSources(address[] calldata, address[] calldata) external {}
}

/// @dev ERC4626 venue granted as a market substrate that calls back into the vault (msg.sender of withdraw/redeem is
///      the PlasmaVault, because the supply fuse runs in the vault's context) before it pays out. The callback is
///      wrapped in try/catch so the payout continues; the outcome is recorded for the test.
contract ContextSenderBindingMaliciousVenue is ERC4626 {
    enum Mode {
        NONE,
        APPROVE,
        TRANSFER
    }

    Mode public mode;
    address public attacker;
    uint256 public transferAmount;
    uint256 public callbackCount;
    bool public lastCallbackOk;
    bytes public lastCallbackError;

    constructor(IERC20 asset_) ERC20("Malicious venue", "MV") ERC4626(asset_) {}

    function arm(Mode mode_, address attacker_, uint256 transferAmount_) external {
        mode = mode_;
        attacker = attacker_;
        transferAmount = transferAmount_;
    }

    function withdraw(uint256 assets_, address receiver_, address owner_) public override returns (uint256) {
        _callback(msg.sender);
        return super.withdraw(assets_, receiver_, owner_);
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        _callback(msg.sender);
        return super.redeem(shares_, receiver_, owner_);
    }

    function _callback(address plasmaVault_) private {
        if (mode == Mode.NONE) {
            return;
        }

        ++callbackCount;

        if (mode == Mode.APPROVE) {
            try IERC20(plasmaVault_).approve(attacker, type(uint256).max) returns (bool ok) {
                lastCallbackOk = ok;
            } catch (bytes memory error_) {
                lastCallbackOk = false;
                lastCallbackError = error_;
            }
        } else {
            try IERC20(plasmaVault_).transfer(attacker, transferAmount) returns (bool ok) {
                lastCallbackOk = ok;
            } catch (bytes memory error_) {
                lastCallbackOk = false;
                lastCallbackError = error_;
            }
        }
    }
}

/// @dev Relays a victim's signed redeem through runWithContextAndSignature and tries to drain the victim's remaining
///      shares in the same transaction with the allowance the malicious venue set during the relayed call.
contract ContextSenderBindingSignedRelayAttacker {
    uint256 public drainedAssets;
    bytes public drainError;

    function relayAndDrain(
        ContextManager contextManager_,
        ContextDataWithSender[] calldata batch_,
        PlasmaVault plasmaVault_,
        address victim_,
        uint256 shares_
    ) external {
        contextManager_.runWithContextAndSignature(batch_);

        try plasmaVault_.redeem(shares_, address(this), victim_) returns (uint256 assets) {
            drainedAssets = assets;
        } catch (bytes memory error_) {
            drainError = error_;
        }
    }
}

/// @dev Token with a transfer hook: when RewardsClaimManager.transfer moves it, it calls RewardsClaimManager.transfer
///      for another token while the relayed caller's context is still set on the RewardsClaimManager.
contract ContextSenderBindingHookToken is ERC20 {
    RewardsClaimManager public rewardsClaimManager;
    address public stolenToken;
    address public attacker;
    uint256 public stolenAmount;
    uint256 public callbackCount;
    bytes public lastCallbackError;

    constructor() ERC20("Hook token", "HOOK") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }

    function arm(
        RewardsClaimManager rewardsClaimManager_,
        address stolenToken_,
        address attacker_,
        uint256 amount_
    ) external {
        rewardsClaimManager = rewardsClaimManager_;
        stolenToken = stolenToken_;
        attacker = attacker_;
        stolenAmount = amount_;
    }

    function transfer(address to_, uint256 value_) public override returns (bool) {
        bool ok = super.transfer(to_, value_);

        if (msg.sender == address(rewardsClaimManager) && callbackCount == 0) {
            ++callbackCount;
            try rewardsClaimManager.transfer(stolenToken, attacker, stolenAmount) {} catch (bytes memory error_) {
                lastCallbackError = error_;
            }
        }

        return ok;
    }
}

contract ContextSenderBindingTest is Test {
    address internal constant _ATOMIST = address(1111111);
    address internal constant _ALPHA = address(2222222);
    address internal constant _USER = address(3333333);
    address internal constant _REWARDS_MANAGER = address(4444444);
    address internal constant _ATTACKER = address(0xBAD);
    address internal constant _RECIPIENT = address(0xB0B);

    uint256 internal constant _USER2_PK = 0xA11CE;
    uint256 internal constant _USER_DEPOSIT = 1_000e18;
    /// @dev Moved into the venue, so a redeem of half of the user's shares needs the instant-withdraw path
    uint256 internal constant _ALLOCATED = 1_800e18;
    uint256 internal constant _REWARDS_IN_MANAGER = 50e18;

    address internal _user2;

    ContextSenderBindingMockToken internal _token;
    ContextSenderBindingMockOracle internal _oracle;
    address internal _accessManager;
    address internal _plasmaVault;
    address internal _withdrawManager;
    RewardsClaimManager internal _rewardsClaimManager;
    ContextManager internal _contextManager;
    ContextSenderBindingMaliciousVenue internal _venue;
    Erc4626SupplyFuse internal _supplyFuse;

    function setUp() public {
        _user2 = vm.addr(_USER2_PK);
        _token = new ContextSenderBindingMockToken("Mock USD", "mUSD");
        _oracle = new ContextSenderBindingMockOracle();
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(_accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(PlasmaVaultCloneLib.newPlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "PLASMA VAULT",
                assetSymbol: "PLASMA",
                underlyingToken: address(_token),
                priceOracleMiddleware: address(_oracle),
                feeConfig: FeeConfigHelper.createZeroFeeConfig(),
                accessManager: _accessManager,
                plasmaVaultBase: address(new PlasmaVaultBase()),
                withdrawManager: _withdrawManager,
                plasmaVaultVotesPlugin: address(0)
            })
        );
        vm.stopPrank();

        _rewardsClaimManager = new RewardsClaimManager(_accessManager, _plasmaVault);

        address[] memory approvedTargets = new address[](2);
        approvedTargets[0] = _plasmaVault;
        approvedTargets[1] = address(_rewardsClaimManager);
        _contextManager = new ContextManager(_accessManager, approvedTargets);

        _initAccessManager();
        _configureVenueMarket();

        _depositDirect(_USER, _USER_DEPOSIT);
        _depositDirect(_user2, _USER_DEPOSIT);
        _allocateToVenue(_ALLOCATED);
    }

    // ---------------------------------------------------------------- regression: relayed redeem + re-entrant venue

    /// @dev runWithContext: the venue reached through the instant-withdraw fuse approves the attacker. The allowance
    ///      must be the venue's own (worthless), not the relayed user's.
    function testShouldNotGrantRelayedUserAllowanceToReentrantVenue() public {
        _venue.arm(ContextSenderBindingMaliciousVenue.Mode.APPROVE, _ATTACKER, 0);
        uint256 userShares = PlasmaVault(_plasmaVault).balanceOf(_USER);
        uint256 redeemShares = userShares / 2;
        uint256 expectedAssets = PlasmaVault(_plasmaVault).previewRedeem(redeemShares);
        uint256 userAssetsBefore = _token.balanceOf(_USER);

        _relay(_USER, _plasmaVault, _redeemData(redeemShares, _USER, _USER));

        assertGt(_venue.callbackCount(), 0, "venue callback was not reached during the relayed redeem");
        assertTrue(_venue.lastCallbackOk(), "venue approve call failed");
        assertEq(
            PlasmaVault(_plasmaVault).allowance(_USER, _ATTACKER),
            0,
            "re-entrant venue approved the attacker as the relayed user"
        );
        assertEq(
            PlasmaVault(_plasmaVault).allowance(address(_venue), _ATTACKER),
            type(uint256).max,
            "re-entrant approve must act as the venue itself"
        );
        assertEq(_token.balanceOf(_USER) - userAssetsBefore, expectedAssets, "relayed redeem payout");
        assertEq(PlasmaVault(_plasmaVault).balanceOf(_USER), userShares - redeemShares, "user shares after redeem");

        uint256 remainingShares = userShares - redeemShares;
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, _ATTACKER, 0, remainingShares)
        );
        vm.prank(_ATTACKER);
        PlasmaVault(_plasmaVault).redeem(remainingShares, _ATTACKER, _USER);
    }

    /// @dev runWithContextAndSignature: anyone can submit the victim's signed redeem. The attacker relays it and tries
    ///      to drain the victim's remaining shares in the same transaction.
    function testShouldNotLetSignedRelayerDrainSignerThroughReentrantVenue() public {
        ContextSenderBindingSignedRelayAttacker attacker = new ContextSenderBindingSignedRelayAttacker();
        _venue.arm(ContextSenderBindingMaliciousVenue.Mode.APPROVE, address(attacker), 0);
        uint256 userShares = PlasmaVault(_plasmaVault).balanceOf(_user2);
        uint256 redeemShares = userShares / 2;
        uint256 remainingShares = userShares - redeemShares;
        uint256 expectedAssets = PlasmaVault(_plasmaVault).previewRedeem(redeemShares);

        ContextDataWithSender[] memory batch = _signedBatch(
            _USER2_PK,
            _plasmaVault,
            _redeemData(redeemShares, _user2, _user2)
        );

        vm.prank(_ATTACKER);
        attacker.relayAndDrain(_contextManager, batch, PlasmaVault(_plasmaVault), _user2, remainingShares);

        assertGt(_venue.callbackCount(), 0, "venue callback was not reached during the relayed redeem");
        assertEq(attacker.drainedAssets(), 0, "attacker drained the signer in the same transaction");
        assertEq(
            attacker.drainError(),
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(attacker),
                0,
                remainingShares
            ),
            "drain must fail on the missing allowance"
        );
        assertEq(PlasmaVault(_plasmaVault).allowance(_user2, address(attacker)), 0, "signer allowance leaked");
        assertEq(PlasmaVault(_plasmaVault).balanceOf(_user2), remainingShares, "signer shares after redeem");
        assertEq(_token.balanceOf(_user2), expectedAssets, "signed relayed redeem payout");
        assertEq(_token.balanceOf(address(attacker)), 0, "attacker received assets");
    }

    /// @dev Share transfers enabled: the venue tries to move the relayed user's remaining shares with transfer. It must
    ///      act as itself and fail on its own (empty) balance.
    function testShouldNotLetReentrantVenueTransferRelayedUserShares() public {
        vm.prank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).enableTransferShares();

        uint256 userShares = PlasmaVault(_plasmaVault).balanceOf(_USER);
        uint256 redeemShares = userShares / 2;
        uint256 remainingShares = userShares - redeemShares;
        _venue.arm(ContextSenderBindingMaliciousVenue.Mode.TRANSFER, _ATTACKER, remainingShares);

        _relay(_USER, _plasmaVault, _redeemData(redeemShares, _USER, _USER));

        assertGt(_venue.callbackCount(), 0, "venue callback was not reached during the relayed redeem");
        assertEq(PlasmaVault(_plasmaVault).balanceOf(_ATTACKER), 0, "re-entrant venue moved the relayed user's shares");
        assertEq(PlasmaVault(_plasmaVault).balanceOf(_USER), remainingShares, "user shares after redeem");
        assertFalse(_venue.lastCallbackOk(), "venue transfer must fail");
        assertEq(
            _venue.lastCallbackError(),
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(_venue), 0, remainingShares),
            "re-entrant transfer must act as the venue itself"
        );
    }

    /// @dev RewardsClaimManager: the relayed caller holds TRANSFER_REWARDS_ROLE. A hooked token moved by
    ///      RewardsClaimManager.transfer calls RewardsClaimManager.transfer again during the context; it must be
    ///      authorized as itself, not with the relayed caller's role.
    function testShouldNotLetReentrantTokenUseRelayedRewardsManagerRole() public {
        ContextSenderBindingHookToken hookToken = new ContextSenderBindingHookToken();
        ContextSenderBindingMockToken rewardToken = new ContextSenderBindingMockToken("Reward", "RWD");
        hookToken.mint(address(_rewardsClaimManager), 1e18);
        rewardToken.mint(address(_rewardsClaimManager), _REWARDS_IN_MANAGER);
        hookToken.arm(_rewardsClaimManager, address(rewardToken), _ATTACKER, _REWARDS_IN_MANAGER);

        _relay(
            _REWARDS_MANAGER,
            address(_rewardsClaimManager),
            abi.encodeWithSelector(RewardsClaimManager.transfer.selector, address(hookToken), _RECIPIENT, 1e18)
        );

        assertEq(hookToken.callbackCount(), 1, "hook token callback was not reached during the relayed transfer");
        assertEq(hookToken.balanceOf(_RECIPIENT), 1e18, "relayed rewards transfer");
        assertEq(rewardToken.balanceOf(_ATTACKER), 0, "re-entrant token used the relayed caller's role");
        assertEq(rewardToken.balanceOf(address(_rewardsClaimManager)), _REWARDS_IN_MANAGER, "rewards left the manager");
        assertEq(
            hookToken.lastCallbackError(),
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(hookToken)),
            "re-entrant call must be authorized as the token itself"
        );
    }

    // ---------------------------------------------------------------- controls: relayed and direct calls still work

    function testShouldRedeemThroughContextManagerFromVenue() public {
        uint256 redeemShares = PlasmaVault(_plasmaVault).balanceOf(_USER) / 2;
        uint256 expectedAssets = PlasmaVault(_plasmaVault).previewRedeem(redeemShares);

        _relay(_USER, _plasmaVault, _redeemData(redeemShares, _RECIPIENT, _USER));

        assertEq(_token.balanceOf(_RECIPIENT), expectedAssets, "relayed redeem payout");
        assertLt(_token.balanceOf(address(_venue)), _ALLOCATED, "redeem did not pull from the venue");
    }

    function testShouldRedeemDirectlyFromVenue() public {
        uint256 redeemShares = PlasmaVault(_plasmaVault).balanceOf(_USER) / 2;
        uint256 expectedAssets = PlasmaVault(_plasmaVault).previewRedeem(redeemShares);

        vm.prank(_USER);
        PlasmaVault(_plasmaVault).redeem(redeemShares, _RECIPIENT, _USER);

        assertEq(_token.balanceOf(_RECIPIENT), expectedAssets, "direct redeem payout");
        assertLt(_token.balanceOf(address(_venue)), _ALLOCATED, "redeem did not pull from the venue");
    }

    /// @dev The relayed call itself still acts as the user: an approve sent through runWithContext is the user's.
    function testShouldApproveAsRelayedUserThroughContextManager() public {
        _relay(_USER, _plasmaVault, abi.encodeWithSelector(IERC20.approve.selector, _RECIPIENT, 123));

        assertEq(PlasmaVault(_plasmaVault).allowance(_USER, _RECIPIENT), 123, "relayed approve");
        assertEq(PlasmaVault(_plasmaVault).allowance(address(_contextManager), _RECIPIENT), 0, "manager allowance");
    }

    /// @dev Direct calls (no context) keep resolving to msg.sender.
    function testShouldApproveAsCallerWithoutContext() public {
        vm.prank(_USER);
        PlasmaVault(_plasmaVault).approve(_RECIPIENT, 456);

        assertEq(PlasmaVault(_plasmaVault).allowance(_USER, _RECIPIENT), 456, "direct approve");
    }

    // ---------------------------------------------------------------- helpers

    function _relay(address sender_, address target_, bytes memory data_) internal {
        address[] memory targets = new address[](1);
        targets[0] = target_;
        bytes[] memory datas = new bytes[](1);
        datas[0] = data_;
        vm.prank(sender_);
        _contextManager.runWithContext(ExecuteData({targets: targets, datas: datas}));
    }

    function _signedBatch(
        uint256 pk_,
        address target_,
        bytes memory data_
    ) internal view returns (ContextDataWithSender[] memory batch) {
        uint256 expiration = block.timestamp + 1 hours;
        uint256 nonce = 1;
        bytes32 digest = keccak256(
            abi.encodePacked(address(_contextManager), expiration, nonce, block.chainid, target_, data_)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk_, digest);
        batch = new ContextDataWithSender[](1);
        batch[0] = ContextDataWithSender({
            sender: vm.addr(pk_),
            expirationTime: expiration,
            nonce: nonce,
            target: target_,
            data: data_,
            signature: abi.encodePacked(r, s, v)
        });
    }

    function _redeemData(uint256 shares_, address receiver_, address owner_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(PlasmaVault.redeem.selector, shares_, receiver_, owner_);
    }

    function _depositDirect(address who_, uint256 amount_) internal {
        _token.mint(who_, amount_);
        vm.startPrank(who_);
        IERC20(address(_token)).approve(_plasmaVault, amount_);
        PlasmaVault(_plasmaVault).deposit(amount_, who_);
        vm.stopPrank();
    }

    function _configureVenueMarket() private {
        uint256 marketId = IporFusionMarkets.ERC4626_0001;
        _venue = new ContextSenderBindingMaliciousVenue(IERC20(address(_token)));
        _supplyFuse = new Erc4626SupplyFuse(marketId);

        address[] memory fuses = new address[](1);
        fuses[0] = address(_supplyFuse);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = bytes32(uint256(uint160(address(_venue))));
        bytes32[] memory params = new bytes32[](2);
        params[1] = substrates[0];
        InstantWithdrawalFusesParamsStruct[] memory instantWithdrawFuses = new InstantWithdrawalFusesParamsStruct[](1);
        instantWithdrawFuses[0] = InstantWithdrawalFusesParamsStruct({fuse: address(_supplyFuse), params: params});

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(marketId, address(new Erc4626BalanceFuse(marketId)));
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(marketId, substrates);
        PlasmaVaultGovernance(_plasmaVault).configureInstantWithdrawalFuses(instantWithdrawFuses);
        vm.stopPrank();
    }

    function _allocateToVenue(uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(_supplyFuse),
            data: abi.encodeWithSelector(
                Erc4626SupplyFuse.enter.selector,
                Erc4626SupplyFuseEnterData({vault: address(_venue), vaultAssetAmount: amount_, minSharesOut: 0})
            )
        });
        vm.prank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(actions);
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;
        address[] memory transferRewardsManagers = new address[](1);
        transferRewardsManagers[0] = _REWARDS_MANAGER;

        DataForInitialization memory data = DataForInitialization({
            isPublic: true,
            iporDaos: initAddress,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: new address[](0),
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: transferRewardsManagers,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(_rewardsClaimManager),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(_contextManager),
                priceOracleMiddlewareManager: address(0x123)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.prank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
    }
}
