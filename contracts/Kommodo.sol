// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.19;

import './interfaces/IKommodo.sol';
import './Connector.sol';

/**
* @dev Kommodo - permissionless lending protocol                            
*/
contract Kommodo is IKommodo, Connector {
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeCast for int256;

    struct Assets { 
        uint128 liquidity;
        uint128 locked;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
    } 

    struct Lender { 
        uint128 liquidity;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
    } 

    struct Withdraws { 
        uint128 amountA;
        uint128 amountB;
        uint256 timestamp;
    }

    struct Loan {
        bool tokenA; 
        uint128 liquidityBor;
        uint128 amountCol;
        uint128 interest;
        uint128 used;
        uint256 start;
    }

    //AMM pool variables
    address public tokenA;                                           
    address public tokenB;
    uint24 public fee;
    int24 public tickSpacing;
    
    //Lending variables
    uint128 public interest;
    uint256 public delay;
    
    //Lender mappings
    mapping(int24 => Assets) public assets;
    mapping(int24 => mapping(address => Lender)) public lender;
    mapping(int24 => mapping(address => Withdraws)) public withdraws;
    //Borrower mappings
    mapping(bytes32 => Loan) public borrower;

    constructor(CreateParams memory params){
        initialize(params.factory);
        tokenA = params.tokenA;
        tokenB = params.tokenB;
        fee = params.fee;
        tickSpacing = params.tickSpacing;
        interest = params.multiplier * params.fee;
        delay = params.delay;
    }

    // Lend functions
    function provide(ProvideParams calldata params) public {
        //Add liquidity to pool
        (uint128 liquidity, , , ) = addLiquidity(tokenA, tokenB, fee, params.tickLower, params.tickLower + tickSpacing, params.amountA, params.amountB);   
        require(liquidity > 0, "provide: insufficient amount");        
        //Update feegrowth lender
        updateFeeGrowth(params.tickLower);
        updateLenderFee(params.tickLower);
        //Store lender position
        assets[params.tickLower].liquidity += liquidity; 
        lender[params.tickLower][msg.sender].liquidity += liquidity;
        emit Provide(msg.sender, params.tickLower, liquidity, params.amountA, params.amountB);       
    }

    function take(TakeParams calldata params) public {                  
        //Remove liquidity from pool
        (uint256 amountA, uint256 amountB, ) = removeLiquidity(tokenA, tokenB, fee, params.tickLower, params.tickLower + tickSpacing, params.liquidity);
        collectLiquidity(tokenA, tokenB, address(this), fee, params.tickLower, params.tickLower + tickSpacing, amountA.toUint128(), amountB.toUint128());  
        require(amountA >= params.amountMinA && amountB >= params.amountMinB, "take: insufficient amount");
        require(assets[params.tickLower].liquidity - assets[params.tickLower].locked >= params.liquidity, "take: insufficient liquidity");
        //Update feegrowth lender
        updateFeeGrowth(params.tickLower);
        updateLenderFee(params.tickLower);
        //Store lender position
        assets[params.tickLower].liquidity -= params.liquidity;  
        lender[params.tickLower][msg.sender].liquidity -= params.liquidity;
        //Store withdraw 
        withdraws[params.tickLower][msg.sender].timestamp = block.timestamp;
        withdraws[params.tickLower][msg.sender].amountA += amountA.toUint128();
        withdraws[params.tickLower][msg.sender].amountB += amountB.toUint128();
        emit Take(msg.sender, params.tickLower, params.liquidity, amountA, amountB);
    }

    function withdraw(int24 tickLower) public {
        require(withdraws[tickLower][msg.sender].timestamp + delay <= block.timestamp, "withdraw: pending");
        //Update feegrowth lender
        updateFeeGrowth(tickLower);  
        updateLenderFee(tickLower);       
        //Remove withdraw position
        uint128 withdrawA = withdraws[tickLower][msg.sender].amountA;
        uint128 withdrawB = withdraws[tickLower][msg.sender].amountB;
        delete withdraws[tickLower][msg.sender];
        //Withdraw amounts
        TransferHelper.safeTransfer(tokenA, msg.sender, withdrawA);   
        TransferHelper.safeTransfer(tokenB, msg.sender, withdrawB);   
        emit Withdraw(msg.sender, tickLower, withdrawA, withdrawB);
    }

    //Borrow functions
    //Notice: no checks on effective (minimal) collateral
    function open(OpenParams calldata params) public {             
        //Get loan position and check
        bool token0 = params.colA > 0;
        Assets storage asset = assets[params.tickBor];  
        Loan storage loan = borrower[getKey(msg.sender, params.tickBor, token0)];
        uint256 used = getInterest(loan.amountCol, loan.start, block.timestamp) + loan.used;    
        require(loan.interest >= used, "open: unclosed loan"); 
        require(loan.start == 0 || loan.tokenA == token0, "open: other token used");
        require(params.colA == 0 || params.colB == 0, "open: multiple collateral tokens");
        require(asset.liquidity - asset.locked >= params.liquidityBor, "open: insufficient liquidity ");  
        //Deposit collateral
        if(token0){
            TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), params.colA + getFee(params.colA).toUint128() + params.interest);  
        } else {
            TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), params.colB + getFee(params.colB).toUint128() + params.interest);  
        }
        //Store fee payment - notice: overflow is safe for feegrowth
        unchecked{asset.feeGrowth0X128 += FullMath.mulDiv(getFee(params.colA).toUint128(), FixedPoint128.Q128, asset.liquidity);}
        unchecked{asset.feeGrowth1X128 += FullMath.mulDiv(getFee(params.colB).toUint128(), FixedPoint128.Q128, asset.liquidity);}
        require(getFee(params.colA + params.colB).toUint128() > 0, "open: no zero fee");   
        //Store loan position 
        loan.tokenA = token0;
        loan.start = block.timestamp;
        loan.used = used.toUint128(); 
        loan.interest += params.interest;
        loan.liquidityBor += params.liquidityBor;
        loan.amountCol += params.colA + params.colB;
        asset.locked += params.liquidityBor;    
        //Check solvency requirement
        bool success = checkRequirement(token0, params.tickBor, loan.liquidityBor.toInt128(), loan.amountCol, loan.amountCol);
        require(success, "open: insufficient collateral for borrow");          
        //Withdraw borrowed amount
        (uint256 borA, uint256 borB, ) = removeLiquidity(tokenA, tokenB, fee, params.tickBor, params.tickBor + tickSpacing, params.liquidityBor);
        require(borA >= params.borAMin && borB >= params.borBMin, "open: insufficient amounts");
        collectLiquidity(tokenA, tokenB, msg.sender, fee, params.tickBor, params.tickBor + tickSpacing, borA.toUint128(), borB.toUint128());  
        emit Open(token0, msg.sender, params.tickBor, params.liquidityBor, borA, borB, params.colA + params.colB);
    }

    function close(CloseParams calldata params) public {
        //Get loan position and check
        Loan memory loan = borrower[getKey(params.owner, params.tickBor, params.token0)];
        require(loan.start != 0, "close: no open loan");        
        //Deposit borrowed amount and store loan position
        uint128 liquidityBor;
        uint128 unused;
        if(loan.liquidityBor == params.liquidityBor && loan.amountCol == params.amountCol){
            (liquidityBor, unused) = fullClose(params);
        } else {
            (liquidityBor, unused) = partialClose(params);
        }
        (, uint256 borA, uint256 borB, ) = addLiquidity(tokenA, tokenB, fee, params.tickBor, params.tickBor + tickSpacing, liquidityBor); 
        //Withdraw collateral amount
        address token = params.token0 ? tokenA : tokenB;
        TransferHelper.safeTransfer(token, msg.sender, params.amountCol + unused);             
        emit Close(msg.sender, params.token0, params.owner, params.tickBor, liquidityBor, borA, borB, params.amountCol);  
    }

    //Internal functions
    function fullClose(CloseParams calldata params) internal returns(uint128 liquidityBor, uint128 unused) { 
        //Get loan position and check
        Assets storage asset = assets[params.tickBor];  
        Loan storage loan = borrower[getKey(params.owner, params.tickBor, params.token0)];
        uint256 used = getInterest(loan.amountCol, loan.start, block.timestamp) + loan.used;
        uint128 cost = used > loan.interest ? loan.interest : used.toUint128();
        require(params.owner == msg.sender || used > loan.interest, "close: not authorized");
        //Update loan position
        asset.locked -= loan.liquidityBor; 
        liquidityBor = loan.liquidityBor;
        unused = loan.interest - cost;
        delete borrower[getKey(params.owner, params.tickBor, params.token0)]; 
        //Store interest payment - notice: overflow is safe for feegrowth
        if(params.token0){
            unchecked{asset.feeGrowth0X128 += FullMath.mulDiv(cost, FixedPoint128.Q128, asset.liquidity);}
        } else {
            unchecked{asset.feeGrowth1X128 += FullMath.mulDiv(cost, FixedPoint128.Q128, asset.liquidity);}      
        }
        emit FullClose(params.token0, params.owner, params.tickBor);
    }

    function partialClose(CloseParams calldata params) internal returns(uint128 liquidityBor, uint128 unused) {
        //Get loan position and check
        Assets storage asset = assets[params.tickBor];  
        Loan storage loan = borrower[getKey(params.owner, params.tickBor, params.token0)];
        uint256 used = getInterest(loan.amountCol, loan.start, block.timestamp) + loan.used;
        require(params.owner == msg.sender, "close: not authorized");
        require(loan.interest - params.interest >= used, "close: insufficient interest"); 
        //Update loan position
        loan.start = block.timestamp;
        loan.used = used.toUint128();
        loan.interest -= params.interest; 
        loan.liquidityBor -= params.liquidityBor;
        loan.amountCol -= params.amountCol;
        asset.locked -= params.liquidityBor; 
        liquidityBor = params.liquidityBor;
        unused = params.interest;
        //check solvency requirement
        bool success = checkRequirement(params.token0, params.tickBor, loan.liquidityBor.toInt128(), loan.amountCol, loan.amountCol);
        require(success, "open: insufficient collateral for borrow");  
        emit PartialClose(params.token0, params.owner, params.tickBor);
    }

    function updateFeeGrowth(int24 tick) internal {
        Assets storage asset = assets[tick];  
        if (asset.liquidity != 0){    
            (uint128 tokensOwed0, uint128 tokensOwed1) = tokensOwed(tokenA, tokenB, fee, tick, tick + tickSpacing);
            (uint256 collect0, uint256 collect1, ) = collectLiquidity(
                tokenA, tokenB, 
                address(this), 
                fee, 
                tick, 
                tick + tickSpacing, 
                tokensOwed0, 
                tokensOwed1);  
            //Notice: overflow is safe for feegrowth
            unchecked{asset.feeGrowth0X128 += FullMath.mulDiv(collect0, FixedPoint128.Q128, asset.liquidity);}
            unchecked{asset.feeGrowth1X128 += FullMath.mulDiv(collect1, FixedPoint128.Q128, asset.liquidity);}
        }      
    }  
    
    function updateLenderFee(int24 tick) internal {
        Assets storage asset = assets[tick];  
        Lender storage provider = lender[tick][msg.sender];
        uint256 delta0; 
        uint256 delta1;
        //Notice: underflow is safe for feegrowth
        unchecked{delta0 = asset.feeGrowth0X128 - provider.feeGrowth0X128;}
        unchecked{delta1 = asset.feeGrowth1X128 - provider.feeGrowth1X128;}   
        uint128 tokensOwed0 = uint128(FullMath.mulDiv(delta0, provider.liquidity, FixedPoint128.Q128));
        uint128 tokensOwed1 = uint128(FullMath.mulDiv(delta1, provider.liquidity, FixedPoint128.Q128));
        provider.feeGrowth0X128 = asset.feeGrowth0X128;
        provider.feeGrowth1X128 = asset.feeGrowth1X128;
        withdraws[tick][msg.sender].amountA += tokensOwed0;
        withdraws[tick][msg.sender].amountB += tokensOwed1;  
    }   
    
    //View & Pure functions
    function checkRequirement(
        bool token0, 
        int24 tickBor, 
        int128 liquidity, 
        uint128 colA, 
        uint128 colB
    ) public view returns(bool success) {       
        //Notice: bor0 & bor1 are positive because liquidity is positive
        int256 bor0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickBor),
                TickMath.getSqrtRatioAtTick(tickBor + tickSpacing),  
                liquidity
        );  
        int256 bor1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickBor),
                TickMath.getSqrtRatioAtTick(tickBor + tickSpacing),  
                liquidity
        );       
        uint256 col0 = colA * 1e6 / (fee + 1e6);
        uint256 col1 = colB * 1e6 / (fee + 1e6);        
        success = token0 ? col0 >= uint256(bor0) : col1 >= uint256(bor1);
    }

    //Fee = liquidity * start fee
    function getFee(uint256 amount) public view returns(uint256){
        return(FullMath.mulDivRoundingUp(amount, fee, 1e6));
    }

    //Interest = amount * year rate * seconds used / 31536000 
    function getInterest(uint256 amount, uint256 start, uint256 end) public view returns(uint256){
        uint256 deltaTime = end - start;
        uint256 yearly = FullMath.mulDivRoundingUp(amount, interest, 1e6);
        return(FullMath.mulDivRoundingUp(yearly, deltaTime, 31536000));
    }

    //End unix time = start + (interest provided * 31536000 / amount * year rate)
    function getLoanEnd(address owner, int24 tickBor, bool token0) public view returns(uint256){
        Loan storage loan = borrower[getKey(owner, tickBor, token0)];
        uint256 available = loan.interest - loan.used;
        uint256 yearly = FullMath.mulDivRoundingUp(loan.amountCol, interest, 1e6);
        uint256 deltaTime = FullMath.mulDiv(available, 31536000, yearly);
        return(loan.start + deltaTime);
    }

    //Loan identification key
    function getKey(address owner, int24 tickBor, bool token0) public pure returns(bytes32){
        return(keccak256(abi.encode(owner, tickBor, token0)));
    }
}