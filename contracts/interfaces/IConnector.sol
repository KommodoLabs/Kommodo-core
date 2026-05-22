// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

/// @title The interface for the connector between Kommodo and Uniswap v3 pools
/// @notice The connector allows Kommodo pools to directly call Uniswap v3 pool functions
interface IConnector {
    /// @notice Returns the Uniswap v3 factory
    /// @return The address of the Uniswap v3 factory
    function factory() external view returns (address);

    /// @notice Stores the Uniswap v3 factory 
    /// @param _factory The address of the Uniswap v3 factory
    function initialize(address _factory) external;

    /// @notice Returns the current tokens owed from the Uniswap v3 pool
    /// @param tokenA The first token of the Uniswap v3 pool
    /// @param tokenB The second token of the Uniswap v3 pool
    /// @param poolFee The fee of the Uniswap v3 pool
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @return tokensOwed0 The token0 amount owed
    /// @return tokensOwed1 The token1 amount owed
    function tokensOwed(address tokenA, address tokenB, uint24 poolFee, int24 tickLower, int24 tickUpper) external view
        returns(uint128 tokensOwed0, uint128 tokensOwed1);
}