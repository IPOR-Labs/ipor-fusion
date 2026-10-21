// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// solhint-disable no-console

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {HyperCoreLib} from "../../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";

interface ICoreDepositWalletMainnetFork {
    function token() external view returns (address);
    function tokenSystemAddress() external view returns (address);
    function newCoreAccountFee() external view returns (uint256);
    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external;
}

contract HyperCoreTokenInfoReader {
    function tokenInfo(uint64 tokenIndex) external view returns (HyperCoreLib.TokenInfo memory) {
        return HyperCoreLib.tokenInfo(tokenIndex);
    }
}

/// @notice Opt-in, fork-only identity and wallet-call probe for HyperEVM mainnet Core USDC.
/// @dev Set HYPEREVM_MAINNET_FORK_RPC to run. Any token balance created with `deal` and any
///      depositFor call execute only in Foundry's local fork state; no signer or broadcast is used.
contract CoreDepositWalletMainnetForkTest is Test {
    address private constant CORE_DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    address private constant NATIVE_USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address private constant TOKEN_SYSTEM_ADDRESS = 0x2000000000000000000000000000000000000000;
    uint32 private constant SPOT_DEX = type(uint32).max;
    uint256 private constant LOCAL_TEST_AMOUNT = 1e6;

    event CoreTokenInfoRead(bool succeeded, bytes revertData);
    event ForkDepositSimulation(bool succeeded, bytes revertData, uint256 observedFee);

    function testMainnetUsdcWalletIdentityAndForkOnlyDepositAttempt() external {
        string memory rpc = vm.envOr("HYPEREVM_MAINNET_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 999, "RPC must point to HyperEVM mainnet");

        HyperCoreTokenInfoReader reader = new HyperCoreTokenInfoReader();
        try reader.tokenInfo(0) returns (HyperCoreLib.TokenInfo memory info) {
            _assertCoreUsdcInfo(info);
            console2.log("fork Core tokenInfo(0): PASS");
            emit CoreTokenInfoRead(true, bytes(""));
        } catch (bytes memory revertData) {
            // Anvil-style EVM forks generally do not emulate HyperCore's 0x80C precompile.
            console2.log("fork Core tokenInfo(0): unavailable (HyperCore precompile not emulated)");
            console2.logBytes(revertData);
            emit CoreTokenInfoRead(false, revertData);
        }
        try this.readCoreUsdcInfoFromRpc() returns (HyperCoreLib.TokenInfo memory info) {
            _assertCoreUsdcInfo(info);
            console2.log("read-only RPC eth_call Core tokenInfo(0): PASS");
        } catch (bytes memory revertData) {
            console2.log("read-only RPC eth_call Core tokenInfo(0): FAIL");
            console2.logBytes(revertData);
            revert("live RPC tokenInfo(0) read failed");
        }
        assertEq(ICoreDepositWalletMainnetFork(CORE_DEPOSIT_WALLET).token(), NATIVE_USDC, "wallet USDC");
        assertEq(
            ICoreDepositWalletMainnetFork(CORE_DEPOSIT_WALLET).tokenSystemAddress(),
            TOKEN_SYSTEM_ADDRESS,
            "wallet Core system address"
        );
        assertEq(IERC20Metadata(NATIVE_USDC).decimals(), 6, "native Circle USDC decimals");
        console2.log("direct wallet identity and native USDC metadata: PASS");

        uint256 fee = ICoreDepositWalletMainnetFork(CORE_DEPOSIT_WALLET).newCoreAccountFee();
        // This is an explicitly simulated deposit: deal changes only this local fork's token state.
        deal(NATIVE_USDC, address(this), LOCAL_TEST_AMOUNT, true);
        IERC20(NATIVE_USDC).approve(CORE_DEPOSIT_WALLET, LOCAL_TEST_AMOUNT);
        try ICoreDepositWalletMainnetFork(CORE_DEPOSIT_WALLET).depositFor(
            address(this), LOCAL_TEST_AMOUNT, SPOT_DEX
        ) {
            assertEq(IERC20(NATIVE_USDC).balanceOf(address(this)), 0, "wallet pulled simulated USDC");
            assertEq(IERC20(NATIVE_USDC).allowance(address(this), CORE_DEPOSIT_WALLET), 0, "allowance consumed");
            console2.log("fork-only depositFor: PASS (wallet pulled simulated 1e6 USDC; no Core credit assertion)");
            emit ForkDepositSimulation(true, bytes(""), fee);
        } catch (bytes memory revertData) {
            IERC20(NATIVE_USDC).approve(CORE_DEPOSIT_WALLET, 0);
            assertEq(IERC20(NATIVE_USDC).allowance(address(this), CORE_DEPOSIT_WALLET), 0, "allowance cleared");
            console2.log("fork-only depositFor: REVERT (simulated call; allowance cleared)");
            console2.logBytes(revertData);
            emit ForkDepositSimulation(false, revertData, fee);
        }
    }

    /// @dev Reads the HyperCore token-info precompile on the upstream node via eth_call. Foundry's
    ///      local fork cannot execute precompiles, so this is a read-only live-node metadata check.
    function readCoreUsdcInfoFromRpc() external returns (HyperCoreLib.TokenInfo memory info) {
        string memory payload = string.concat(
            "[{\"to\":\"",
            vm.toString(address(0x80c)),
            "\",\"data\":\"",
            vm.toString(abi.encode(uint64(0))),
            "\"},\"latest\"]"
        );
        bytes memory result = vm.rpc("eth_call", payload);
        info = abi.decode(result, (HyperCoreLib.TokenInfo));
    }

    function _assertCoreUsdcInfo(HyperCoreLib.TokenInfo memory info) private pure {
        assert(keccak256(bytes(info.name)) == keccak256(bytes("USDC")));
        assert(info.evmContract == CORE_DEPOSIT_WALLET);
        assert(info.weiDecimals == 8);
        assert(info.evmExtraWeiDecimals == -2);
    }
}
