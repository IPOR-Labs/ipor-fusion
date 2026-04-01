// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {MidasClaimFromExecutorFuse, MidasClaimFromExecutorFuseEnterData} from "contracts/fuses/midas/MidasClaimFromExecutorFuse.sol";
import {MidasExecutor} from "contracts/fuses/midas/MidasExecutor.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";

import {MidasClaimFromExecutorFuseHarness} from "./mocks/claim_executor/MidasClaimFromExecutorFuseHarness.sol";
import {MockERC20ForClaim} from "./mocks/claim_executor/MockERC20ForClaim.sol";

/// @title MidasClaimFromExecutorFuseTest
/// @notice Unit tests for MidasClaimFromExecutorFuse — 100% branch coverage target
/// @dev Uses a delegatecall harness to simulate the PlasmaVault storage context.
contract MidasClaimFromExecutorFuseTest is Test {
    // ============ Constants ============

    uint256 internal constant MARKET_ID = 1;

    // ============ State Variables ============

    MidasClaimFromExecutorFuse internal fuse;
    MidasClaimFromExecutorFuseHarness internal harness;
    MockERC20ForClaim internal token;
    MidasExecutor internal executor;

    // ============ Setup ============

    function setUp() public {
        fuse = new MidasClaimFromExecutorFuse(MARKET_ID);
        harness = new MidasClaimFromExecutorFuseHarness(address(fuse));
        token = new MockERC20ForClaim("Mock Token", "MTK", 18);

        // Deploy a real MidasExecutor with the harness as PLASMA_VAULT (simulates delegatecall context)
        executor = new MidasExecutor(address(harness));
        // Store executor in harness storage so enter() can find it
        harness.setExecutor(address(executor));

        vm.label(address(fuse), "MidasClaimFromExecutorFuse");
        vm.label(address(harness), "Harness(PlasmaVault)");
        vm.label(address(token), "MockERC20ForClaim");
        vm.label(address(executor), "MidasExecutor");
    }

    // ============ Helper Functions ============

    /// @dev Grant the token as M_TOKEN substrate in the harness (PlasmaVault context)
    function _grantMTokenSubstrate(address token_) internal {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: token_})
        );
        harness.grantMarketSubstrates(MARKET_ID, substrates);
    }

    /// @dev Grant the token as ASSET substrate in the harness (PlasmaVault context)
    function _grantAssetSubstrate(address token_) internal {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: token_})
        );
        harness.grantMarketSubstrates(MARKET_ID, substrates);
    }

    /// @dev Grant both M_TOKEN and ASSET substrates for the token
    function _grantBothSubstrates(address token_) internal {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: token_})
        );
        substrates[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: token_})
        );
        harness.grantMarketSubstrates(MARKET_ID, substrates);
    }

    /// @dev Mint tokens to the executor and grant M_TOKEN substrate — common setup for claim tests
    function _setupClaimWithMToken(uint256 amount_) internal {
        _grantMTokenSubstrate(address(token));
        token.mint(address(executor), amount_);
    }

    // ============ Constructor Tests ============

    /// @dev B1: marketId == 0 must revert with Errors.WrongValue()
    function testConstructor_RevertsWhenMarketIdIsZero() public {
        // Given / When / Then
        vm.expectRevert(abi.encodeWithSelector(Errors.WrongValue.selector));
        new MidasClaimFromExecutorFuse(0);
    }

    /// @dev B2: VERSION must be set to address(this) (the deployed fuse address)
    function testConstructor_SetsVersionToContractAddress() public {
        // Given
        MidasClaimFromExecutorFuse newFuse = new MidasClaimFromExecutorFuse(1);

        // Then
        assertEq(newFuse.VERSION(), address(newFuse), "VERSION must equal address(this) after construction");
    }

    /// @dev B2: MARKET_ID must store the provided marketId
    function testConstructor_SetsMarketId() public {
        // Given
        MidasClaimFromExecutorFuse newFuse = new MidasClaimFromExecutorFuse(42);

        // Then
        assertEq(newFuse.MARKET_ID(), 42, "MARKET_ID must equal the constructor argument");
    }

    /// @dev B2: Minimum valid marketId = 1 (boundary between valid and invalid)
    function testConstructor_AcceptsMarketIdOne() public {
        // Given
        MidasClaimFromExecutorFuse newFuse = new MidasClaimFromExecutorFuse(1);

        // Then
        assertEq(newFuse.MARKET_ID(), 1, "MARKET_ID must be 1 (minimum valid value)");
    }

    /// @dev B2: Maximum valid marketId = type(uint256).max
    function testConstructor_AcceptsMaxUint256MarketId() public {
        // Given
        MidasClaimFromExecutorFuse newFuse = new MidasClaimFromExecutorFuse(type(uint256).max);

        // Then
        assertEq(newFuse.MARKET_ID(), type(uint256).max, "MARKET_ID must equal type(uint256).max");
    }

    // ============ enter() — Substrate Grant Validation ============

    /// @dev B5: Token granted neither as M_TOKEN nor ASSET → MidasClaimFromExecutorFuseTokenNotGranted
    function testEnter_RevertsWhenTokenNotGrantedAsEitherMTokenOrAsset() public {
        // Given: no substrates granted for the token
        MidasClaimFromExecutorFuseEnterData memory data = MidasClaimFromExecutorFuseEnterData({token: address(token)});

        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseTokenNotGranted.selector, address(token)
            )
        );
        harness.enter(data);
    }

    /// @dev B3, B7b: Token granted only as M_TOKEN → first branch of OR is true, claim succeeds
    function testEnter_SucceedsWhenTokenGrantedAsMToken() public {
        // Given: M_TOKEN substrate granted, executor funded
        _setupClaimWithMToken(1000e6);

        // When
        vm.expectEmit(true, true, true, true);
        emit MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseClaimed(fuse.VERSION(), address(token), 1000e6);
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Then: tokens transferred from executor to harness (PlasmaVault)
        assertEq(token.balanceOf(address(harness)), 1000e6, "Harness must receive the claimed tokens");
        assertEq(token.balanceOf(address(executor)), 0, "Executor must have zero balance after claim");
    }

    /// @dev B4, B7b: Token granted only as ASSET → second branch of OR is true, claim succeeds
    function testEnter_SucceedsWhenTokenGrantedAsAsset() public {
        // Given: ASSET substrate granted (not M_TOKEN), executor funded
        _grantAssetSubstrate(address(token));
        token.mint(address(executor), 500e18);

        // When
        vm.expectEmit(true, true, true, true);
        emit MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseClaimed(fuse.VERSION(), address(token), 500e18);
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Then: tokens transferred
        assertEq(token.balanceOf(address(harness)), 500e18, "Harness must receive the claimed tokens");
        assertEq(token.balanceOf(address(executor)), 0, "Executor must have zero balance after claim");
    }

    /// @dev B3 short-circuit: Both M_TOKEN and ASSET granted — M_TOKEN check short-circuits, no issues
    function testEnter_SucceedsWhenTokenGrantedAsBothMTokenAndAsset() public {
        // Given: both substrates granted, executor funded
        _grantBothSubstrates(address(token));
        token.mint(address(executor), 250e18);

        // When
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Then: claim succeeds and tokens are transferred
        assertEq(token.balanceOf(address(harness)), 250e18, "Harness must receive all claimed tokens");
        assertEq(token.balanceOf(address(executor)), 0, "Executor must have zero balance");
    }

    /// @dev B5: Token granted as DEPOSIT_VAULT (wrong type) → still reverts with TokenNotGranted
    function testEnter_RevertsWhenTokenGrantedAsOtherSubstrateType() public {
        // Given: DEPOSIT_VAULT substrate granted for the token address — wrong type
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: address(token)})
        );
        harness.grantMarketSubstrates(MARKET_ID, substrates);

        // When / Then: DEPOSIT_VAULT type is not M_TOKEN or ASSET → revert
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseTokenNotGranted.selector, address(token)
            )
        );
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));
    }

    // ============ enter() — Executor Validation ============

    /// @dev B6: Token is granted but executor is address(0) → MidasClaimFromExecutorFuseExecutorNotDeployed
    function testEnter_RevertsWhenExecutorNotDeployed() public {
        // Given: M_TOKEN substrate granted, but NO executor stored
        _grantMTokenSubstrate(address(token));
        harness.setExecutor(address(0)); // clear executor

        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseExecutorNotDeployed.selector)
        );
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));
    }

    // ============ enter() — Claiming Logic ============

    /// @dev B7b: Executor has non-zero balance → full amount transferred to harness
    function testEnter_ClaimsFullBalanceFromExecutor() public {
        // Given: 1000e6 tokens minted to executor
        _setupClaimWithMToken(1000e6);

        // When
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Then
        assertEq(token.balanceOf(address(harness)), 1000e6, "Harness must hold exactly 1000e6 tokens");
        assertEq(token.balanceOf(address(executor)), 0, "Executor balance must be zero after full claim");
    }

    /// @dev B7a: Executor has zero balance → amount = 0, no transfer, event still emitted with amount 0
    function testEnter_ClaimsZeroBalanceFromExecutor() public {
        // Given: M_TOKEN granted, but executor has NO tokens
        _grantMTokenSubstrate(address(token));
        // (no mint)

        // When
        vm.expectEmit(true, true, true, true);
        emit MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseClaimed(fuse.VERSION(), address(token), 0);
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Then
        assertEq(token.balanceOf(address(harness)), 0, "Harness balance must remain zero");
    }

    /// @dev B7b: All event parameters must match exactly
    function testEnter_EmitsCorrectEvent() public {
        // Given: fuse with marketId 7, 500e18 tokens in executor
        MidasClaimFromExecutorFuse fuse7 = new MidasClaimFromExecutorFuse(7);
        MidasClaimFromExecutorFuseHarness harness7 = new MidasClaimFromExecutorFuseHarness(address(fuse7));
        vm.label(address(fuse7), "Fuse_MarketId7");
        vm.label(address(harness7), "Harness_MarketId7");

        MidasExecutor executor7 = new MidasExecutor(address(harness7));
        harness7.setExecutor(address(executor7));

        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: address(token)})
        );
        harness7.grantMarketSubstrates(7, substrates);
        token.mint(address(executor7), 500e18);

        // When / Then: verify all event fields
        vm.expectEmit(true, true, true, true);
        emit MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseClaimed(fuse7.VERSION(), address(token), 500e18);
        harness7.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Additional assertion: version must be fuse7 address, not harness address
        assertNotEq(fuse7.VERSION(), address(harness7), "VERSION must be fuse address, not harness");
        assertEq(fuse7.VERSION(), address(fuse7), "VERSION must equal the fuse contract address");
    }

    // ============ deployExecutor() Tests ============

    /// @dev B8: No executor in storage → deploys a new MidasExecutor and stores it
    function testDeployExecutor_DeploysNewExecutorWhenNoneExists() public {
        // Given: fresh harness with no executor
        MidasClaimFromExecutorFuseHarness freshHarness = new MidasClaimFromExecutorFuseHarness(address(fuse));
        vm.label(address(freshHarness), "FreshHarness");

        assertEq(freshHarness.getExecutor(), address(0), "Executor must be address(0) before deployment");

        // When
        vm.expectEmit(true, true, false, false);
        emit MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseExecutorCreated(fuse.VERSION(), address(0)); // address placeholder
        freshHarness.deployExecutor();

        // Then: executor was deployed and stored
        address deployedExecutor = freshHarness.getExecutor();
        assertNotEq(deployedExecutor, address(0), "Executor must be deployed and stored");

        // The executor's PLASMA_VAULT must be the harness (the delegatecall context = address(this) in the fuse)
        assertEq(
            MidasExecutor(deployedExecutor).PLASMA_VAULT(),
            address(freshHarness),
            "Executor PLASMA_VAULT must be the harness (delegatecall context)"
        );
    }

    /// @dev B9: Executor already deployed → returns existing address, no new deployment
    function testDeployExecutor_ReturnsExistingExecutorWhenAlreadyDeployed() public {
        // Given: fresh harness, deploy executor once
        MidasClaimFromExecutorFuseHarness freshHarness = new MidasClaimFromExecutorFuseHarness(address(fuse));
        freshHarness.deployExecutor();
        address firstExecutor = freshHarness.getExecutor();
        assertNotEq(firstExecutor, address(0), "First deployment must store executor");

        // When: deploy a second time
        freshHarness.deployExecutor();

        // Then: same executor address returned
        address secondExecutor = freshHarness.getExecutor();
        assertEq(secondExecutor, firstExecutor, "Second call must return the same executor (idempotent)");
    }

    /// @dev B8: Event must contain fuse.VERSION() (not harness address, not address(0))
    function testDeployExecutor_EmitsEventWithCorrectVersion() public {
        // Given: fresh harness
        MidasClaimFromExecutorFuseHarness freshHarness = new MidasClaimFromExecutorFuseHarness(address(fuse));
        vm.label(address(freshHarness), "FreshHarness_EmitTest");

        // When: record the emitted event
        vm.recordLogs();
        freshHarness.deployExecutor();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Then: find the ExecutorCreated event and check version field
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].topics[0]
                    == keccak256("MidasClaimFromExecutorFuseExecutorCreated(address,address)")
            ) {
                (address version, ) = abi.decode(logs[i].data, (address, address));
                assertEq(version, fuse.VERSION(), "Event version must equal fuse.VERSION()");
                assertNotEq(version, address(freshHarness), "Event version must NOT be harness address");
                found = true;
                break;
            }
        }
        assertTrue(found, "MidasClaimFromExecutorFuseExecutorCreated event must be emitted");
    }

    // ============ Integration Tests ============

    /// @dev B3/B7b/B8: Full flow — deployExecutor, fund it, then enter (claim)
    function testEnterAfterDeployExecutor_ClaimsSuccessfully() public {
        // Given: fresh harness, deploy executor via fuse, grant substrate, fund executor
        MidasClaimFromExecutorFuseHarness freshHarness = new MidasClaimFromExecutorFuseHarness(address(fuse));
        vm.label(address(freshHarness), "IntegrationHarness");

        // Grant M_TOKEN substrate
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: address(token)})
        );
        freshHarness.grantMarketSubstrates(MARKET_ID, substrates);

        // Deploy executor via fuse (B8)
        freshHarness.deployExecutor();
        address deployedExec = freshHarness.getExecutor();

        // Fund the executor
        token.mint(deployedExec, 777e18);

        // When
        vm.recordLogs();
        freshHarness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Then: tokens transferred
        assertEq(token.balanceOf(address(freshHarness)), 777e18, "Harness must hold all claimed tokens");
        assertEq(token.balanceOf(deployedExec), 0, "Executor must be drained");

        // MidasClaimFromExecutorFuseClaimed event must be emitted
        bool claimEmitted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("MidasClaimFromExecutorFuseClaimed(address,address,uint256)")) {
                claimEmitted = true;
                break;
            }
        }
        assertTrue(claimEmitted, "MidasClaimFromExecutorFuseClaimed event must be emitted");
    }

    /// @dev B3+B4+B7b: Claim two tokens (one as M_TOKEN, one as ASSET) independently
    function testEnterMultipleTokens_ClaimsEachIndependently() public {
        // Given: two tokens with different substrate types
        MockERC20ForClaim tokenA = new MockERC20ForClaim("Token A", "TKA", 6);
        MockERC20ForClaim tokenB = new MockERC20ForClaim("Token B", "TKB", 18);
        vm.label(address(tokenA), "TokenA(M_TOKEN)");
        vm.label(address(tokenB), "TokenB(ASSET)");

        // Grant tokenA as M_TOKEN and tokenB as ASSET in one call
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: address(tokenA)})
        );
        substrates[1] = MidasSubstrateLib.substrateToBytes32(
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: address(tokenB)})
        );
        harness.grantMarketSubstrates(MARKET_ID, substrates);

        // Mint to executor
        tokenA.mint(address(executor), 100e6);
        tokenB.mint(address(executor), 200e18);

        // When: claim tokenA
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(tokenA)}));

        // Then: tokenA transferred, tokenB untouched
        assertEq(tokenA.balanceOf(address(harness)), 100e6, "Harness must hold 100e6 of tokenA");
        assertEq(tokenA.balanceOf(address(executor)), 0, "Executor tokenA balance must be zero");
        assertEq(tokenB.balanceOf(address(executor)), 200e18, "Executor tokenB balance must be unchanged");

        // When: claim tokenB
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(tokenB)}));

        // Then: tokenB also transferred
        assertEq(tokenB.balanceOf(address(harness)), 200e18, "Harness must hold 200e18 of tokenB");
        assertEq(tokenB.balanceOf(address(executor)), 0, "Executor tokenB balance must be zero");
    }

    // ============ Boundary / Edge Case Tests ============

    /// @dev B5: Error must include the exact token address
    function testEnter_RevertsWithCorrectTokenAddressInError() public {
        // Given: no substrates granted
        address weirdToken = address(0xDEAD);

        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseTokenNotGranted.selector, weirdToken
            )
        );
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: weirdToken}));
    }

    /// @dev B7b overflow boundary: type(uint128).max token amount
    function testEnter_WithMaxUint128TokenAmount() public {
        // Given
        uint256 bigAmount = type(uint128).max;
        _setupClaimWithMToken(bigAmount);

        // When
        vm.expectEmit(true, true, true, true);
        emit MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseClaimed(fuse.VERSION(), address(token), bigAmount);
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Then
        assertEq(token.balanceOf(address(harness)), bigAmount, "Harness must hold type(uint128).max tokens");
        assertEq(token.balanceOf(address(executor)), 0, "Executor must be fully drained");
    }

    /// @dev B7b boundary: minimum non-zero amount = 1
    function testEnter_WithAmountOne() public {
        // Given: exactly 1 token in executor
        _setupClaimWithMToken(1);

        // When
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Then: 1 token transferred
        assertEq(token.balanceOf(address(harness)), 1, "Harness must hold exactly 1 token");
        assertEq(token.balanceOf(address(executor)), 0, "Executor must have zero balance");
    }

    // ============ Fuzz Tests ============

    /// @dev B1+B2 fuzz: any non-zero marketId is accepted and stored correctly
    function testFuzz_Constructor_AcceptsAnyNonZeroMarketId(uint256 marketId_) public {
        vm.assume(marketId_ != 0);

        // When
        MidasClaimFromExecutorFuse newFuse = new MidasClaimFromExecutorFuse(marketId_);

        // Then
        assertEq(newFuse.MARKET_ID(), marketId_, "MARKET_ID must equal the fuzz input");
        assertEq(newFuse.VERSION(), address(newFuse), "VERSION must equal address(newFuse)");
    }

    /// @dev B7a+B7b fuzz: claimed amount always equals the executor's balance before claim
    function testFuzz_Enter_ClaimsCorrectAmount(uint256 amount_) public {
        vm.assume(amount_ <= type(uint128).max); // realistic ERC20 supply

        // Given
        _grantMTokenSubstrate(address(token));
        token.mint(address(executor), amount_);

        // When
        harness.enter(MidasClaimFromExecutorFuseEnterData({token: address(token)}));

        // Then: invariant — harness receives exactly amount_, executor drains to zero
        assertEq(token.balanceOf(address(harness)), amount_, "Harness balance must equal minted amount");
        assertEq(token.balanceOf(address(executor)), 0, "Executor must be fully drained (or was already zero)");
    }

    /// @dev B5 fuzz: any ungranted token address causes MidasClaimFromExecutorFuseTokenNotGranted
    function testFuzz_Enter_RevertsForUngrantedToken(address token_) public {
        vm.assume(token_ != address(0));

        // Given: no substrates granted at all (fresh harness)
        MidasClaimFromExecutorFuseHarness freshHarness = new MidasClaimFromExecutorFuseHarness(address(fuse));

        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasClaimFromExecutorFuse.MidasClaimFromExecutorFuseTokenNotGranted.selector, token_
            )
        );
        freshHarness.enter(MidasClaimFromExecutorFuseEnterData({token: token_}));
    }
}
