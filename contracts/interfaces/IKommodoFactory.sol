// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

/// @title The interface for the Kommodo Factory
/// @notice The Kommodo Factory facilitates creation of Kommodo pools
interface IKommodoFactory {
    /// @notice Returns the Uniswap v3 factory
    /// @return The address of the Uniswap v3 factory
    function factory() external view returns (address);

    /// @notice Returns the fee multiplier applied to the Uniswap v3 fee
    /// @return The multiplier used for all kommodo pools created through this factory
    function multiplier() external view returns (uint24);

    /// @notice Returns the Kommodo pool address for a given pair of tokens and a fee, or address 0 if it does not exist
    /// @dev assetA and assetB may be passed in either token0/token1 or token1/token0 order
    /// @param assetA The contract address of either token0 or token1
    /// @param assetB The contract address of the other token
    /// @param poolFee The Uniswap v3 fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @return The Kommodo pool address
    function kommodo(
        address assetA,
        address assetB,
        uint24 poolFee
    ) external view returns (address);

    /// @notice Returns all deployed Kommodo pools
    /// @param index The index of the Kommodo pool in the array
    /// @return The address array of Kommodo pools
    function allKommodo(uint256 index) external view returns (address);

    /// @notice Returns total number of deployed Kommodo pools
    /// @return The total number of deployed Kommodo pools
    function allKommodoLength() external view returns (uint256);

    /// @notice Creates a Kommodo pool for the given two tokens and Uniswap v3 fee
    /// @param assetA One of the two tokens in the desired pool
    /// @param assetB The other of the two tokens in the desired pool
    /// @param poolFee The desired Uniswap v3 fee for the pool
    /// @dev assetA and assetB may be passed in either order: token0/token1 or token1/token0. tickSpacing is retrieved
    /// from the Uniswap v3 factory for the fee. The call will revert if the pool already exists, the fee is invalid, or the token arguments
    /// are invalid.
    /// @return The address of the newly created Kommodo pool
    function createKommodo(address assetA, address assetB, uint24 poolFee)
        external returns (address);

}