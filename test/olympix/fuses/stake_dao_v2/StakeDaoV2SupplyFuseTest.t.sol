// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/stake_dao_v2/StakeDaoV2SupplyFuse.sol

import {StakeDaoV2SupplyFuse} from "contracts/fuses/stake_dao_v2/StakeDaoV2SupplyFuse.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626} from "test/test_helpers/MockErc4626.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLibMock} from "test/transient_storage/TransientStorageLibMock.sol";
import {TransientStorageSetterFuse} from "test/test_helpers/TransientStorageSetterFuse.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {StakeDaoV2SupplyFuseEnterData} from "contracts/fuses/stake_dao_v2/StakeDaoV2SupplyFuse.sol";
contract StakeDaoV2SupplyFuseTest is OlympixUnitTest("StakeDaoV2SupplyFuse") {


    function test_enter_LpTokenUnderlyingAmountZero_opixBranch101True() public {
            // Deploy fuse with valid non-zero marketId to avoid constructor revert
            StakeDaoV2SupplyFuse fuse = new StakeDaoV2SupplyFuse(1);
    
            // Prepare enter data with lpTokenUnderlyingAmount = 0 to hit opix-target-branch-101-True
            StakeDaoV2SupplyFuseEnterData memory data_ = StakeDaoV2SupplyFuseEnterData({
                rewardVault: address(0),
                lpTokenUnderlyingAmount: 0, // triggers the early return branch
                minLpTokenUnderlyingAmount: 0
            });
    
            // Call enter; it should take the early return path and not revert
            (address rewardVault, uint256 rewardVaultShares, uint256 lpTokenAmount, uint256 finalLpTokenUnderlyingAmount) = fuse.enter(data_);
    
            // Validate returned values correspond to the early-return branch
            assertEq(rewardVault, address(0), "rewardVault should be zero address");
            assertEq(rewardVaultShares, 0, "rewardVaultShares should be zero");
            assertEq(lpTokenAmount, 0, "lpTokenAmount should be zero");
            assertEq(finalLpTokenUnderlyingAmount, 0, "finalLpTokenUnderlyingAmount should be zero");
        }

    function test_enter_rewardVaultNotGranted_Reverts_opixBranch107True() public {
            // deploy fuse implementation with non-zero marketId so constructor does not revert
            StakeDaoV2SupplyFuse fuseImpl = new StakeDaoV2SupplyFuse(1);
    
            // wrap fuse in PlasmaVaultMock so that state reads/writes use the vault storage layout
            PlasmaVaultMock plasmaVault = new PlasmaVaultMock(address(fuseImpl), address(0));
    
            // create arbitrary ERC4626 reward vault (not granted as substrate in PlasmaVaultConfigLib)
            MockERC20 underlying = new MockERC20("UNDER", "UND", 18);
            MockERC4626 lpToken = new MockERC4626(underlying, "LP", "LP");
            MockERC4626 rewardVault = new MockERC4626(lpToken, "RV", "RV");
    
            // mint underlying to plasmaVault so lpTokenUnderlyingAmount branch does not short-circuit
            underlying.mint(address(plasmaVault), 1_000 ether);
    
            // build enter data: non-zero lpTokenUnderlyingAmount, but rewardVault not granted
            StakeDaoV2SupplyFuseEnterData memory data_ = StakeDaoV2SupplyFuseEnterData({
                rewardVault: address(rewardVault),
                lpTokenUnderlyingAmount: 1_000 ether,
                minLpTokenUnderlyingAmount: 0
            });
    
            // encode call to enter((address,uint256,uint256)) and execute via delegatecall from PlasmaVaultMock
            bytes memory callData = abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                data_
            );
    
            // expect revert from the `if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(...))` branch
            vm.expectRevert(abi.encodeWithSelector(
                StakeDaoV2SupplyFuse.StakeDaoV2SupplyFuseUnsupportedRewardVault.selector,
                "enter",
                address(rewardVault)
            ));
            plasmaVault.execute(address(fuseImpl), callData);
        }

    function test_instantWithdraw_ZeroAmount() public {
            // Deploy fuse with non-zero marketId
            StakeDaoV2SupplyFuse fuse = new StakeDaoV2SupplyFuse(1);
    
            // Prepare params with amount = 0 to hit the early return branch in instantWithdraw
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(uint256(0)); // amount = 0 -> opix-target-branch-241-True
            params[1] = bytes32(uint256(uint160(address(0)))); // rewardVault address (ignored in this branch)
    
            // Call instantWithdraw as the test contract (simulating PlasmaVault context)
            fuse.instantWithdraw(params);
    
            // If the function returns without reverting, the targeted True branch has been covered
        }

    function test_instantWithdraw_NonZeroAmount_And_NonZeroRewardVault() public {
            // set up underlying token and nested ERC4626 vaults
            MockERC20 underlying = new MockERC20("UNDER", "UND", 18);
            MockERC4626 lpToken = new MockERC4626(underlying, "LP", "LP");
            MockERC4626 rewardVault = new MockERC4626(lpToken, "RV", "RV");
    
            // deploy fuse implementation and plasma vault mock (delegatecalls into fuse)
            StakeDaoV2SupplyFuse fuseImpl = new StakeDaoV2SupplyFuse(1);
            PlasmaVaultMock plasmaVault = new PlasmaVaultMock(address(fuseImpl), address(0));
    
            // grant rewardVault as allowed substrate in market 1 so isSubstrateAsAssetGranted == true
            address[] memory assets = new address[](1);
            assets[0] = address(rewardVault);
            plasmaVault.grantAssetsToMarket(1, assets);
    
            // mint underlying into plasmaVault and perform enter flow to get rewardVault shares
            underlying.mint(address(plasmaVault), 1_000 ether);
    
            // build enter data and call via PlasmaVaultMock
            StakeDaoV2SupplyFuseEnterData memory enterDataStruct = StakeDaoV2SupplyFuseEnterData({
                rewardVault: address(rewardVault),
                lpTokenUnderlyingAmount: 1_000 ether,
                minLpTokenUnderlyingAmount: 1_000 ether
            });
    
            bytes memory enterCalldata = abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                enterDataStruct
            );
            plasmaVault.execute(address(fuseImpl), enterCalldata);
    
            // choose a non‑zero amount so instantWithdraw enters the else branch after amount == 0 check
            uint256 amount = 100 ether;
    
            // prepare params: params[0] = amount, params[1] = rewardVault address encoded as bytes32
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(amount);
            params[1] = PlasmaVaultConfigLib.addressToBytes32(address(rewardVault));
    
            // call instantWithdraw via PlasmaVaultMock so that `address(this)` inside fuse is plasmaVault
            plasmaVault.instantWithdraw(params);
            // if the call does not revert, the opix-target-branch-243-False else‑branch was executed
        }

    function test_instantWithdraw_ZeroRewardVault() public {
            // Deploy fuse with non-zero marketId
            StakeDaoV2SupplyFuse fuse = new StakeDaoV2SupplyFuse(1);
    
            // Non‑zero amount so we pass the first if(amount == 0) check
            uint256 amount = 1 ether;
    
            // Prepare params so that rewardVault decodes to address(0)
            // params[0] = amount, params[1] = bytes32(0) -> address(0)
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(amount);
            params[1] = bytes32(0); // rewardVault = address(0) -> opix-target-branch-249-True
    
            // Call instantWithdraw; it should hit the `if (address(rewardVault) == address(0)) { return; }` branch
            fuse.instantWithdraw(params);
    
            // If we reach here without reverting, the True branch at line 249 has been covered
        }

    function test_enterTransient_opixBranch267True() public {
            // deploy underlying and nested ERC4626 vaults
            MockERC20 underlying = new MockERC20("UNDER", "UND", 18);
            MockERC4626 lpToken = new MockERC4626(underlying, "LP", "LP");
            MockERC4626 rewardVault = new MockERC4626(lpToken, "RV", "RV");
    
            // deploy fuse implementation with non‑zero market id
            StakeDaoV2SupplyFuse fuseImpl = new StakeDaoV2SupplyFuse(1);
    
            // deploy PlasmaVaultMock to delegatecall into fuse and use vault storage
            PlasmaVaultMock plasmaVault = new PlasmaVaultMock(address(fuseImpl), address(0));
    
            // grant rewardVault as allowed substrate so isSubstrateAsAssetGranted == true
            address[] memory assets = new address[](1);
            assets[0] = address(rewardVault);
            plasmaVault.grantAssetsToMarket(1, assets);
    
            // mint underlying into plasmaVault so enter has balance to work with
            underlying.mint(address(plasmaVault), 1_000 ether);
    
            // prepare transient inputs for VERSION == address(fuseImpl)
            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = bytes32(uint256(uint160(address(rewardVault))));
            inputs[1] = bytes32(uint256(1_000 ether));
            inputs[2] = bytes32(uint256(500 ether));
            plasmaVault.setInputs(address(fuseImpl), inputs);
    
            // call enterTransient via delegatecall from plasmaVault
            bytes memory data = abi.encodeWithSignature("enterTransient()");
            plasmaVault.execute(address(fuseImpl), data);
    
            // read outputs from transient storage and perform basic sanity checks
            bytes32[] memory outputs = plasmaVault.getOutputs(address(fuseImpl));
            assertEq(outputs.length, 4, "outputs length should be 4");
            // decoded rewardVault address should match
            assertEq(address(uint160(uint256(outputs[0]))), address(rewardVault), "rewardVault mismatch");
        }
}