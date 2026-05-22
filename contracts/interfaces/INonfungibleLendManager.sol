// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

import './IKommodoFactory.sol';

/// @title The interface for Non Fungible Token lender Liquidity positions
/// @notice Wraps Kommodo pool lender positions in a non-fungible token interface which allows for them to be transferred
interface INonfungibleLendManager {
    /// @notice Returns the Kommodo factory
    /// @return The Kommodo factory
    function factory() external view returns (IKommodoFactory);
    
    // NFT position info stored
    struct Position { 
        // Kommodo pool address
        address pool;
        // tick of the position
        int24 tickLower;
        // liquidity locked for withdraw 
        uint128 locked;
        // liquidity in the position
        uint128 liquidity;
        // last updated blocknumber for locked liquidity
        uint256 blocknumber;
        // fee growth of token0 for this position 
        uint256 feeGrowth0X128;
        // fee growth of token1 for this position 
        uint256 feeGrowth1X128;
        // available withdraw amounts of token0
        uint128 withdrawA;
        // available withdraw amounts of token1
        uint128 withdrawB; 
    }  

    /// @notice Returns the position info for the token id
    /// @param tokenId The id of the NFT
    /// @return pool The Kommodo pool address
    /// @return tickLower The tick of the position
    /// @return locked The liquidity locked for withdraw
    /// @return liquidity The liquidity in the position
    /// @return blocknumber The last updated blocknumber for locked liquidity
    /// @return feeGrowth0X128 The fee growth of token0 for this position 
    /// @return feeGrowth1X128 The fee growth of token1 for this position 
    /// @return withdrawA The available withdraw amounts of token0
    /// @return withdrawB The available withdraw amounts of token1
    function position(uint256 tokenId)
        external returns(
            address pool,
            int24 tickLower,
            uint128 locked,
            uint128 liquidity,
            uint256 blocknumber,
            uint256 feeGrowth0X128,
            uint256 feeGrowth1X128,
            uint128 withdrawA,
            uint128 withdrawB 
        );

    /// @notice Approve a Kommodo pool to transfer funds from this contract
    /// @dev Anyone can approve any pool. It has to be a valid Kommodo pool, verified using the KommodoFactory.
    /// @dev TokenA and TokenB are order agnostic for this function
    /// @param tokenA The first token to approve
    /// @param tokenB The second token to approve
    /// @param poolFee The Kommodo pool fee (matches underlying Uniswap v3 fee)
    function poolApprove(address tokenA, address tokenB, uint24 poolFee) external;


    /// @notice Deploy and approve a Kommodo pool
    /// @dev TokenA and TokenB are order agnostic for this function
    /// @param token0 One of the two tokens in the desired pool
    /// @param token1 The other of the two tokens in the desired pool
    /// @param poolFee The Kommodo pool fee (matches underlying Uniswap v3 fee)
    function deploy(address token0, address token1, uint24 poolFee) external;

    // input params for minting new NFT lender position
    struct MintParams { 
        // token0 of the Kommodo pool
        address assetA;
        // token1 of the Kommodo pool
        address assetB;
        // Kommodo pool fee (matches underlying Uniswap v3 fee)
        uint24 poolFee;
        // tick at which to provide the liquidity
        int24 tickLower; 
        // liquidity amount to provide
        uint128 liquidity;
        // maximum pool token0 amount for liquidity to deposit
        uint128 amountMaxA; 
        // maximum pool token1 amount for liquidity to deposit
        uint128 amountMaxB;     
    } 

    /// @notice Creates a new position wrapped in a NFT
    /// @dev Call this when the pool does exist and is initialized. Note that if the pool is created but not initialized
    /// a method does not exist, i.e. the pool is assumed to be initialized.
    /// @param params MintParams assetA/assetB/poolFee/tickLower/liquidity/amountMaxA/amountMaxB
    function mint(MintParams calldata params) external; 

    // input params for increasing liquidity in an existing NFT lender position
    struct ProvideParams {
        // identifier of the NFT 
        uint256 tokenId;
        // liquidity amount to provide
        uint128 liquidity;
        // maximum token0 amount for liquidity to deposit
        uint128 amountMaxA; 
        // maximum token1 amount for liquidity to deposit
        uint128 amountMaxB;       
    } 

    /// @notice Increases the amount of liquidity in a position, with tokens paid by the `msg.sender`
    /// @param params ProvideParams tokenId/liquidity/amountMaxA/amountMaxB
    function provide(ProvideParams calldata params) external;

    // input params for decreasing liquidity in an existing NFT lender position
    struct TakeParams { 
        // identifier of the NFT 
        uint256 tokenId;
        // liquidity amount to remove
        uint128 liquidity; 
        // minimum token0 amount for liquidity to remove
        uint128 amountMinA; 
        // minimum token1 amount for liquidity to remove
        uint128 amountMinB; 
        // receiver of the withdrawn assets
        address recipient;   
    }

    /// @notice Decreases the amount of liquidity in a position, can only be called by the NFT owner
    /// @param params TakeParams tokenId/liquidity/amountMinA/amountMinB/recipient
    function take(TakeParams calldata params) external;

    // input params to withdraw amounts from the NFT position
    struct WithdrawParams {
        // identifier of the NFT 
        uint256 tokenId;
        // maximum token0 amount to withdraw when available
        uint128 amountA; 
        // maximum token1 amount to withdraw when available
        uint128 amountB;
        // receiver of the withdrawn assets  
        address recipient; 
    }

    /// @notice Withdraw the amounts available for this position, can only be called by the NFT owner
    /// @param params WithdrawParams tokenId/amountA/amountB/recipient
    function withdraw(WithdrawParams calldata params) external;

    /// @notice Remove empty NFT, can only be called by the NFT owner
    /// @param tokenId The identifier of the NFT
    function burn(uint256 tokenId) external;
}