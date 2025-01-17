// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BimaOwnable} from "../dependencies/BimaOwnable.sol";

contract TokenWrapperFactory {
    mapping(address token => address wrapper) public tokenToWrapper;

    address public immutable factory;

    constructor(address _factoryAddress) {
        factory = _factoryAddress;
    }

    function createWrapper(address _token) external {
        require(msg.sender == factory, "!factory");

        require(tokenToWrapper[_token] == address(0), "Wrapper already exists");

        tokenToWrapper[_token] = address(new TokenWrapper(ERC20(_token)));
    }

    function getWrapper(IERC20 _token) external view returns (TokenWrapper _wrapper) {
        _wrapper = TokenWrapper(tokenToWrapper[address(_token)]);
    }
}

contract TokenWrapper is ERC20 {
    ERC20 public immutable underlyingToken;

    uint256 private immutable CONVERSION_FACTOR;

    constructor(ERC20 _underlyingToken) ERC20(_underlyingToken.name(), _underlyingToken.symbol()) {
        underlyingToken = _underlyingToken;

        CONVERSION_FACTOR = 18 - _underlyingToken.decimals();
    }

    function wrap(uint256 _underlyingAmount) external returns (uint256 _wrappedAmount) {
        underlyingToken.transferFrom(msg.sender, address(this), _underlyingAmount);

        _wrappedAmount = previewWrappedAmount(_underlyingAmount);

        _mint(msg.sender, _wrappedAmount);
    }

    function unwrap(uint256 _wrappedAmount) external returns (uint256 _underlyingAmount) {
        _burn(msg.sender, _wrappedAmount);

        _underlyingAmount = previewUnwrappedAmount(_wrappedAmount);

        underlyingToken.transfer(msg.sender, _underlyingAmount);
    }

    function previewWrappedAmount(uint256 _underlyingAmount) public view returns (uint256 _wrappedAmount) {
        _wrappedAmount = _underlyingAmount * 10 ** CONVERSION_FACTOR;
    }

    function previewUnwrappedAmount(uint256 _wrappedAmount) public view returns (uint256 _underlyingAmount) {
        _underlyingAmount = _wrappedAmount / (10 ** CONVERSION_FACTOR);
    }
}
