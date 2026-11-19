// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {PlasmaVaultSlippageRouter} from "../../contracts/zaps/PlasmaVaultSlippageRouter.sol";

/// @dev Access manager that lets every caller through, so that the router reaches the vault call
contract OpenAccessManagerForRouterMint {
    function canCall(address, address, bytes4) external pure returns (bool immediate, uint32 delay) {
        return (true, 0);
    }
}

/// @dev Vault whose `mint` reports `reportedAssets` (it may be above the allowance) and pulls at most the allowance
contract OverchargingMintVault {
    address public immutable ASSET;
    address public immutable AUTHORITY;
    uint256 public reportedAssets;

    constructor(address asset_, address authority_) {
        ASSET = asset_;
        AUTHORITY = authority_;
    }

    function asset() external view returns (address) {
        return ASSET;
    }

    function authority() external view returns (address) {
        return AUTHORITY;
    }

    function setReportedAssets(uint256 reportedAssets_) external {
        reportedAssets = reportedAssets_;
    }

    function mint(uint256, address) external returns (uint256) {
        uint256 pulled = reportedAssets < IERC20(ASSET).allowance(msg.sender, address(this))
            ? reportedAssets
            : IERC20(ASSET).allowance(msg.sender, address(this));
        IERC20(ASSET).transferFrom(msg.sender, address(this), pulled);
        return reportedAssets;
    }
}

/// @notice The router's own `SlippageExceeded` on `mint` (assets spent above `maxAssets`), reached without a fork
///         (IL-9681). The fork test only reaches the allowance revert of the vault.
contract PlasmaVaultSlippageRouterMintSlippageTest is Test {
    uint256 private constant MAX_ASSETS = 1_000e6;
    uint256 private constant REPORTED_ASSETS = 1_001e6;

    address private constant USER = address(0xA11CE);

    MockERC20 private _usdc;
    OverchargingMintVault private _vault;
    PlasmaVaultSlippageRouter private _router;

    function setUp() public {
        _usdc = new MockERC20("USDC", "USDC", 6);
        _vault = new OverchargingMintVault(address(_usdc), address(new OpenAccessManagerForRouterMint()));
        _router = new PlasmaVaultSlippageRouter();
        _usdc.mint(USER, MAX_ASSETS);
    }

    function testShouldRevertRouterMintWhenVaultSpendsMoreThanMaxAssets() public {
        // given: the vault reports one unit above what the user allowed
        _vault.setReportedAssets(REPORTED_ASSETS);
        vm.startPrank(USER);
        _usdc.approve(address(_router), MAX_ASSETS);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultSlippageRouter.SlippageExceeded.selector, REPORTED_ASSETS, MAX_ASSETS)
        );
        _router.mint(address(_vault), 1, USER, MAX_ASSETS);
        vm.stopPrank();

        assertEq(_usdc.balanceOf(USER), MAX_ASSETS, "user keeps assets");
        assertEq(_usdc.balanceOf(address(_router)), 0, "router holds nothing");
    }

    function testShouldRefundUnspentWhenVaultSpendsLessThanMaxAssets() public {
        // given: the vault spends 600 of the 1_000 allowed
        _vault.setReportedAssets(600e6);
        vm.startPrank(USER);
        _usdc.approve(address(_router), MAX_ASSETS);

        // when
        uint256 assets = _router.mint(address(_vault), 1, USER, MAX_ASSETS);
        vm.stopPrank();

        // then
        assertEq(assets, 600e6, "assets spent returned");
        assertEq(_usdc.balanceOf(USER), MAX_ASSETS - 600e6, "unspent part refunded");
        assertEq(_usdc.balanceOf(address(_router)), 0, "router holds nothing");
    }
}
