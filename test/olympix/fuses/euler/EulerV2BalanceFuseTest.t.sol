// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/euler/EulerV2BalanceFuse.sol

import {EulerV2BalanceFuse} from "contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
import {IEVC} from "@ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {PriceOracleMiddlewareMock} from "test/price_oracle/PriceOracleMiddlewareMock.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {EulerSubstrate, EulerFuseLib} from "contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IBorrowing} from "contracts/fuses/euler/ext/IBorrowing.sol";
contract EulerV2BalanceFuseTest is OlympixUnitTest("EulerV2BalanceFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_balanceOf_ReturnsZeroWhenNoSubstrates_branch77True() public {
            // Deploy EulerV2BalanceFuse with non-zero EVC so constructor does not revert
            EulerV2BalanceFuse fuse = new EulerV2BalanceFuse(1, address(0x1));
    
            // No substrates are configured for MARKET_ID=1, so balanceOf() should
            // take the `if (len == 0) { return 0; }` branch (opix-target-branch-77-True)
            uint256 balance = fuse.balanceOf();
    
            assertEq(balance, 0, "Balance should be zero when no substrates are configured");
        }

    function test_balanceOf_RevertsWhenPriceIsZero() public {
            // Deploy mock underlying token and ERC4626 Euler vault
            MockERC20 underlying = new MockERC20("Token", "TKN", 18);
            MockERC4626 eulerVault = new MockERC4626(underlying, "EulerVault", "eTKN");
    
            // Deploy a PriceOracleMiddlewareMock that always returns price = 0
            PriceOracleMiddlewareMock oracle = new PriceOracleMiddlewareMock(address(0), 8, address(0));
    
            // Deploy PlasmaVaultMock with EulerV2BalanceFuse as balance fuse so that
            // `address(this)` inside balanceOf() is the PlasmaVaultMock address
            EulerV2BalanceFuse fuseImpl = new EulerV2BalanceFuse(1, address(0x1));
            PlasmaVaultMock plasmaVault = new PlasmaVaultMock(address(0), address(fuseImpl));
    
            // Point PlasmaVaultLib.getPriceOracleMiddleware() storage to our mock oracle
            plasmaVault.setPriceOracleMiddleware(address(oracle));
    
            // Configure market substrates so that balanceOf() loop executes at least once
            EulerSubstrate memory substrate = EulerSubstrate({
                eulerVault: address(eulerVault),
                isCollateral: false,
                canBorrow: false,
                subAccounts: 0x01
            });
    
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = EulerFuseLib.substrateToBytes32(substrate);
            plasmaVault.grantMarketSubstrates(1, substrates);
    
            // Stub debtOf via a minimal IBorrowing implementation using vm.mockCall
            vm.mockCall(
                address(eulerVault),
                abi.encodeWithSelector(IBorrowing.debtOf.selector, EulerFuseLib.generateSubAccountAddress(address(plasmaVault), substrate.subAccounts)),
                abi.encode(uint256(0))
            );
    
            // Expect revert from branch: if (price == 0) { revert Errors.UnsupportedQuoteCurrencyFromOracle(); }
            vm.expectRevert(Errors.UnsupportedQuoteCurrencyFromOracle.selector);
            plasmaVault.balanceOf();
        }
}