// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-periphery/contracts/libraries/PositionKey.sol';

import './interfaces/IConnector.sol';
import './libraries/TickMath.sol';
import './libraries/PoolAddress.sol';
import './libraries/SqrtPriceMath.sol'; 
import './libraries/CallbackValidation.sol';

abstract contract Connector is IConnector, IUniswapV3MintCallback, Initializable {
    
    /// @inheritdoc IConnector
    address public override factory;

    // Uniswap v3 callback data
    struct MintCallbackData {
        // Uniswap v3 pool identifier based on token0/token1/fee
        PoolAddress.PoolKey poolKey;
        // Uniswap v3 pool returned payer address
        address payer;
    }

    /// @notice On setup stores the Uniswap v3 factory
    /// @param _factory The address of the Uniswap v3 factory
    function __Connector_init(address _factory) internal onlyInitializing {
            factory = _factory;
    }

    /// @inheritdoc IUniswapV3MintCallback
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        CallbackValidation.verifyCallback(factory, decoded.poolKey);
        if (amount0Owed > 0) TransferHelper.safeTransferFrom(decoded.poolKey.token0, decoded.payer, msg.sender, amount0Owed);
        if (amount1Owed > 0) TransferHelper.safeTransferFrom(decoded.poolKey.token1, decoded.payer, msg.sender, amount1Owed);
    }

    /// @notice Add liquidity to Uniswap v3 pool
    /// @param tokenA The first token of the Uniswap v3 pool
    /// @param tokenB The second token of the Uniswap v3 pool
    /// @param poolFee The fee of the Uniswap v3 pool
    /// @param tickLower The lower tick position to add liqudity
    /// @param tickUpper The upper tick position to add liqudity
    /// @param amount The liquidity amount to add
    /// @return liquidity The liquidity added
    /// @return amount0 The token0 amount deposited for the liquidity
    /// @return amount1 The token1 amount deposited for the liquidity
    /// @return pool The Uniswap v3 pool address
    function addLiquidity(address tokenA, address tokenB, uint24 poolFee, int24 tickLower, int24 tickUpper, uint128 amount)
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
        // mint pool position
        liquidity = amount;
        (amount0, amount1) = pool.mint(
            address(this),
            tickLower,
            tickUpper,
            liquidity,
            abi.encode(MintCallbackData({poolKey: poolKey, payer: msg.sender}))
        );
    }

    /// @notice Remove liquidity from Uniswap v3 pool
    /// @param tokenA The first token of the Uniswap v3 pool
    /// @param tokenB The second token of the Uniswap v3 pool
    /// @param poolFee The fee of the Uniswap v3 pool
    /// @param tickLower The lower tick position to remove liqudity
    /// @param tickUpper The upper tick position to remove liqudity
    /// @param liquidity The liquidity amount to remove
    /// @return amount0 The token0 amount removed for the liquidity
    /// @return amount1 The token1 amount removed for the liquidity
    /// @return pool The Uniswap v3 pool address
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

    /// @notice Collect amounts from Uniswap v3 pool
    /// @param tokenA The first token of the Uniswap v3 pool
    /// @param tokenB The second token of the Uniswap v3 pool
    /// @param receiver The receiver of the withdrawn token amounts
    /// @param poolFee The fee of the Uniswap v3 pool
    /// @param tickLower The lower tick position to remove liqudity
    /// @param tickUpper The upper tick position to remove liqudity
    /// @param amountA The maximum token0 amount to withdraw when available
    /// @param amountB The maximum token1 amount to withdraw when available
    /// @return amount0 The token0 amount withdrawn 
    /// @return amount1 The token1 amount withdrawn
    /// @return pool The Uniswap v3 pool address
    function collectAmounts(address tokenA, address tokenB, address receiver, uint24 poolFee, int24 tickLower, int24 tickUpper, uint128 amountA, uint128 amountB) 
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
            receiver,
            tickLower,
            tickUpper,
            amountA,
            amountB
        );
    }
 
    /// @inheritdoc IConnector
    function tokensOwed(address tokenA, address tokenB, uint24 poolFee, int24 tickLower, int24 tickUpper) 
        public
        view
        override
        returns(
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) 
    {
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({token0: tokenA, token1: tokenB, fee: poolFee});
        IUniswapV3Pool pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, poolKey));
        bytes32 positionKey = PositionKey.compute(address(this), tickLower, tickUpper);
        (, , , tokensOwed0, tokensOwed1) = pool.positions(positionKey);
    }
}