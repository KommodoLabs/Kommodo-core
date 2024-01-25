// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.19;

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

import './libraries/PoolAddress.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityAmounts.sol';
import './libraries/CallbackValidation.sol';

/**
* @dev Connector - library to connect to AMM                          
*/
abstract contract Connector is IUniswapV3MintCallback {
    
    address immutable factory;

    struct MintCallbackData {
        PoolAddress.PoolKey poolKey;
        address payer;
    }

    constructor(address _factory) {
        factory = _factory;
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);
        TransferHelper.safeTransferFrom(decoded.poolKey.token0, decoded.payer, msg.sender, amount0Owed);
        TransferHelper.safeTransferFrom(decoded.poolKey.token1, decoded.payer, msg.sender, amount1Owed);
    }

    function addLiquidity(address tokenA, address tokenB, uint24 poolFee, int24 tickLower, int24 tickUpper, uint128 amountA, uint128 amountB) 
        internal 
        returns(
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            IUniswapV3Pool pool
        )
    {
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({token0: tokenA, token1: tokenB, fee: poolFee});
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));
        // compute the liquidity amount
        {
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
            uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
            uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);            
            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                sqrtRatioAX96,
                sqrtRatioBX96,
                amountA,
                amountB
            );
        }
        // mint pool position
        (amount0, amount1) = pool.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender}))
        );
    }

    function removeLiquidity(address tokenA, address tokenB, uint24 poolFee, int24 tickLower, int24 tickUpper, uint128 liquidity) 
        internal 
        returns(
            uint256 amount0,
            uint256 amount1,
            IUniswapV3Pool pool
        ) 
    {
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({token0: tokenA, token1: tokenB, fee: poolFee});
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));
        (amount0, amount1) = pool.burn(tickLower, tickUpper, liquidity);
    }

    function collectLiquidity(address tokenA, address tokenB, uint24 poolFee, int24 tickLower, int24 tickUpper, uint128 amountA, uint128 amountB) 
        internal 
        returns(
            uint256 amount0,
            uint256 amount1,
            IUniswapV3Pool pool
        )
    {
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({token0: tokenA, token1: tokenB, fee: poolFee});
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));
        (amount0, amount1) = pool.collect(
            msg.sender,
            tickLower,
            tickUpper,
            amountA,
            amountB
        );
    }
}




 


