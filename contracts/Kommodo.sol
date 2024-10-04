// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.19;

import './libraries/SqrtPriceMath.sol';
import './libraries/SafeCast.sol';
import './interfaces/IKommodo.sol';
import './Connector.sol';

/**
* @dev Kommodo - permissionless lending protocol                            
*/
contract Kommodo is IKommodo, Connector {
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeCast for int256;

    struct Liquidity { 
        uint128 liquidity;
        uint128 shares;
        uint128 locked;
    } 

    struct Withdraws { 
        uint128 amountA;
        uint128 amountB;
        uint256 timestamp;
    }

    struct Borrower { 
        uint128 liquidityBor;
        uint128 liquidityCol;
        uint128 interest;
        uint128 fee;
        uint256 start;
        uint128 used;
    }

    //AMM pool variables
    address public tokenA;                                           
    address public tokenB;
    uint24 public poolFee;
    int24 public poolSpacing;
    
    //Lending variables
    uint128 constant BASE = 1e6;
    uint128 public fee;
    uint128 public interest;
    uint128 public margin;
    //Length = total tickspace AMM
    uint256[1774544] public availableLiquidity;

    //Lender mappings
    mapping(int24 => Liquidity) public liquidity;
    mapping(int24 => mapping(address => uint128)) public lender;
    mapping(int24 => mapping(address => Withdraws)) public withdraws;
    //Borrower mappings
    mapping(int24 => uint128) public collateral;
    mapping(bytes32 => Borrower) public borrower;

    constructor(address _factory, address _tokenA, address _tokenB, int24 _poolSpacing, uint24 _poolFee, uint128 _fee, uint128 _interest, uint128 _margin){
        initialize(_factory);
        tokenA = _tokenA;
        tokenB = _tokenB;
        poolFee = _poolFee;
        poolSpacing = _poolSpacing;
        fee = _fee;
        interest = _interest;
        margin = _margin;
    }

    // Lend functions
    function provide(int24 tickLower, uint128 amountA, uint128 amountB) public {
        //Add liquidity to pool
        (uint128 amount, , , ) = addLiquidity(tokenA, tokenB, poolFee, tickLower, tickLower + poolSpacing, amountA, amountB);                                     
        uint128 share = liquidity[tickLower].shares == 0 ? amount : amount / (liquidity[tickLower].liquidity / liquidity[tickLower].shares);           
        require(share > 0, "provide: insufficient share");        
        //Store lender position
        lender[tickLower][msg.sender] += share;
        liquidity[tickLower].liquidity += amount; 
        liquidity[tickLower].shares += share;
        availableLiquidity[uint24(tickLower + 887272)] += amount;     
        emit Provide(msg.sender, tickLower, amount, share, amountA, amountB);       
    }

    function take(int24 tickLower, address receiver, uint128 share, uint128 amountMinA, uint128 amountMinB) public {                  
        //Remove liquidity from pool
        uint128 amount = liquidity[tickLower].liquidity / liquidity[tickLower].shares * share;
        (uint256 amountA, uint256 amountB, ) = removeLiquidity(tokenA, tokenB, poolFee, tickLower, tickLower + poolSpacing, amount);
        require(amountA >= amountMinA && amountB >= amountMinB, "take: insufficient amount");
        require(liquidity[tickLower].liquidity - liquidity[tickLower].locked >= amount, "take: insufficient liquidity");
        //Store lender position
        lender[tickLower][msg.sender] -= share;  
        liquidity[tickLower].liquidity -= amount;  
        liquidity[tickLower].shares -= share; 
        availableLiquidity[uint24(tickLower + 887272)] -= amount;
        //Store withdraw 
        withdraws[tickLower][receiver].timestamp = block.timestamp;
        withdraws[tickLower][receiver].amountA += amountA.toUint128();
        withdraws[tickLower][receiver].amountB += amountB.toUint128();
        emit Take(msg.sender, receiver, tickLower, amount, share, amountA, amountB);
    }

    function withdraw(int24 tickLower) public {
        require(withdraws[tickLower][msg.sender].timestamp != 0, "withdraw: no withdraw");
        require(withdraws[tickLower][msg.sender].timestamp < block.timestamp, "withdraw: pending");
        uint128 withdrawA = withdraws[tickLower][msg.sender].amountA;
        uint128 withdrawB = withdraws[tickLower][msg.sender].amountB;
        //Remove withdraw position
        delete withdraws[tickLower][msg.sender];
        //Withdraw amounts
        collectLiquidity(tokenA, tokenB, poolFee, tickLower, tickLower + poolSpacing, withdrawA, withdrawB);  
        emit Withdraw(msg.sender, tickLower, withdrawA, withdrawB);
    }

    //Borrow functions
    function open(OpenParams calldata params) public {             
        //Get loan position and check
        Borrower storage loan = borrower[getKey(msg.sender, params.tickLowerBor, params.tickLowerCol)];
        uint128 _fee = getFee(params.liquidityBor).toUint128();
        uint256 used = getInterest(params.tickLowerBor, params.tickLowerCol, loan.liquidityBor, loan.start, block.timestamp) + loan.used;    
        require(params.tickLowerBor != params.tickLowerCol, "open: tick borrow is tick collateral");
        require(liquidity[params.tickLowerBor].liquidity - liquidity[params.tickLowerBor].locked >= params.liquidityBor, "open: insufficient liquidity ");
        require(_fee > 0, "open: no zero fee");         
        require(loan.interest >= used, "open: unclosed loan");  
        //Deposit collateral and store loan position    
        (uint128 liquidityCol, , , ) = addLiquidity(tokenA, tokenB, poolFee, params.tickLowerCol, params.tickLowerCol + poolSpacing, params.colA, params.colB); 
        loan.fee += _fee;
        loan.start = block.timestamp;
        loan.used = used.toUint128(); 
        loan.interest += params.interest;
        loan.liquidityBor += params.liquidityBor;
        loan.liquidityCol += liquidityCol;
        collateral[params.tickLowerCol] += liquidityCol;    
        liquidity[params.tickLowerBor].locked += params.liquidityBor;         
        availableLiquidity[uint24(params.tickLowerBor + 887272)] -= params.liquidityBor; 
        //Check solvency requirement
        uint128 totalBorrow = loan.liquidityBor + loan.interest + loan.fee;
        bool success = checkRequirement(params.tickLowerBor, params.tickLowerCol, totalBorrow.toInt128(), loan.liquidityCol.toInt128());
        require(success, "open: insufficient collateral for borrow");  
        //Withdraw borrowed amount
        (uint256 amountA, uint256 amountB, ) = removeLiquidity(tokenA, tokenB, poolFee, params.tickLowerBor, params.tickLowerBor + poolSpacing, params.liquidityBor);
        require(amountA >= params.borAMin && amountB >= params.borBMin, "open: insufficient amounts");
        collectLiquidity(tokenA, tokenB, poolFee, params.tickLowerBor, params.tickLowerBor + poolSpacing, amountA.toUint128(), amountB.toUint128());  
        emit Open(msg.sender, params.tickLowerCol, params.tickLowerBor, liquidityCol, params.liquidityBor, amountA, amountB);
    }

    function close(CloseParams calldata params) public {
        //Get loan position
        Borrower memory loan = borrower[getKey(params.owner, params.tickLowerBor, params.tickLowerCol)];
        require(loan.start != 0, "close: no open loan"); 
        //Deposit borrowed amount and store loan position
        uint128 liquidityBor = loan.liquidityBor == params.liquidityBor && loan.liquidityCol == params.liquidityCol ? fullClose(params) : partialClose(params);
        availableLiquidity[uint24(params.tickLowerBor + 887272)] += liquidityBor;  
        addLiquidity(tokenA, tokenB, poolFee, params.tickLowerBor, params.tickLowerBor + poolSpacing, liquidityBor); 
        //Withdraw collateral amount
        collateral[params.tickLowerCol] -= params.liquidityCol; 
        (uint256 amountA, uint256 amountB, ) = removeLiquidity(tokenA, tokenB, poolFee, params.tickLowerCol, params.tickLowerCol + poolSpacing, params.liquidityCol);
        collectLiquidity(tokenA, tokenB, poolFee, params.tickLowerCol, params.tickLowerCol + poolSpacing, amountA.toUint128(), amountB.toUint128());  
        emit Close(msg.sender, params.owner, params.tickLowerCol, params.tickLowerBor, params.liquidityCol, liquidityBor, amountA, amountB);
    }

    function fullClose(CloseParams calldata params) internal returns(uint128 liquidityBor) {
        //Get loan position and check interest
        Borrower storage loan = borrower[getKey(params.owner, params.tickLowerBor, params.tickLowerCol)];
        uint256 used = getInterest(params.tickLowerBor, params.tickLowerCol, loan.liquidityBor, loan.start, block.timestamp) + loan.used;
        require(params.owner == msg.sender || loan.interest < used, "close: not authorized");
        //Update loan position
        uint128 cost = used.toUint128() > loan.interest ? loan.interest + loan.fee : used.toUint128() + loan.fee;
        liquidity[params.tickLowerBor].locked -= params.liquidityBor; 
        liquidity[params.tickLowerBor].liquidity += cost; 
        liquidityBor = loan.liquidityBor + cost;
        delete borrower[getKey(params.owner, params.tickLowerBor, params.tickLowerCol)]; 
        emit FullClose(params.owner, params.tickLowerCol, params.tickLowerBor);
    }

    function partialClose(CloseParams calldata params) internal returns(uint128 liquidityBor) {
        //Get loan position and check interes
        Borrower storage loan = borrower[getKey(params.owner, params.tickLowerBor, params.tickLowerCol)];
        uint256 used = getInterest(params.tickLowerBor, params.tickLowerCol, loan.liquidityBor, loan.start, block.timestamp) + loan.used;
        require(params.owner == msg.sender || loan.interest < used, "close: not authorized");
        require(loan.interest > used, "close: insufficient liquidity for fee and interest"); 
        //Update loan position
        loan.start = block.timestamp;
        loan.used = used.toUint128();
        loan.interest -= params.interest; 
        loan.liquidityBor -= params.liquidityBor;
        loan.liquidityCol -= params.liquidityCol;
        liquidity[params.tickLowerBor].locked -= params.liquidityBor; 
        liquidityBor = params.liquidityBor;
        //check solvency requirement
        uint128 totalBorrow = loan.liquidityBor + loan.interest + loan.fee;        
        bool success = checkRequirement(params.tickLowerBor, params.tickLowerCol, totalBorrow.toInt128(), loan.liquidityCol.toInt128()); 
        require(success, "open: insufficient collateral for borrow"); 
        emit PartialClose(params.owner, params.tickLowerCol, params.tickLowerBor);
    }
    
    //View functions
    function checkRequirement(int24 tickBor, int24 tickCol, int128 amountBor, int128 amountCol) public view returns(bool success) {
        int256 bor0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickBor),
                TickMath.getSqrtRatioAtTick(tickBor + poolSpacing),  
                amountBor
        ); 
        int256 bor1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickBor),
                TickMath.getSqrtRatioAtTick(tickBor + poolSpacing),  
                amountBor
        );
        int256 col0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickCol),
                TickMath.getSqrtRatioAtTick(tickCol + poolSpacing),  
                amountCol
        ); 
        int256 col1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickCol),
                TickMath.getSqrtRatioAtTick(tickCol + poolSpacing),  
                amountCol
        );
        //bor and cor are positive for positve liquidity inputs
        col0 = col0 * (uint256((margin + BASE) / BASE)).toInt256();
        col1 = col1 * (uint256((margin + BASE) / BASE)).toInt256();
        return(bor0 <= col0 && bor1 <= col1); 
    }

    //Fee = liquidity * start fee
    function getFee(uint256 _liquidity) public view returns(uint256 amount){
        amount = _liquidity * fee / BASE;
    }

    //Interest = liquidity * seconds passed * ticks passed * interest per liquidity second tick
    function getInterest(int24 tickBor, int24 tickCol, uint256 _liquidity, uint256 start, uint256 end) public view returns(uint256 amount){
        //Order ticks 
        (int24 tickLow, int24 tickUp) = tickBor > tickCol ? (tickBor, tickCol) : (tickCol, tickBor);
        //Calculate interest and fee
        uint256 deltaTime = (end - start);
        uint24 deltaTick = uint24((tickLow - tickUp) / poolSpacing);
        uint256 deltaInterest = interest * deltaTime * deltaTick;
        amount = _liquidity * deltaInterest / BASE;
    }

    //Loan identification key
    function getKey(address owner, int24 tickLowerBor, int24 tickLowerCol) public pure returns(bytes32 key){
        key = keccak256(abi.encode(owner, tickLowerBor, tickLowerCol));
    }
}




 


