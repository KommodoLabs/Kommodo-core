// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

/// @title The interface for a Kommodo pool
/// @notice A Kommodo pool facilitates lending an borrowing of underlying Uniswap v3 CLP's
interface IKommodo {
    /// @notice Emitted when (lender) liquidity is provided for a given position
    /// @param owner The address that minted the liquidity
    /// @param tickLower The lower tick of the position
    /// @param liquidity The liquidity amount provided
    /// @param amountA The assetA amount provided for the liquidity
    /// @param amountB The assetB amount provided for the liquidity
    event Provide(
        address indexed owner,
        int24 indexed tickLower,
        uint128 liquidity,
        uint256 amountA,
        uint256 amountB
    );

    /// @notice Emitted when (lender) liquidity is removed for a given position
    /// @param owner The address that owns the position
    /// @param tickLower The lower tick of the position
    /// @param liquidity The liquidity amount removed
    /// @param amountA The assetA amount removed for the liquidity
    /// @param amountB The assetB amount removed for the liquidity
    event Take(
        address indexed owner,
        int24 indexed tickLower,
        uint128 liquidity,
        uint256 amountA,
        uint256 amountB
    );

    /// @notice Emitted when fees and pending withdraws are withdrawn by the owner of a position
    /// @param owner The address that owns the position
    /// @param tickLower The lower tick of the position
    /// @param amountA The assetA amount removed withdrawn
    /// @param amountB The assetB amount removed withdrawn
    event Withdraw(
        address indexed owner,
        int24 indexed tickLower,
        uint256 amountA,
        uint256 amountB
    );

    /// @notice Emitted when a borrow position is opened
    /// @param token0 The bool value indicating use of collateral token0 or token1
    /// @param owner The address that owns the position
    /// @param tickBor The tick of the borrow position
    /// @param liquidityBor The (additional) liquidity amount borrowed
    /// @param amountCol The (additional) collateral amount deposited
    /// @param interest The latest interest amount for the total position
    /// @param borA The (additional) assetA amount borrowed for the liquidity
    /// @param borB The (additional) assetB amount borrowed for the liquidity
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

    /// @notice Emitted when a borrow position is adjusted
    /// @param token0 The bool value indicating use of collateral token0 or token1
    /// @param owner The address that owns the position
    /// @param tickBor The tick of the borrow position
    /// @param liquidityBor The liquidity amount returned
    /// @param amountCol The collateral amount removed
    /// @param interest The latest interest amount for the total position
    /// @param borA The assetA amount returned for the liquidity 
    /// @param borB The assetB amount returned for the liquidity
    event Adjust(
        bool indexed token0,
        address indexed owner,
        int24 indexed tickBor,
        uint128 liquidityBor,
        uint256 amountCol,
        uint128 interest,
        uint256 borA,
        uint256 borB
    );

    /// @notice Emitted when a borrow position is closed
    /// @param token0 The bool value indicating use of collateral token0 or token1
    /// @param sender The address that closes the position
    /// @param owner The address that owns the position
    /// @param tickBor The tick of the borrow position
    /// @param liquidityBor The liquidity amount returned
    /// @param amountCol The collateral amount removed
    /// @param borA The assetA amount returned for the liquidity 
    /// @param borB The assetB amount returned for the liquidity
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




    // @notice Emitted when interest is adjusted
    /// @param token0 The bool value indicating use of collateral token0 or token1
    /// @param owner The address that owns the position
    /// @param tickBor The tick of the borrow position
    /// @param interest The new interest amount of the position
    /// @param delta The change (deposit or withdraw) of interest for the position
    event Interest(
        bool indexed token0,
        address indexed owner,
        int24 indexed tickBor,
        uint128 interest,
        int128 delta    
    );



    /// @notice The first of the two tokens of the pool, sorted by address
    /// @return token contract address
    function tokenA() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address
    /// @return token contract address
    function tokenB() external view returns (address);

