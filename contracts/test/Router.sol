pragma solidity ^0.8.0;

import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

//Mock router implementation for testing
contract Router {

    address public pool;
    address public tokenA;
    address public tokenB;
    
    function initialize (address _pool, address _tokenA, address _tokenB) public {
        pool = _pool;
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata _data) public {
        //add payment logic
        uint256 amountToPay = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        address tokenPay = amount0Delta > 0 ? tokenA : tokenB;
        TransferHelper.safeTransferFrom(tokenPay, address(this), pool, uint256(amountToPay)); 
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data) public {
        IUniswapV3Pool(pool).swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data);
    }
}