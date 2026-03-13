// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

import './interfaces/IKommodo.sol';
import './Connector.sol';

/**
* @dev Kommodo - permissionless lending protocol                            
*/
contract Kommodo is IKommodo, Connector {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for uint128;
    using SafeCast for int128;

    //AMM pool variables
    address public tokenA;                                           
    address public tokenB;
    uint24 public fee;
    int24 public tickSpacing;
    //Lending variable
    uint24 public interest;
    
    //Lender mappings
    mapping(int24 => Assets) public assets;
    mapping(int24 => mapping(address => Lender)) public lender;
    mapping(int24 => mapping(address => Withdraws)) public withdraws;
    //Borrower mappings
    mapping(bytes32 => Loan) public borrower;

    constructor(CreateParams memory params) {
        require(params.multiplier * params.fee <= 1e6, "create: interest overflow");
        initialize(params.factory);
        tokenA = params.tokenA;
        tokenB = params.tokenB;
        fee = params.fee;
        tickSpacing = params.tickSpacing;
        interest = params.multiplier * params.fee;
    }

    // Lend functions
    function provide(ProvideParams calldata params) public {
        Lender storage _lender = lender[params.tickLower][msg.sender];
        //Add liquidity to pool
        (, uint256 amountA, uint256 amountB, ) = addLiquidity(tokenA, tokenB, fee, params.tickLower, params.tickLower + tickSpacing, params.liquidity);
        require(params.liquidity > 0, "provide: insufficient amount"); 
        require(amountA <= params.amountMaxA && amountB <= params.amountMaxB, "provide: max amount deposit");
        //Update feegrowth lender
        updateFeeGrowth(params.tickLower);
        updateLenderFee(params.tickLower);
        //Store lender position
        uint128 locked = _lender.locked;
        uint256 blocknumber = _lender.blocknumber;
        assets[params.tickLower].liquidity += params.liquidity; 
        _lender.liquidity += params.liquidity;
        _lender.locked = blocknumber < block.number ? params.liquidity : locked + params.liquidity;
        _lender.blocknumber = block.number;
        emit Provide(msg.sender, params.tickLower, params.liquidity, amountA, amountB);     
    }

    function take(TakeParams calldata params) public returns(uint256 amountA, uint256 amountB) {      
        Assets storage _assets = assets[params.tickLower];
        Lender storage _lender = lender[params.tickLower][msg.sender];  
        Withdraws storage _withdraws = withdraws[params.tickLower][msg.sender];
        require(_assets.liquidity - _assets.locked >= params.liquidity, "take: insufficient liquidity");
        //Remove liquidity from pool
        ( amountA, amountB, ) = removeLiquidity(tokenA, tokenB, fee, params.tickLower, params.tickLower + tickSpacing, params.liquidity);  
        collectLiquidity(tokenA, tokenB, address(this), fee, params.tickLower, params.tickLower + tickSpacing, amountA.toUint128(), amountB.toUint128()); 
        require(amountA >= params.amountMinA && amountB >= params.amountMinB, "take: insufficient amounts");
        //Update feegrowth
        updateFeeGrowth(params.tickLower);
        updateLenderFee(params.tickLower);
        //Store lender position
        uint128 locked = _lender.locked;
        uint256 blocknumber = _lender.blocknumber;
        _assets.liquidity -= params.liquidity;  
        _lender.liquidity -= params.liquidity;
        _lender.locked = blocknumber < block.number ? 0 : locked;
        _lender.blocknumber = block.number;
        _withdraws.amountA += amountA.toUint128();
        _withdraws.amountB += amountB.toUint128();
        require(_lender.liquidity >= _lender.locked, "take: withdraw locked");
        emit Take(msg.sender, params.tickLower, params.liquidity, amountA, amountB);
    }

    function withdraw(
        int24 tickLower,
        address recipient, 
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public {
        Assets storage _assets = assets[tickLower];
        Withdraws storage _withdraws = withdraws[tickLower][msg.sender];
        //Update feegrowth 
        if(lender[tickLower][msg.sender].liquidity > 0 && _assets.liquidity - _assets.locked > 0){
            removeLiquidity(tokenA, tokenB, fee, tickLower, tickLower + tickSpacing, 0);
        }
        updateFeeGrowth(tickLower);  
        updateLenderFee(tickLower);       
        //Update withdraw position
        uint128 withdrawA = _withdraws.amountA > amount0Requested ? amount0Requested : _withdraws.amountA;
        uint128 withdrawB = _withdraws.amountB > amount1Requested ? amount1Requested : _withdraws.amountB;
        _withdraws.amountA -= withdrawA;
        _withdraws.amountB -= withdrawB;
        //Withdraw amounts
        if (withdrawA > 0) {TransferHelper.safeTransfer(tokenA, recipient, withdrawA);}   
        if (withdrawB > 0) {TransferHelper.safeTransfer(tokenB, recipient, withdrawB);} 
        emit Withdraw(msg.sender, tickLower, withdrawA, withdrawB);
    }

    //Borrow functions
    //Notice: no checks on effective (minimal) collateral
    function open(OpenParams calldata params) public {  
        Assets storage _assets = assets[params.tickBor];  
        Loan storage loan = borrower[getKey(msg.sender, params.tickBor, params.token0)];
        require(getFee(params.colAmount).toUint128() > 0, "open: no zero fee");   
        //Deposit collateral & store fee payment - notice: overflow is safe for feegrowth
        if(params.token0){
            uint256 balanceABefore = IERC20(tokenA).balanceOf(address(this));
            TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), params.colAmount + getFee(params.colAmount).toUint128());  
            uint256 receivedA = IERC20(tokenA).balanceOf(address(this)) - balanceABefore;
            require(receivedA == (params.colAmount + getFee(params.colAmount).toUint128()), "open: unsufficient amount");
            unchecked{_assets.feeGrowth0X128 += FullMath.mulDiv(getFee(params.colAmount).toUint128(), FixedPoint128.Q128, _assets.liquidity);}
        } else {      
            uint256 balanceBBefore = IERC20(tokenB).balanceOf(address(this));      
            TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), params.colAmount + getFee(params.colAmount).toUint128()); 
            uint256 receivedB = IERC20(tokenB).balanceOf(address(this)) - balanceBBefore;
            require(receivedB == (params.colAmount + getFee(params.colAmount).toUint128()), "open: unsufficient amount");
            unchecked{_assets.feeGrowth1X128 += FullMath.mulDiv(getFee(params.colAmount).toUint128(), FixedPoint128.Q128, _assets.liquidity);} 
        }
        //Interest adjust - checks sufficiency
        setInterest(params.token0, params.tickBor, params.interest);
        //Store loan position 
        require(_assets.liquidity - _assets.locked >= params.liquidityBor, "open: insufficient liquidity");
        _assets.locked += params.liquidityBor;    
        loan.liquidityBor += params.liquidityBor;
        loan.amountCol += params.colAmount;
        //Check solvency requirement
        bool success = checkRequirement(params.token0, params.tickBor, loan.liquidityBor.toInt128(), loan.amountCol);
        require(success, "open: insufficient collateral for borrow");          
        //Withdraw borrowed amount
        (uint256 borA, uint256 borB, ) = removeLiquidity(tokenA, tokenB, fee, params.tickBor, params.tickBor + tickSpacing, params.liquidityBor);
        require(borA >= params.borAMin && borB >= params.borBMin, "open: insufficient amounts");
        collectLiquidity(tokenA, tokenB, msg.sender, fee, params.tickBor, params.tickBor + tickSpacing, borA.toUint128(), borB.toUint128());  
        emit Open(params.token0, msg.sender, params.tickBor, params.liquidityBor, params.colAmount, loan.interest, borA, borB);
    }

    function adjust(AdjustParams calldata params) public {
        Assets storage _assets = assets[params.tickBor];  
        Loan storage loan = borrower[getKey(msg.sender, params.tickBor, params.token0)];
        require(loan.start != 0, "adjust: no open loan");   
        //Return borrow amount
        uint256 borA;
        uint256 borB;
        if(params.liquidityBor > 0){(, borA, borB, ) = addLiquidity(tokenA, tokenB, fee, params.tickBor, params.tickBor + tickSpacing, params.liquidityBor);}
        require(borA <= params.borAMax && borB <= params.borBMax, "adjust: max amount repay");
        //Interest adjust - checks sufficiency
        setInterest(params.token0, params.tickBor, params.interest);
        //Update loan position
        _assets.locked -= params.liquidityBor; 
        loan.liquidityBor -= params.liquidityBor;
        loan.amountCol -= params.amountCol;
        //check solvency requirement
        bool success = checkRequirement(params.token0, params.tickBor, loan.liquidityBor.toInt128(), loan.amountCol);
        require(success, "open: insufficient collateral for borrow");  
        //Withdraw collateral amount 
        address token = params.token0 ? tokenA : tokenB;
        TransferHelper.safeTransfer(token, msg.sender, params.amountCol); 
        emit Adjust(params.token0, msg.sender, params.tickBor, params.liquidityBor, params.amountCol, loan.interest, borA, borB);  
    }

    function close(CloseParams calldata params) public {
        Assets storage _assets = assets[params.tickBor];  
        Loan storage loan = borrower[getKey(params.owner, params.tickBor, params.token0)];
        //Check loan position 
        uint256 used = getInterest(loan.amountCol, loan.start, block.timestamp);
        uint128 cost = used > loan.interest ? loan.interest : used.toUint128();
        require(loan.start != 0, "close: no open loan");             
        require(params.owner == msg.sender || used > loan.interest, "close: not authorized");      
        //Update loan position
        uint128 liquidityBor = loan.liquidityBor;
        uint128 amountCol = loan.amountCol;
        uint128 unused = loan.interest - cost;
        _assets.locked -= loan.liquidityBor; 
        delete borrower[getKey(params.owner, params.tickBor, params.token0)]; 
        //Store interest payment - notice: overflow is safe for feegrowth
        if(params.token0){unchecked{_assets.feeGrowth0X128 += FullMath.mulDiv(cost, FixedPoint128.Q128, _assets.liquidity);}} 
        else { unchecked{_assets.feeGrowth1X128 += FullMath.mulDiv(cost, FixedPoint128.Q128, _assets.liquidity);}}
        //Return borrow amount
        uint256 borA;
        uint256 borB;
        if(liquidityBor > 0){(, borA, borB, ) = addLiquidity(tokenA, tokenB, fee, params.tickBor, params.tickBor + tickSpacing, liquidityBor);}
        require(borA <= params.borAMax && borB <= params.borBMax, "adjust: max amount repay");
        //Withdraw collateral amount to sender and return interest to owner
        address token = params.token0 ? tokenA : tokenB;
        if (unused > 0) {TransferHelper.safeTransfer(token, msg.sender, unused);} 
        TransferHelper.safeTransfer(token, msg.sender, amountCol);
        emit Close(params.token0, msg.sender, params.owner, params.tickBor, liquidityBor, amountCol, borA, borB);  
    }

    function setInterest(bool token0,  int24 tickBor, int128 delta) public {
        //Get loan position
        Assets storage _assets = assets[tickBor];  
        Loan storage loan = borrower[getKey(msg.sender, tickBor, token0)];
        uint256 used = getInterest(loan.amountCol, loan.start, block.timestamp);  
        address token = token0 ? tokenA : tokenB;
        //Check interest requirements and deposit positive delta
        require(loan.interest >= used, "open: unclosed loan"); 
        if(delta > 0){
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));      
            TransferHelper.safeTransferFrom(token, msg.sender, address(this), (delta).toUint128());
            uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
            require(received == ((delta).toUint128()), "open: unsufficient amount");
        }
        loan.interest = delta > 0 ? loan.interest + delta.toUint128() - used.toUint128() : loan.interest - (-delta).toUint128() - used.toUint128();
        loan.start = block.timestamp;
        //Store used interest - notice: overflow is safe for feegrowth
        if(token0){
            unchecked{_assets.feeGrowth0X128 += FullMath.mulDiv(used.toUint128(), FixedPoint128.Q128, _assets.liquidity);}
        } else {
            unchecked{_assets.feeGrowth1X128 += FullMath.mulDiv(used.toUint128(), FixedPoint128.Q128, _assets.liquidity);} 
        }
        //Return interest for negative delta
        if (delta < 0){TransferHelper.safeTransfer(token, msg.sender, (-delta).toUint128());}
    }

    function updateFeeGrowth(int24 tick) internal {
        Assets storage _assets = assets[tick];  
        if (_assets.liquidity - _assets.locked != 0){    
            (uint128 tokensOwed0, uint128 tokensOwed1) = tokensOwed(tokenA, tokenB, fee, tick, tick + tickSpacing);
            (uint256 collect0, uint256 collect1, ) = collectLiquidity(
                tokenA, 
                tokenB, 
                address(this), 
                fee, 
                tick, 
                tick + tickSpacing, 
                tokensOwed0, 
                tokensOwed1);  
            //Notice: overflow is safe for feegrowth
            unchecked{_assets.feeGrowth0X128 += FullMath.mulDiv(collect0, FixedPoint128.Q128, _assets.liquidity);}
            unchecked{_assets.feeGrowth1X128 += FullMath.mulDiv(collect1, FixedPoint128.Q128, _assets.liquidity);}
        }      
    }  
    
    function updateLenderFee(int24 tick) internal {
        Assets storage _assets = assets[tick];  
        Lender storage _provider = lender[tick][msg.sender];
        Withdraws storage _withdraws = withdraws[tick][msg.sender];
        uint256 delta0; 
        uint256 delta1;
        //Notice: underflow is safe for feegrowth
        unchecked{delta0 = _assets.feeGrowth0X128 - _provider.feeGrowth0X128;}
        unchecked{delta1 = _assets.feeGrowth1X128 - _provider.feeGrowth1X128;}   
        uint128 tokensOwed0 = uint128(FullMath.mulDiv(delta0, _provider.liquidity, FixedPoint128.Q128));
        uint128 tokensOwed1 = uint128(FullMath.mulDiv(delta1, _provider.liquidity, FixedPoint128.Q128));
        _provider.feeGrowth0X128 = _assets.feeGrowth0X128;
        _provider.feeGrowth1X128 = _assets.feeGrowth1X128;
        _withdraws.amountA += tokensOwed0;
        _withdraws.amountB += tokensOwed1;  
    }   
    
    //View & Pure functions
    function checkRequirement(
        bool token0, 
        int24 tickBor, 
        int128 liquidity, 
        uint128 col
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
        //Fee percentage doubles as safety margin - repayed to closer of position
        uint256 col0 = col * 1e6 / (fee + 1e6);
        uint256 col1 = col * 1e6 / (fee + 1e6);    
        require(bor0 > 0 || bor1 > 0, "checkRequirement: no borrow position");    
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
        uint256 yearly = FullMath.mulDivRoundingUp(loan.amountCol, interest, 1e6);
        uint256 deltaTime = FullMath.mulDiv(loan.interest, 31536000, yearly);
        return(loan.start + deltaTime);
    }

    //Loan identification key
    function getKey(address owner, int24 tickBor, bool token0) public pure returns(bytes32){
        return(keccak256(abi.encode(owner, tickBor, token0)));
    }
}