    /// @notice The Uniswap v3 fee assiciated with the underlying Uniswap v3 pool
    /// @return fee amount
    function fee() external view returns (uint24);

    /// @notice The Uniswap v3 tick spacing assiciated with the underlying Uniswap v3 pool
    /// @return spacing number
    function tickSpacing() external view returns (int24);

    /// @notice The interest rate for the kommodo pool
    /// @dev Determined by the multiplier times the underlying Uniswap v3 pool fee
    /// @return annual interest
    function rate() external view returns (uint24);

    // pool info stored for each individual tick 
    struct Assets { 
        // total liquidity deposited by lenders
        uint128 liquidity;
        // liquidity witdrawn by borrowers
        uint128 locked;
        // fee growth of token0 per tick 
        uint256 feeGrowth0X128;
        // fee growth of token1 per tick 
        uint256 feeGrowth1X128;
    } 

    /// @notice Returns the total Kommodo pool asset data
    /// @param tickLower The tick at which the assets are stored
    /// @return liquidity The liquidity deposited by lenders
    /// @return locked The liquidity witdrawn by borrowers
    /// @return feeGrowth0X128 fee growth of token0 for this tickLower 
    /// @return feeGrowth1X128 fee growth of token1 for this tickLower
    function assets(int24 tickLower) 
        external view returns (
            uint128 liquidity,
            uint128 locked,
            uint256 feeGrowth0X128,
            uint256 feeGrowth1X128
        );

    // lender position info stored for each individual tick and owner
    struct Lender { 
        // liquidity deposited in the position
        uint128 liquidity;
        // liquidity locked for withdraw 
        uint128 paused;
        // fee growth of token0 for this position 
        uint256 feeGrowth0X128;
        // fee growth of token1 for this position 
        uint256 feeGrowth1X128;
        // last updated blocknumber for locked liquidity
        uint256 blocknumber;
    } 

    /// @notice Returns the lender position data
    /// @param tickLower The tick at which the assets are stored
    /// @param owner owner of the position
    /// @return liquidity The liquidity deposited in the position
    /// @return locked The liquidity locked for withdraw 
    /// @return feeGrowth0X128 fee growth of token0 for this position 
    /// @return feeGrowth1X128 fee growth of token1 for this position
    /// @return blocknumber last updated blocknumber for locked liquidity
    function lender(int24 tickLower, address owner)
        external returns(
            uint128 liquidity,
            uint128 locked,
            uint256 feeGrowth0X128,
            uint256 feeGrowth1X128,
            uint256 blocknumber
        );


    // lender widraw info stored for each individual tick and owner
    struct Withdraws { 
        // token0 amount available
        uint128 amountA;
        // token0 amount available
        uint128 amountB;
    }

    /// @notice Returns the available withdraw amounts
    /// @param tickLower The tick at which the assets are stored
    /// @param owner owner of the position
    /// @return amountA The token0 amount available
    /// @return amountB The token1 amount available
    function withdraws(int24 tickLower, address owner)
        external returns(
            uint128 amountA,
            uint128 amountB
        );

    // borrower position info stored for each individual tick, owner and collateral type
    struct Loan {
        // liquidity amount borrowed
        uint128 liquidityBor;
        // collateral amount deposited in token0 or token1
        uint128 amountCol;
        // interest deposited for borrow position
        uint128 interest;
        // last interest adjustment timestamp
        uint256 start;
    }

    /// @notice Returns the borrow positions
    /// @dev The key is determined as the hash of address owner, int24 tickBor and bool token0
    /// @param key The identifier for the borrow position
    /// @return liquidityBor The liquidity amount borrowed
    /// @return amountCol The collateral amount deposited in token0 or token1
    /// @return interest The interest deposited
    /// @return start The last interest adjustment timestamp
    function borrower(bytes32 key)
        external returns(
            uint128 liquidityBor,
            uint128 amountCol,
            uint128 interest,
            uint256 start
        );

