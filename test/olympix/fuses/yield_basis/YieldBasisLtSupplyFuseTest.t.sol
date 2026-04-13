// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol

import {YieldBasisLtSupplyFuse, YieldBasisLtSupplyFuseExitData} from "contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IYieldBasisLT} from "contracts/fuses/yield_basis/ext/IYieldBasisLT.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {YieldBasisLtSupplyFuse, YieldBasisLtSupplyFuseEnterData} from "contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol";
import {YieldBasisLtSupplyFuse} from "contracts/fuses/yield_basis/YieldBasisLtSupplyFuse.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {IporMathWrapper} from "test/utils/IporMathTest.t.sol";
contract YieldBasisLtSupplyFuseTest is OlympixUnitTest("YieldBasisLtSupplyFuse") {


    function test_enter_NonZeroLtAssetAmount_UnsupportedVaultElseBranch() public {
            uint256 marketId = 1;
            YieldBasisLtSupplyFuse fuse = new YieldBasisLtSupplyFuse(marketId);
    
            address ltAddress = address(0x1234);
    
            YieldBasisLtSupplyFuseEnterData memory data_ = YieldBasisLtSupplyFuseEnterData({
                ltAddress: ltAddress,
                ltAssetAmount: 1,
                debt: 0,
                minSharesToReceive: 0
            });
    
            vm.expectRevert(
                abi.encodeWithSelector(
                    YieldBasisLtSupplyFuse.YieldBasisLtSupplyFuseUnsupportedVault.selector,
                    "enter",
                    ltAddress
                )
            );
    
            fuse.enter(data_);
        }

    function test_enter_RevertsWhenVaultNotGranted_branchTrue() public {
            // create fuse with arbitrary market id
            uint256 marketId = 1;
            YieldBasisLtSupplyFuse fuse = new YieldBasisLtSupplyFuse(marketId);
    
            // use a LT address that is not configured in PlasmaVaultConfigLib
            address ltAddress = address(0x1234);
    
            // non‑zero ltAssetAmount to skip early return and reach the branch
            YieldBasisLtSupplyFuseEnterData memory data_ = YieldBasisLtSupplyFuseEnterData({
                ltAddress: ltAddress,
                ltAssetAmount: 1e18,
                debt: 0,
                minSharesToReceive: 0
            });
    
            // expect revert with custom error YieldBasisLtSupplyFuseUnsupportedVault from this contract
            vm.expectRevert(
                abi.encodeWithSelector(
                    YieldBasisLtSupplyFuse.YieldBasisLtSupplyFuseUnsupportedVault.selector,
                    "enter",
                    ltAddress
                )
            );
    
            fuse.enter(data_);
        }

    function test_instantWithdraw_NonZeroAmount_ElseBranchAndSecondIfElse() public {
            // set up a mock underlying token
            MockERC20 underlying = new MockERC20("Underlying", "UND", 18);

            // deploy fuse with arbitrary market id
            uint256 marketId = 1;
            YieldBasisLtSupplyFuse fuse = new YieldBasisLtSupplyFuse(marketId);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // mock ERC4626.asset() staticcall on vault address (since address(this) = vault in delegatecall)
            vm.mockCall(address(vault), abi.encodeWithSelector(bytes4(0x38d52e0f)), abi.encode(address(underlying)));

            // create a mock LT token
            MockERC20 ltToken = new MockERC20("LT", "LT", 18);

            // Grant LT as substrate asset in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = address(ltToken);
            vault.grantAssetsToMarket(marketId, assets);

            // give the vault some LT balance
            ltToken.mint(address(vault), 100e18);

            // mock IYieldBasisLT interface calls on ltToken
            vm.mockCall(address(ltToken), abi.encodeWithSelector(IYieldBasisLT.ASSET_TOKEN.selector), abi.encode(address(underlying)));
            vm.mockCall(address(ltToken), abi.encodeWithSelector(IYieldBasisLT.pricePerShare.selector), abi.encode(1e18));
            vm.mockCall(address(ltToken), abi.encodeWithSelector(IYieldBasisLT.balanceOf.selector, address(vault)), abi.encode(100e18));
            vm.mockCall(address(ltToken), abi.encodeWithSelector(IYieldBasisLT.withdraw.selector), abi.encode(1e18));

            // Mock approve calls
            vm.mockCall(address(underlying), abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)"))), abi.encode(true));

            // prepare params
            uint256 amountUnderlying = 1e18;
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(amountUnderlying);
            params[1] = PlasmaVaultConfigLib.addressToBytes32(address(ltToken));

            // call instantWithdraw via vault
            vault.instantWithdraw(params);
        }

    function test_instantWithdraw_ZeroLtShares_branch165True() public {
            // Arrange
            uint256 marketId = 1;
            YieldBasisLtSupplyFuse fuse = new YieldBasisLtSupplyFuse(marketId);
    
            // Mock underlying ERC4626.asset() call on the fuse (treated as vault)
            MockERC20 underlying = new MockERC20("Underlying", "UND", 18);
            bytes memory assetRet = abi.encode(address(underlying));
            vm.mockCall(address(fuse), abi.encodeWithSelector(bytes4(0x38d52e0f)), assetRet);
    
            // Create an LT token address and configure it as a granted substrate so the fuse logic
            // can use it without reverting on unsupported vault in _exit()
            address ltAddress = address(0xABCD);
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            bytes32 ltAsBytes32 = PlasmaVaultConfigLib.addressToBytes32(ltAddress);
            marketSubstrates.substrateAllowances[ltAsBytes32] = 1;
    
            // Mock IYieldBasisLT.pricePerShare and balanceOf so that ltSharesToWithdraw == 0
            // pricePerShare arbitrary non‑zero; balanceOf == 0 makes min(ltSharesAmount, balanceOf) == 0
            vm.mockCall(
                ltAddress,
                abi.encodeWithSelector(IYieldBasisLT.pricePerShare.selector),
                abi.encode(1e18)
            );
            vm.mockCall(
                ltAddress,
                abi.encodeWithSelector(IYieldBasisLT.balanceOf.selector, address(fuse)),
                abi.encode(0)
            );
    
            // Non‑zero underlying amount so first early‑return is skipped, but
            // with balanceOf == 0 the condition `if (ltSharesToWithdraw == 0)` is true
            uint256 amountUnderlying = 1e18;
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(amountUnderlying);
            params[1] = PlasmaVaultConfigLib.addressToBytes32(ltAddress);
    
            // Act & Assert: should hit `if (ltSharesToWithdraw == 0) { return; }` branch
            // and simply return without reverting
            fuse.instantWithdraw(params);
        }

    function test_exit_ZeroLtShares_OpixBranch183True() public {
            uint256 marketId = 1;
            YieldBasisLtSupplyFuse fuse = new YieldBasisLtSupplyFuse(marketId);
    
            YieldBasisLtSupplyFuseExitData memory data_ = YieldBasisLtSupplyFuseExitData({
                ltAddress: address(0x1234),
                ltSharesAmount: 0,
                minLtAssetAmountToReceive: 0
            });
    
            (address ltAddress, uint256 ltSharesAmount, uint256 ltAssetAmountReceived) = fuse.exit(data_);
    
            assertEq(ltAddress, address(0));
            assertEq(ltSharesAmount, 0);
            assertEq(ltAssetAmountReceived, 0);
        }
}