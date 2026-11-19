// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {PriceOracleMiddlewareManagerLib} from "../../contracts/managers/price/PriceOracleMiddlewareManagerLib.sol";

/// @dev Minimal middleware reporting a configurable quote currency
contract QuoteCurrencyMiddlewareMock {
    address public immutable QUOTE_CURRENCY;

    constructor(address quoteCurrency_) {
        QUOTE_CURRENCY = quoteCurrency_;
    }
}

/// @dev Middleware without the QUOTE_CURRENCY() getter
contract NoQuoteCurrencyMiddlewareMock {
    function getAssetPrice(address) external pure returns (uint256, uint256) {
        return (1e18, 18);
    }
}

/// @dev Middleware whose QUOTE_CURRENCY() returns a malformed (short) payload
contract MalformedQuoteCurrencyMiddlewareMock {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

/// @title IL-9649: the manager accepts only middlewares quoting in its own QUOTE_CURRENCY (USD)
contract PriceOracleMiddlewareManagerQuoteCurrencyTest is Test {
    address private constant _AUTHORITY = address(0xA11CE);
    address private constant _EUR = address(0x00000000000000000000000000000000000003d2);

    PriceOracleMiddlewareManager private _manager;
    address private _usdMiddleware;
    address private _eurMiddleware;

    function setUp() public {
        _usdMiddleware = address(new QuoteCurrencyMiddlewareMock(address(0x348)));
        _eurMiddleware = address(new QuoteCurrencyMiddlewareMock(_EUR));
        _manager = new PriceOracleMiddlewareManager(_AUTHORITY, _usdMiddleware);
    }

    function testConstructorAcceptsUsdMiddleware() public view {
        assertEq(_manager.getPriceOracleMiddleware(), _usdMiddleware);
    }

    function testConstructorRevertsForNonUsdMiddleware() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPriceOracleMiddlewareQuoteCurrency(address)", _eurMiddleware));
        new PriceOracleMiddlewareManager(_AUTHORITY, _eurMiddleware);
    }

    function testProxyInitializeRevertsForNonUsdMiddleware() public {
        PriceOracleMiddlewareManager clone = PriceOracleMiddlewareManager(_clone(address(_manager)));
        vm.expectRevert(abi.encodeWithSignature("InvalidPriceOracleMiddlewareQuoteCurrency(address)", _eurMiddleware));
        clone.proxyInitialize(_AUTHORITY, _eurMiddleware);
    }

    function testInitializeRevertsForMiddlewareWithoutCode() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidPriceOracleMiddlewareQuoteCurrency(address)", address(0x999)));
        new PriceOracleMiddlewareManager(_AUTHORITY, address(0x999));
    }

    function testInitializeZeroMiddlewareKeepsExistingError() public {
        vm.expectRevert(PriceOracleMiddlewareManager.InvalidPriceOracleMiddleware.selector);
        new PriceOracleMiddlewareManager(_AUTHORITY, address(0));
    }

    function testSetterRevertsForNonUsdMiddleware() public {
        vm.mockCall(
            _AUTHORITY,
            abi.encodeWithSignature("canCall(address,address,bytes4)"),
            abi.encode(true, uint32(0))
        );
        vm.expectRevert(abi.encodeWithSignature("InvalidPriceOracleMiddlewareQuoteCurrency(address)", _eurMiddleware));
        _manager.setPriceOracleMiddleware(_eurMiddleware);
        assertEq(_manager.getPriceOracleMiddleware(), _usdMiddleware, "middleware must not change");
    }

    function testSetterRevertsForMiddlewareWithoutGetter() public {
        address noGetter = address(new NoQuoteCurrencyMiddlewareMock());
        _allowAll();
        vm.expectRevert(abi.encodeWithSignature("InvalidPriceOracleMiddlewareQuoteCurrency(address)", noGetter));
        _manager.setPriceOracleMiddleware(noGetter);
    }

    function testSetterRevertsForMalformedGetterReturn() public {
        address malformed = address(new MalformedQuoteCurrencyMiddlewareMock());
        _allowAll();
        vm.expectRevert(abi.encodeWithSignature("InvalidPriceOracleMiddlewareQuoteCurrency(address)", malformed));
        _manager.setPriceOracleMiddleware(malformed);
    }

    function testSetterRevertsForMiddlewareWithoutCode() public {
        _allowAll();
        vm.expectRevert(abi.encodeWithSignature("InvalidPriceOracleMiddlewareQuoteCurrency(address)", address(0x999)));
        _manager.setPriceOracleMiddleware(address(0x999));
    }

    function testSetterAcceptsUsdMiddleware() public {
        address other = address(new QuoteCurrencyMiddlewareMock(address(0x348)));
        _allowAll();
        _manager.setPriceOracleMiddleware(other);
        assertEq(_manager.getPriceOracleMiddleware(), other);
    }

    function testSetterZeroAddressKeepsExistingError() public {
        _allowAll();
        vm.expectRevert(PriceOracleMiddlewareManagerLib.PriceOracleMiddlewareCanNotBeZero.selector);
        _manager.setPriceOracleMiddleware(address(0));
    }

    function _allowAll() private {
        vm.mockCall(
            _AUTHORITY,
            abi.encodeWithSignature("canCall(address,address,bytes4)"),
            abi.encode(true, uint32(0))
        );
    }

    function _clone(address implementation_) private returns (address instance) {
        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            implementation_,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        assembly {
            instance := create(0, add(code, 0x20), mload(code))
        }
    }
}
