// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Erc4626BalanceFuse} from "./../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MockERC4626} from "../../test_helpers/MockErc4626.sol";

contract Erc4626BalanceFuseOracleStub {
    function getAssetPrice(address) external pure returns (uint256, uint256) {
        return (1e8, 8);
    }
}

/// @notice M20 (IL-9610): a substrate equal to the vault's own underlying `asset()` must not be counted by the
///         balance fuse, because it is already counted as idle underlying
contract Erc4626BalanceFuseUnderlyingSkipTest is Test {
    uint256 private constant MARKET_ID = 1;

    MockERC20 private token;
    MockERC4626 private underlyingShare; // parent's underlying asset, itself an ERC-4626 share
    MockERC4626 private otherVault; // ordinary ERC-4626 substrate
    PlasmaVaultMock private parent;

    function setUp() public {
        token = new MockERC20("Token", "TKN", 18);
        underlyingShare = new MockERC4626(token, "Share U", "SU");
        otherVault = new MockERC4626(token, "Vault V", "V");

        Erc4626BalanceFuse balanceFuse = new Erc4626BalanceFuse(MARKET_ID);
        parent = new PlasmaVaultMock(address(0x1), address(balanceFuse));
        parent.setPriceOracleMiddleware(address(new Erc4626BalanceFuseOracleStub()));
        // PlasmaVaultMock has no asset(); the parent's underlying is the ERC-4626 share
        vm.mockCall(address(parent), abi.encodeWithSignature("asset()"), abi.encode(address(underlyingShare)));

        address[] memory substrates = new address[](2);
        substrates[0] = address(underlyingShare);
        substrates[1] = address(otherVault);
        parent.grantAssetsToMarket(MARKET_ID, substrates);

        token.mint(address(this), 1_000e18);
        token.approve(address(underlyingShare), type(uint256).max);
        token.approve(address(otherVault), type(uint256).max);
    }

    function testShouldSkipSubstrateEqualToParentAsset() external {
        // given: the parent holds 100 of its own underlying (shares of U) and 40 worth of V shares
        underlyingShare.deposit(100e18, address(parent));
        otherVault.deposit(40e18, address(parent));

        // when
        uint256 balance = parent.balanceOf();

        // then: only V is counted (40 tokens at 1 USD, WAD)
        assertEq(balance, 40e18, "underlying share substrate must be skipped, other vault counted");
    }

    function testShouldReturnZeroWhenOnlySubstrateIsParentAsset() external {
        // given
        underlyingShare.deposit(100e18, address(parent));

        // when
        uint256 balance = parent.balanceOf();

        // then
        assertEq(balance, 0, "only substrate is the parent's underlying, balance must be zero");
    }
}
