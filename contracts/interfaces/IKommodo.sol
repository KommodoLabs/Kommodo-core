// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.19;

/**
* @dev Interface Kommodo - permissionless lending protocol                            
*/
interface IKommodo {
    
    event Provide(
        address indexed owner,
        int24 indexed tickLower,
        uint128 liquidity,
        uint128 amountA,
        uint128 amountB
    );

    event Take(
        address indexed owner,
        int24 indexed tickLower,
        uint128 liquidity,
        uint256 amountA,
        uint256 amountB
    );

    event Withdraw(
        address indexed owner,
        int24 indexed tickLower,
        uint256 amountA,
        uint256 amountB
    );

    event Open(
        bool indexed token0,
        address indexed owner,
        int24 indexed tickBor,
        uint128 liquidityBor,
        uint256 borA,
        uint256 borB,
        uint128 amountCol
    );

    event Close(
        address sender,
        bool indexed token0,
        address indexed owner,
        int24 indexed tickBor,
        uint128 liquidityBor,
        uint256 borA,
        uint256 borB,
        uint256 amountCol
    );

    event FullClose(
        bool indexed token0,
        address indexed owner,
        int24 indexed tickBor
    );

    event PartialClose(
        bool indexed token0,
        address indexed owner,
        int24 indexed tickBor   
    );

    struct CreateParams { 
        address factory; 
        address tokenA; 
        address tokenB; 
        int24 tickSpacing; 
        uint24 fee; 
        uint128 multiplier; 
        uint256 delay;  
    } 

    struct ProvideParams { 
        int24 tickLower; 
        uint128 amountA; 
        uint128 amountB;      
    } 

    function provide(ProvideParams calldata params)
        external;

    struct TakeParams { 
        int24 tickLower;
        uint128 liquidity; 
        uint128 amountMinA; 
        uint128 amountMinB;   
    } 

    function take(TakeParams calldata params)
        external;

    struct OpenParams { 
        int24 tickBor; 
        uint128 liquidityBor;
        uint128 borAMin;
        uint128 borBMin; 
        uint128 colA; 
        uint128 colB; 
        uint128 interest; 
    } 

    function open(OpenParams calldata params)
        external;

    struct CloseParams {
        bool token0;
        address owner;  
        int24 tickBor; 
        uint128 liquidityBor;
        uint128 amountCol;
        uint128 interest; 
    } 

    function close(CloseParams calldata params)
        external;
}




 