    // input params for constructor
    struct CreateParams { 
        // Uniswap v3 factory address
        address factory;
        // first of the two tokens of the pool, sorted by address
        address tokenA; 
        // second of the two tokens of the pool, sorted by address
        address tokenB; 
        // Uniswap v3 tick spacing assiciated with the underlying Uniswap v3 pool
        int24 tickSpacing; 
        // Uniswap v3 fee assiciated with the underlying Uniswap v3 pool
        uint24 fee; 
        // multiplier used for kommodo fee, multiplies the underlying Uniswap v3 pool fee
        uint24 multiplier;  
    } 

    // input params for providing to lender position
    struct ProvideParams { 
        // tick at which to provide the liquidity
        int24 tickLower; 
        // liquidity amount to provide
        uint128 liquidity;
        // maximum token0 amount for liquidity to deposit
        uint128 amountMaxA; 
        // maximum token1 amount for liquidity to deposit
        uint128 amountMaxB;   
    } 

    /// @notice Adds liquidity for the position of msg.sender at tick
    /// @dev Deposits can only be withdrawn the next block (locked) to protect against flash loan risks
    /// @param params ProvideParams tick/liquidity/amountMaxA/amountMaxB 
    function provide(ProvideParams calldata params) external;

    // input params for taking from lender position
    struct TakeParams { 
        // lower tick of the position
        int24 tickLower;
        // liquidity amount to remove
        uint128 liquidity; 
        // minimum token0 amount for liquidity to receive
        uint128 amountMinA; 
        // minimum token1 amount for liquidity to receive
        uint128 amountMinB;   
    } 

    /// @notice Remove liquidity for the position of msg.sender at tick
    /// @dev Liquidity can only be withdrawn when unlocked to protect against flash loan risks.
    /// @dev Asset removal requires two steps first take then withdraw. These can be performed in the same txt.
    /// @param params TakeParams tick/liquidity/amountMinA/amountMinB 
    /// @return amountA The assetA amount removed for the liquidity
    /// @return amountB The assetB amount removed for the liquidity
    function take(TakeParams calldata params) external returns(uint256 amountA, uint256 amountB);

