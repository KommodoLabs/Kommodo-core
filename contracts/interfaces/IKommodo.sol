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
        uint128 shares,
        uint128 amountA,
        uint128 amountB
    );

    event Take(
        address indexed owner,
        address indexed receiver,
        int24 indexed tickLower,
        uint128 liquidity,
        uint128 shares,
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
        address indexed owner,
        int24 indexed tickLowerCol,
        int24 indexed tickLowerBor,
        uint128 liquidityCol,
        uint128 liquidityBor,
        uint256 amountA,
        uint256 amountB
    );

    event Close(
        address sender,
        address indexed owner,
        int24 indexed tickLowerCol,
        int24 indexed tickLowerBor,
        uint128 liquidityCol,
        uint128 liquidityBor,
        uint256 amountA,
        uint256 amountB
    );

    event FullClose(
        address indexed owner,
        int24 indexed tickLowerCol,
        int24 indexed tickLowerBor
    );

    event PartialClose(
        address indexed owner,
        int24 indexed tickLowerCol,
        int24 indexed tickLowerBor
    );

    struct OpenParams { 
        int24 tickLowerBor; 
        int24 tickLowerCol; 
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
        int24 tickLowerBor; 
        int24 tickLowerCol; 
        uint128 liquidityBor;
        uint128 liquidityCol;
        uint128 interest; 
        address owner; 
    } 

    function close(CloseParams calldata params)
        external;
}




 


