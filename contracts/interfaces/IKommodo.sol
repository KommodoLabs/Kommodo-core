// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

/**
* @dev Interface Kommodo - permissionless lending protocol                            
*/
interface IKommodo {
    
    event Provide(
        address indexed owner,
        int24 indexed tickLower,
        uint128 liquidity,
        uint256 amountA,
        uint256 amountB
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
        uint128 amountCol,
        uint128 interest,
        uint256 borA,
        uint256 borB
    );

    event Adjust(
        bool indexed token0,
        address owner,
        int24 indexed tickBor,
        uint128 liquidityBor,
        uint256 amountCol,
        uint128 interest,
        uint256 borA,
        uint256 borB
    );

    event Close(
        bool indexed token0,
        address sender,
        address indexed owner,
        int24 indexed tickBor,
        uint128 liquidityBor,
        uint256 amountCol,
        uint256 borA,
        uint256 borB
    );

    struct CreateParams { 
        address factory;
        address tokenA; 
        address tokenB; 
        int24 tickSpacing; 
        uint24 fee; 
        uint24 multiplier;  
    } 

    struct Assets { 
        uint128 liquidity;
        uint128 locked;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
    } 
    
    struct Lender { 
        uint128 liquidity;
        uint128 locked;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 blocknumber;
    } 

    struct Withdraws { 
        uint128 amountA;
        uint128 amountB;
    }

    struct Loan {
        uint128 liquidityBor;
        uint128 amountCol;
        uint128 interest;
        uint256 start;
    }

    function assets(int24 tick)
        external returns(
            uint128 liquidity,
            uint128 locked,
            uint256 feeGrowth0X128,
            uint256 feeGrowth1X128
        );

    function lender(int24 tick, address owner)
        external returns(
            uint128 liquidity,
            uint128 locked,
            uint256 feeGrowth0X128,
            uint256 feeGrowth1X128,
            uint256 blocknumber
        );

    function withdraws(int24 tick, address owner)
        external returns(
            uint128 amountA,
            uint128 amountB
        );
    
    function borrower(bytes32 key)
        external returns(
            uint128 liquidityBor,
            uint128 amountCol,
            uint128 interest,
            uint256 start
        );

    struct ProvideParams { 
        int24 tickLower; 
        uint128 liquidity;
        uint128 amountMaxA; 
        uint128 amountMaxB;   
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
        external returns(uint256 amountA, uint256 amountB);

    struct OpenParams { 
        bool token0;
        int24 tickBor; 
        uint128 liquidityBor;
        uint128 borAMin;
        uint128 borBMin; 
        uint128 colAmount; 
        int128 interest; 
    } 

    function withdraw( 
        int24 tickLower,
        address recipient, 
        uint128 amount0Requested,
        uint128 amount1Requested
    )
        external;

    function open(OpenParams calldata params)
        external;

    struct AdjustParams {
        bool token0;
        int24 tickBor; 
        uint128 liquidityBor;
        uint128 borAMax;
        uint128 borBMax; 
        uint128 amountCol;
        int128 interest; 
    } 

    function adjust(AdjustParams calldata params)
        external;

    struct CloseParams {
        bool token0;
        address owner;  
        int24 tickBor;
        uint128 borAMax;
        uint128 borBMax;  
    } 

    function close(CloseParams calldata params)
        external;

    function setInterest(bool token0, int24 tickBor, int128 delta)
        external;

    function getFee(uint256 amount) 
        external view returns(uint256);
 
}




 