    /// @notice Withdraw liquidity for the position of msg.sender at tick 
    /// @dev Split between withdraw and take to allow fee accumulation in these withdraw amounts.
    /// @dev Withdraw must be called by the position owner.
    /// @param tickLower The lower tick of the position to witdraw from
    /// @param recipient The address to receive the witdrawn funds
    /// @param amount0Requested The maximum token0 amount to withdraw when available
    /// @param amount1Requested The maximum token1 amount to withdraw when available
    function withdraw( 
        int24 tickLower,
        address recipient, 
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external;

    // input params for opening a borrow position
    struct OpenParams { 
        // bool value indicating use of collateral token0 or token1
        bool token0;
        // tick at which to borrow
        int24 tickBor; 
        // liquidity amount to borrow
        uint128 liquidityBor;
        // minimum token0 amount to receive for borrow liquidity
        uint128 borAMin;
        // minimum token1 amount to receive for borrow liquidity
        uint128 borBMin; 
        // collateral amount to deposit in collateral token
        uint128 colAmount; 
        // interest amount to deposit in borrow position
        int128 interest; 
    } 

    /// @notice Borrow liquidity for msg.sender at tick
    /// @dev No checks on effective (minimal) collateral. User can deposit more then required collateral.
    /// @dev Can be used to open a new position or increase the borrow amount and/or collateral amount.
    /// @param params OpenParams token0/tickBor/liquidityBor/borAMin/borBMin/colAmount/interest
    function open(OpenParams calldata params) external;

    // input params for adjusting an existing borrow position
    struct AdjustParams {
        // bool value indicating use of collateral token0 or token1
        bool token0;
        // tick at which borrowed
        int24 tickBor; 
        // liquidity amount to return
        uint128 liquidityBor;
        // maximum token0 amount to deposit for returned borrow liquidity
        uint128 borAMax;
        // maximum token1 amount to deposit for returned borrow liquidity
        uint128 borBMax; 
        // collateral amount to withdraw in collateral token
        uint128 amountCol;
        // positive or negative interest adjustment
        int128 interest; 
    } 

    /// @notice Adjust borrow position for msg.sender at tick
    /// @dev Can be used to decrease the borrow amount and/or collateral amount.
    /// @param params AdjustParams token0/tickBor/liquidityBor/borAMax/borBMax/amountCol/interest
    function adjust(AdjustParams calldata params) external;

    // input params for closing an existing borrow position
    struct CloseParams {
        // bool value indicating use of collateral token0 or token1
        bool token0;
        // owner of the borrow position
        address owner;  
        // tick at which borrowed
        int24 tickBor;
        // maximum token0 amount to deposit for returned borrow liquidity
        uint128 borAMax;
        // maximum token1 amount to deposit for returned borrow liquidity
        uint128 borBMax;  
    } 

    /// @notice Close borrow position for owner at tick
    /// @dev Can be used to fully close the borrow position.
    /// @dev Active (sufficient interest) loans can only be closed by the owner. Inactive loans can be closed by anyone.
    /// @param params CloseParams token0/owner/tickBor/borAMax/borBMax
    function close(CloseParams calldata params) external;

    /// @notice Adjust interest deposit for borrow position
    /// @dev No minimum interest requirement. Only requires new interest amount is sufficient for already used interest.
    /// @param token0 bool value indicating use of collateral token0 or token1 for borrow position
    /// @param tickBor tick at which borrowed
    /// @param delta interest adjustment amount
    function setInterest(bool token0, int24 tickBor, int128 delta) external;

    /// @notice Checks the solvency requirement
    /// @dev Checks that the collateral amount is more then or equal to the borrow amount based on liquidity and collateral type.
    /// @dev Uses a positive collateral margin (based on fee percentage) in the check. This margin is used a incentive for other
    /// users to close inactive loans. 
    /// @param token0 bool value indicating use of collateral token0 or token1
    /// @param tickBor tick at which borrowed
    /// @param liquidity total liquidity borrowed
    /// @param col total collateral amount provided
    /// @return success The bool indicating a succesfull solvency check
    function checkRequirement(bool token0, int24 tickBor, int128 liquidity, uint128 col) external view returns(bool success);

    /// @notice Returns the start fee amount for the borrowed assets
    /// @dev Opening a position requires a start fee, interest and margin.
    /// @param amount The liquidity amount borrowed
    /// @return uint256 The start fee = liquidity * start fee
    function getFee(uint256 amount) external view returns(uint256);
    
    /// @notice Returns the used interest amount for the liquidity borrowed during the provided period
    /// @param amount The liquidity amount borrowed 
    /// @param start The start of the period
    /// @param end The end of the period
    /// @return uint256 The interest = amount * year rate * seconds used / 31536000 
    function getInterest(uint256 amount, uint256 start, uint256 end) external view returns(uint256);

    /// @notice Returns the end timestampd for the borrowed position 
    /// @param owner The address that owns the position
    /// @param tickBor The tick of the borrow position
    /// @param token0 The bool value indicating use of collateral token0 or token1
    /// @return uint256 The end unix time = start + (interest provided * 31536000 / amount * year rate)
    function getLoanEnd(address owner, int24 tickBor, bool token0) external view returns(uint256);

    /// @notice Returns the key identifier for a borrow position
    /// @param owner The address that owns the position
    /// @param tickBor The tick of the borrow position
    /// @param token0 The bool value indicating use of collateral token0 or token1
    /// @return bytes32 The hash of the input params
    function getKey(address owner, int24 tickBor, bool token0) external pure returns(bytes32);
}