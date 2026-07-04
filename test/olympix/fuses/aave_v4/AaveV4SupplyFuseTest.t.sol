// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {AaveV4SupplyFuse, AaveV4SupplyFuseEnterData} from "contracts/fuses/aave_v4/AaveV4SupplyFuse.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {MockAaveV4Spoke} from "test/fuses/aave_v4/MockAaveV4Spoke.sol";
import {ERC20Mock} from "test/fuses/aave_v4/ERC20Mock.sol";
import {AaveV4SubstrateLib} from "contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";

/// @dev Target contract: contracts/fuses/aave_v4/AaveV4SupplyFuse.sol
/// @dev Uses local PlasmaVaultMock + MockAaveV4Spoke for substrate context — no fork required.

contract AaveV4SupplyFuseTest is OlympixUnitTest("AaveV4SupplyFuse") {
    uint256 internal constant MARKET_ID = 43;
    uint256 internal constant RESERVE_ID = 1;

    AaveV4SupplyFuse internal fuse;
    PlasmaVaultMock internal vault;
    MockAaveV4Spoke internal spoke;
    ERC20Mock internal token;

    function setUp() public override {
        fuse = new AaveV4SupplyFuse(MARKET_ID);
        vault = new PlasmaVaultMock(address(fuse), address(0));
        spoke = new MockAaveV4Spoke();
        token = new ERC20Mock("Test Token", "TST", 18);
        spoke.addReserve(RESERVE_ID, address(token));
        token.mint(address(spoke), 1_000_000e18);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeAsset(address(token));
        substrates[1] = AaveV4SubstrateLib.encodeSpoke(address(spoke));
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function test_example_constructorSetsImmutables() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.VERSION(), address(fuse));
    }

    function test_example_constructorRevertsOnZeroMarketId() public {
        vm.expectRevert(AaveV4SupplyFuse.AaveV4SupplyFuseInvalidMarketId.selector);
        new AaveV4SupplyFuse(0);
    }

    function test_example_enterSupplies() public {
        uint256 amount = 1_000e18;
        token.mint(address(vault), amount);
        vault.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: amount,
                minShares: 0
            })
        );
        assertEq(spoke.getUserSuppliedShares(RESERVE_ID, address(vault)), amount);
    }

    function test_example_enterReturnsEarlyOnZeroAmount() public {
        vault.enterAaveV4Supply(
            AaveV4SupplyFuseEnterData({
                spoke: address(spoke),
                asset: address(token),
                reserveId: RESERVE_ID,
                amount: 0,
                minShares: 0
            })
        );
        assertEq(spoke.getUserSuppliedShares(RESERVE_ID, address(vault)), 0);
    }

    function test_instantWithdraw_RevertsOnInsufficientAmount_BranchTrue() public {
            uint256 supplyAmount = 1_000e18;
    
            // Arrange: vault already has correct substrates configured in setUp
            // Mint tokens to vault and supply into Aave via fuse so there is balance to withdraw
            token.mint(address(vault), supplyAmount);
            vault.enterAaveV4Supply(
                AaveV4SupplyFuseEnterData({
                    spoke: address(spoke),
                    asset: address(token),
                    reserveId: RESERVE_ID,
                    amount: supplyAmount,
                    minShares: 0
                })
            );
    
            // Configure spoke so that withdrawnAmount == supplyAmount
            spoke.setShareRate(1, 1);
            spoke.setWithdrawRate(1, 1);
    
            // Build params for instantWithdraw: amount = supplyAmount, minAmount = supplyAmount + 1
            // so withdrawnAmount < minAmount and the targeted branch is taken
            bytes32[] memory params = new bytes32[](5);
            params[0] = bytes32(supplyAmount); // amount
            params[1] = bytes32(uint256(uint160(address(token)))); // asset
            params[2] = bytes32(uint256(uint160(address(spoke)))); // spoke
            params[3] = bytes32(RESERVE_ID); // reserveId
            params[4] = bytes32(supplyAmount + 1); // minAmount (one more than we can withdraw)
    
            vm.expectRevert(
                abi.encodeWithSelector(
                    AaveV4SupplyFuse.AaveV4SupplyFuseInsufficientAmount.selector,
                    supplyAmount,
                    supplyAmount + 1
                )
            );
            vault.instantWithdraw(params);
        }
    
}