// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

import {Test} from "forge-std/Test.sol";

import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";

import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";

import {PriceOracleMiddleware} from "../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";

contract PlasmaVaultErc20FusionTest is Test {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    PlasmaVault private plasmaVault;
    address private owner;
    uint256 private ownerPrivKey;
    address private spender;
    address private delegatee;

    string private assetName;
    string private assetSymbol;
    address private underlyingToken;
    address private alpha;
    uint256 private amount;
    uint256 private deadline;
    uint256 private nonce;

    PriceOracleMiddleware public priceOracleMiddlewareProxy;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        ownerPrivKey = 1;
        owner = vm.addr(ownerPrivKey);
        spender = address(0x1);
        delegatee = address(0x5);

        assetName = "IPOR Fusion USDC";
        assetSymbol = "ipfUSDC";
        underlyingToken = USDC;
        address[] memory alphas = new address[](1);

        alpha = address(0x1);
        alphas[0] = alpha;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));

        accessManager = createAccessManager(usersToRoles);

        plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase())
            )
        );

        setupRoles(plasmaVault, accessManager);
    }

    function testShouldNotCallFunctionUpdateInternal() public {
        //given
        address spender = address(0x1);
        bytes memory error = abi.encodeWithSignature("UnsupportedMethod()");

        //then
        vm.expectRevert(error);
        //when
        // solhint-disable-next-line  avoid-low-level-calls
        address(plasmaVault).call(
            abi.encodeWithSignature("updateInternal(address,address,uint256)", owner, spender, 100)
        );
    }

    function testERC20PermitShouldHaveAllowanceWhenPermit() public {
        //given
        uint256 value = 100 * 1e6;
        uint256 amount = 200 * 1e6;

        uint256 deadline = block.timestamp + 1 days;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(assetName)),
                keccak256(bytes("1")),
                block.chainid,
                address(plasmaVault)
            )
        );

        uint256 nonce = Nonces(address(plasmaVault)).nonces(owner);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivKey, digest);

        //when
        vm.prank(owner);
        IERC20Permit(address(plasmaVault)).permit(owner, spender, value, deadline, v, r, s);

        //then
        assertEq(plasmaVault.allowance(owner, spender), value);
    }

    function testErc20PermitShouldTransferWhenPermit() public {
        //given
        uint256 value = 100 * 1e6;
        uint256 amount = 200 * 1e6;

        uint256 deadline = block.timestamp + 1 days;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(assetName)),
                keccak256(bytes("1")),
                block.chainid,
                address(plasmaVault)
            )
        );

        uint256 nonce = Nonces(address(plasmaVault)).nonces(owner);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivKey, digest);

        vm.prank(owner);
        IERC20Permit(address(plasmaVault)).permit(owner, spender, value, deadline, v, r, s);

        bytes4[] memory sig = new bytes4[](2);
        sig[0] = PlasmaVault.transfer.selector;
        sig[1] = PlasmaVault.transferFrom.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.PUBLIC_ROLE);

        //when
        vm.prank(spender);
        plasmaVault.transferFrom(owner, spender, value);

        //then
        assertEq(plasmaVault.balanceOf(spender), value);
    }

    function testERC20VotesShouldShowVotes() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        /// @dev Activate checkpoint
        vm.prank(owner);
        IVotes(address(plasmaVault)).delegate(owner);

        //when
        uint256 votes = IVotes(address(plasmaVault)).getVotes(owner);

        //then
        assertEq(votes, amount);
    }

    function testERC20VotesShouldNOTShowVotes() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        //when
        uint256 votes = IVotes(address(plasmaVault)).getVotes(owner);

        //then
        assertEq(votes, 0);
    }

    function testERC20VotestShouldShowVotesInDelegatee() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        vm.prank(owner);
        IVotes(address(plasmaVault)).delegate(delegatee);

        //when
        uint256 votes = IVotes(address(plasmaVault)).getVotes(delegatee);

        //then
        assertEq(votes, amount);
    }

    function testERC20VotesShouldDelegateAndTransferAndNotChangeVotingPower() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        vm.prank(owner);
        IVotes(address(plasmaVault)).delegate(delegatee);

        // @dev Activate checkpoint
        vm.prank(delegatee);
        IVotes(address(plasmaVault)).delegate(delegatee);

        uint256 votesBefore = IVotes(address(plasmaVault)).getVotes(delegatee);

        bytes4[] memory sig = new bytes4[](1);
        sig[0] = PlasmaVault.transfer.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.PUBLIC_ROLE);

        //when
        vm.prank(owner);
        plasmaVault.transfer(delegatee, amount);

        //then
        uint256 votesAfter = IVotes(address(plasmaVault)).getVotes(delegatee);

        assertEq(votesBefore, votesAfter);
    }

    function testErc20VotesShouldDelegateFromOneDelegateeToAnotherOneNoTransferredAmount() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        vm.prank(owner);
        IVotes(address(plasmaVault)).delegate(delegatee);

        // @dev Activate checkpoint
        vm.prank(delegatee);
        IVotes(address(plasmaVault)).delegate(delegatee);

        uint256 votesBefore = IVotes(address(plasmaVault)).getVotes(delegatee);

        //when
        vm.prank(delegatee);
        IVotes(address(plasmaVault)).delegate(spender);

        //then
        uint256 votesAfter = IVotes(address(plasmaVault)).getVotes(spender);

        uint256 delegateeBalanceOf = plasmaVault.balanceOf(delegatee);

        assertNotEq(
            votesBefore,
            votesAfter,
            "New delegatee should have voting power equal to transferred amount to a delegatee"
        );
        assertEq(
            votesAfter,
            delegateeBalanceOf,
            "New delegatee should have voting power equal to transferred amount to a delegatee - balanceOf"
        );
    }

    function testErc20VotesShouldDelegateFromOneDelegateeToAnotherOneTransferredAmount() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        vm.prank(owner);
        IVotes(address(plasmaVault)).delegate(delegatee);

        // @dev Activate checkpoint
        vm.prank(delegatee);
        IVotes(address(plasmaVault)).delegate(delegatee);

        uint256 votesBefore = IVotes(address(plasmaVault)).getVotes(delegatee);

        bytes4[] memory sig = new bytes4[](1);
        sig[0] = PlasmaVault.transfer.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.PUBLIC_ROLE);

        //when
        vm.prank(owner);
        plasmaVault.transfer(delegatee, 50 * 1e6);

        //when
        vm.prank(delegatee);
        IVotes(address(plasmaVault)).delegate(spender);

        //then
        uint256 votesAfter = IVotes(address(plasmaVault)).getVotes(spender);

        uint256 delegateeBalanceOf = plasmaVault.balanceOf(delegatee);

        assertNotEq(
            votesBefore,
            votesAfter,
            "New delegatee should have voting power equal to transferred amount to a delegatee"
        );
        assertEq(
            votesAfter,
            delegateeBalanceOf,
            "New delegatee should have voting power equal to transferred amount to a delegatee - balanceOf"
        );

        assertEq(
            votesAfter,
            50 * 1e6,
            "New delegatee should have voting power equal to transferred amount to a delegatee"
        );
    }

    function testErc20VotesShouldDecreaseVotingPowerWhenBurn() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        /// @dev Activate checkpoint
        vm.prank(owner);
        IVotes(address(plasmaVault)).delegate(owner);

        uint256 votesBefore = IVotes(address(plasmaVault)).getVotes(owner);

        //when
        vm.prank(owner);
        plasmaVault.withdraw(50 * 1e6, owner, owner);

        //then
        uint256 votesAfter = IVotes(address(plasmaVault)).getVotes(owner);

        assertEq(votesBefore, amount, "Voting power should be equal to deposited amount");
        assertEq(votesAfter, 150 * 1e6, "Voting power should be equal to 0 after burn");
    }

    function testErc20VotesShouldIncreaseVotes() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(100 * 1e6, owner);

        vm.prank(delegatee);
        IVotes(address(plasmaVault)).delegate(delegatee);

        vm.prank(owner);
        IVotes(address(plasmaVault)).delegate(delegatee);

        uint256 delegateeVotesBefore = IVotes(address(plasmaVault)).getVotes(delegatee);

        bytes4[] memory sig = new bytes4[](1);
        sig[0] = PlasmaVault.transfer.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.PUBLIC_ROLE);

        vm.prank(owner);
        plasmaVault.deposit(100 * 1e6, owner);

        //when
        vm.prank(owner);
        plasmaVault.transfer(delegatee, 200 * 1e6);

        //then
        uint256 delegateeVotesAfter = IVotes(address(plasmaVault)).getVotes(delegatee);

        assertEq(delegateeVotesBefore, 100 * 1e6, "Delegatee should have voting power equal to 100 * 1e6");
        assertEq(delegateeVotesAfter, 200 * 1e6, "Delegatee should have voting power equal to 200 * 1e6");
    }

    function testErc20VotesDelegateBySig() public {
        //given
        uint256 amount = 200 * 1e6;
        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        vm.prank(owner);
        plasmaVault.deposit(100 * 1e6, owner);

        /// @dev Activate checkpoint
        vm.prank(owner);
        IVotes(address(plasmaVault)).delegate(owner);

        uint256 delegateeVotesBefore = IVotes(address(plasmaVault)).getVotes(delegatee);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(assetName)),
                keccak256(bytes("1")),
                block.chainid,
                address(plasmaVault)
            )
        );

        uint256 nonce = Nonces(address(plasmaVault)).nonces(owner);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
                delegatee,
                nonce,
                block.timestamp + 1 days
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivKey, digest);

        //when
        vm.prank(owner);
        IVotes(address(plasmaVault)).delegateBySig(delegatee, nonce, block.timestamp + 1 days, v, r, s);

        //then
        uint256 delegateeVotesAfter = IVotes(address(plasmaVault)).getVotes(delegatee);

        assertEq(IVotes(address(plasmaVault)).delegates(owner), delegatee, "Owner's delegatee should be set correctly");

        assertEq(
            IVotes(address(plasmaVault)).getVotes(delegatee),
            100 * 1e6,
            "Delegatee's voting power should be equal to the owner's balance"
        );

        assertEq(delegateeVotesBefore, 0, "Delegatee should have voting power equal to 0");
        assertEq(delegateeVotesAfter, 100 * 1e6, "Delegatee should have voting power equal to 100 * 1e6");
    }

    function testErc20VotesErc20PermitShouldPermitToDelegateeAndTransferToDelegateeNoChangesInVotesPower() public {
        //given
        amount = 200 * 1e6;
        deadline = block.timestamp + 1 days;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(owner), amount);

        vm.prank(owner);
        ERC20(USDC).approve(address(plasmaVault), amount);

        /// @dev Owner deposits and have voting power
        vm.prank(owner);
        plasmaVault.deposit(amount, owner);

        /// @dev Initialize delegatee
        vm.prank(delegatee);
        IVotes(address(plasmaVault)).delegate(delegatee);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(assetName)),
                keccak256(bytes("1")),
                block.chainid,
                address(plasmaVault)
            )
        );

        bytes32 permitStructHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                delegatee,
                amount,
                Nonces(address(plasmaVault)).nonces(owner),
                deadline
            )
        );

        bytes32 permitDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, permitStructHash));

        (uint8 permitV, bytes32 permitR, bytes32 permitS) = vm.sign(ownerPrivKey, permitDigest);

        /// @dev Owner permits transfer to delegatee
        vm.prank(owner);
        IERC20Permit(address(plasmaVault)).permit(owner, delegatee, amount, deadline, permitV, permitR, permitS);

        uint256 nonce = Nonces(address(plasmaVault)).nonces(owner);

        bytes32 delegationStructHash = keccak256(
            abi.encode(
                keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)"),
                delegatee,
                /// @dev Notice! Nonce changes after permit, so we need to update nonce
                nonce,
                block.timestamp + 1 days
            )
        );

        bytes32 delegationDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, delegationStructHash));

        (uint8 delegationV, bytes32 delegationR, bytes32 delegationS) = vm.sign(ownerPrivKey, delegationDigest);

        /// @dev owner delegates to delegatee
        vm.prank(owner);
        IVotes(address(plasmaVault)).delegateBySig(
            delegatee,
            nonce,
            block.timestamp + 1 days,
            delegationV,
            delegationR,
            delegationS
        );

        uint256 delegateeVotesBefore = IVotes(address(plasmaVault)).getVotes(delegatee);

        bytes4[] memory sig = new bytes4[](1);
        sig[0] = PlasmaVault.transferFrom.selector;

        /// @dev temporary setup tranferFrom role to a public role
        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.PUBLIC_ROLE);

        //when
        vm.prank(delegatee);
        plasmaVault.transferFrom(owner, delegatee, amount);

        //then
        uint256 delegateeVotesAfter = IVotes(address(plasmaVault)).getVotes(delegatee);

        uint256 delegateeBalanceOf = plasmaVault.balanceOf(delegatee);

        assertEq(delegateeVotesBefore, delegateeVotesAfter, "Delegatee's voting power should not change");

        assertEq(delegateeVotesAfter, delegateeBalanceOf, "Delegatee's voting power should be equal to the balance");

        assertEq(delegateeVotesAfter, amount, "Delegatee's voting power should be equal to the transferred amount");
    }

    function createAccessManager(UsersToRoles memory usersToRoles) public returns (IporFusionAccessManager) {
        address atomist = address(this);
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles, vm);
    }

    function setupRoles(PlasmaVault plasmaVault, IporFusionAccessManager accessManager) public {
        address atomist = address(this);
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }
}
