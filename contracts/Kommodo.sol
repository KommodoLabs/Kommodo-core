// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import '@openzeppelin/contracts/security/ReentrancyGuard.sol'; 

import './interfaces/IKommodo.sol';
import './Connector.sol';

contract Kommodo is IKommodo, Connector, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for uint128;
    using SafeCast for int128;

    /// @inheritdoc IKommodo
    address public override tokenA;   
    /// @inheritdoc IKommodo
    address public override tokenB;
    /// @inheritdoc IKommodo
    uint24 public override fee;
    /// @inheritdoc IKommodo
    int24 public override tickSpacing;

    /// @inheritdoc IKommodo
    uint24 public override rate;
    /// @inheritdoc IKommodo
    mapping(int24 => Assets) public override assets;
    /// @inheritdoc IKommodo
    mapping(int24 => mapping(address => Lender)) public override lender;
    /// @inheritdoc IKommodo
    mapping(int24 => mapping(address => Withdraws)) public override withdraws;
    /// @inheritdoc IKommodo
    mapping(bytes32 => Loan) public override borrower;

    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IKommodo
    function initialize(CreateParams memory params) external initializer {
        require(params.multiplier * params.fee <= 1e6, "initialize: interest overflow");
        __Connector_init(params.factory);
        tokenA = params.tokenA;
        tokenB = params.tokenB;
        fee = params.fee;
        tickSpacing = params.tickSpacing;
        rate = params.multiplier * params.fee;
    }

    // Lend functions
    /// @inheritdoc IKommodo
    function provide(ProvideParams calldata params) public override nonReentrant {
        Lender storage _lender = lender[params.tickLower][msg.sender];
        //Add liquidity to pool
        (, uint256 amountA, uint256 amountB, ) = addLiquidity(tokenA, tokenB, fee, params.tickLower, params.tickLower + tickSpacing, params.liquidity);
        require(amountA <= params.amountMaxA && amountB <= params.amountMaxB, "provide: max amount deposit");
        //Update feegrowth lender
        updateFeeGrowth(params.tickLower);
        updateLenderFee(params.tickLower);
        //Store lender position
        uint128 paused = _lender.paused;
        uint256 blocknumber = _lender.blocknumber;
        assets[params.tickLower].liquidity += params.liquidity; 
        _lender.liquidity += params.liquidity;
        _lender.paused = blocknumber < block.number ? params.liquidity : paused + params.liquidity;
        _lender.blocknumber = block.number;
        emit Provide(msg.sender, params.tickLower, params.liquidity, amountA, amountB);     
    }

    /// @inheritdoc IKommodo
    function take(TakeParams calldata params) public override nonReentrant returns(uint256 amountA, uint256 amountB) {      
        Assets storage _assets = assets[params.tickLower];
        Lender storage _lender = lender[params.tickLower][msg.sender];  
        Withdraws storage _withdraws = withdraws[params.tickLower][msg.sender];
        require(_assets.liquidity - _assets.locked >= params.liquidity, "take: insufficient liquidity");
        //Remove liquidity from pool
        ( amountA, amountB, ) = removeLiquidity(tokenA, tokenB, fee, params.tickLower, params.tickLower + tickSpacing, params.liquidity);  
        collectAmounts(tokenA, tokenB, address(this), fee, params.tickLower, params.tickLower + tickSpacing, amountA.toUint128(), amountB.toUint128()); 
        require(amountA >= params.amountMinA && amountB >= params.amountMinB, "take: insufficient amounts");
        //Update feegrowth
        updateFeeGrowth(params.tickLower);
        updateLenderFee(params.tickLower);
        //Store lender position
        uint128 paused = _lender.paused;
        uint256 blocknumber = _lender.blocknumber;
        _assets.liquidity -= params.liquidity;  
        _lender.liquidity -= params.liquidity;
        _lender.paused = blocknumber < block.number ? 0 : paused;
        _lender.blocknumber = block.number;
        _withdraws.amountA += amountA.toUint128();
        _withdraws.amountB += amountB.toUint128();
        require(_lender.liquidity >= _lender.paused, "take: withdraw locked");
        emit Take(msg.sender, params.tickLower, params.liquidity, amountA, amountB);
    }

    /// @inheritdoc IKommodo
    function withdraw(
        int24 tickLower,
        address recipient, 
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public override nonReentrant {
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
    /// @inheritdoc IKommodo
    function open(OpenParams calldata params) public override nonReentrant {  
        Assets storage _assets = assets[params.tickBor];  
        Loan storage loan = borrower[getKey(msg.sender, params.tickBor, params.token0)];
        uint256 startFee = getFee(params.colAmount).toUint128();
        require(startFee > 0, "open: no zero fee");   
        //Deposit collateral & store fee payment - notice: overflow is safe for feegrowth
        if(params.token0){
            uint256 balanceABefore = IERC20(tokenA).balanceOf(address(this));
            TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), params.colAmount + startFee);  
            uint256 receivedA = IERC20(tokenA).balanceOf(address(this)) - balanceABefore;
            require(receivedA == (params.colAmount + startFee), "open: unsufficient amount");
            unchecked{_assets.feeGrowth0X128 += FullMath.mulDiv(startFee, FixedPoint128.Q128, _assets.liquidity);}
        } else {      
            uint256 balanceBBefore = IERC20(tokenB).balanceOf(address(this));      
            TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), params.colAmount + startFee); 
            uint256 receivedB = IERC20(tokenB).balanceOf(address(this)) - balanceBBefore;
            require(receivedB == (params.colAmount + startFee), "open: unsufficient amount");
            unchecked{_assets.feeGrowth1X128 += FullMath.mulDiv(startFee, FixedPoint128.Q128, _assets.liquidity);} 
        }
        //Interest adjust - checks sufficiency
        storeInterest(params.token0, params.tickBor, params.interest);
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
        collectAmounts(tokenA, tokenB, msg.sender, fee, params.tickBor, params.tickBor + tickSpacing, borA.toUint128(), borB.toUint128());  
        emit Open(params.token0, msg.sender, params.tickBor, params.liquidityBor, params.colAmount, loan.interest, borA, borB);
    }

    /// @inheritdoc IKommodo
    function adjust(AdjustParams calldata params) public override nonReentrant {
        Assets storage _assets = assets[params.tickBor];  
        Loan storage loan = borrower[getKey(msg.sender, params.tickBor, params.token0)];
        require(loan.start != 0, "adjust: no open loan");   
        //Return borrow amount
        uint256 borA;
        uint256 borB;
        if(params.liquidityBor > 0){(, borA, borB, ) = addLiquidity(tokenA, tokenB, fee, params.tickBor, params.tickBor + tickSpacing, params.liquidityBor);}
        require(borA <= params.borAMax && borB <= params.borBMax, "adjust: max amount repay");
        //Interest adjust - checks sufficiency
        storeInterest(params.token0, params.tickBor, params.interest);
        //Update loan position
        _assets.locked -= params.liquidityBor; 
        loan.liquidityBor -= params.liquidityBor;
        loan.amountCol -= params.amountCol;
        //check solvency requirement
        bool success = checkRequirement(params.token0, params.tickBor, loan.liquidityBor.toInt128(), loan.amountCol);
        require(success, "adjust: insufficient collateral for borrow");  
        //Withdraw collateral amount 
        address token = params.token0 ? tokenA : tokenB;
        if(params.amountCol > 0) {TransferHelper.safeTransfer(token, msg.sender, params.amountCol);} 
        emit Adjust(params.token0, msg.sender, params.tickBor, params.liquidityBor, params.amountCol, loan.interest, borA, borB);  
    }

    /// @inheritdoc IKommodo
    function close(CloseParams calldata params) public override nonReentrant {
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
        require(borA <= params.borAMax && borB <= params.borBMax, "close: max amount repay");
        //Withdraw collateral amount to sender and return interest to owner
        address token = params.token0 ? tokenA : tokenB;
        if (unused > 0) {TransferHelper.safeTransfer(token, msg.sender, unused);} 
        TransferHelper.safeTransfer(token, msg.sender, amountCol);
        emit Close(params.token0, msg.sender, params.owner, params.tickBor, liquidityBor, amountCol, borA, borB);  
    }

    /// @inheritdoc IKommodo
    function setInterest(bool token0,  int24 tickBor, int128 delta) public override nonReentrant {
       storeInterest(token0, tickBor, delta);
    }

    /// @inheritdoc IKommodo
    function updateInterest(bool token0,  int24 tickBor, address owner) public override nonReentrant {
        Loan storage loan = borrower[getKey(owner, tickBor, token0)];
        uint256 used = getInterest(loan.amountCol, loan.start, block.timestamp); 
        require(loan.interest >= used, "updateInterest: unclosed loan"); 
        loan.interest = loan.interest - used.toUint128();
        loan.start = block.timestamp;
    }

    /// @dev Internal function to split from public function for nonreentrant modifier.
    /// @param token0 bool value indicating use of collateral token0 or token1 for borrow position
    /// @param tickBor tick at which borrowed
    /// @param delta interest adjustment amount
    function storeInterest(bool token0,  int24 tickBor, int128 delta) internal {
        //Get loan position
        Assets storage _assets = assets[tickBor];  
        Loan storage loan = borrower[getKey(msg.sender, tickBor, token0)];
        uint256 used = getInterest(loan.amountCol, loan.start, block.timestamp);  
        address token = token0 ? tokenA : tokenB;
        //Check interest requirements and deposit positive delta
        require(loan.interest >= used, "storeInterest: unclosed loan"); 
        if(delta > 0){
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));      
            TransferHelper.safeTransferFrom(token, msg.sender, address(this), (delta).toUint128());
            uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
            require(received == ((delta).toUint128()), "storeInterest: unsufficient amount");
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
        emit Interest(token0, msg.sender, tickBor, loan.interest, delta);  
    }


    /// @dev Updates feegrowth for the kommodo pool based on fees earned in the Uniswap v3 pool.
    /// @dev only contains fees because every non zero Uniswap v3 remove call is directly followed by a collect.
    /// @param tick The tick for which the fee is updated
    function updateFeeGrowth(int24 tick) internal {
        Assets storage _assets = assets[tick];  
        if (_assets.liquidity - _assets.locked != 0){    
            (uint128 tokensOwed0, uint128 tokensOwed1) = tokensOwed(tokenA, tokenB, fee, tick, tick + tickSpacing);
            (uint256 collect0, uint256 collect1, ) = collectAmounts(
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

    /// @dev Updates feegrowth for the lender position based on the pools feegrowth
    /// @param tick The tick for which the fee is updated
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
    /// @inheritdoc IKommodo
    function checkRequirement(
        bool token0, 
        int24 tickBor, 
        int128 liquidity, 
        uint128 col
    ) public view override returns(bool success) {       
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
    /// @inheritdoc IKommodo
    function getFee(uint256 amount) public view override returns(uint256){
        return(FullMath.mulDivRoundingUp(amount, fee, 1e6));
    }

    //Interest = amount * year rate * seconds used / 31536000 
    /// @inheritdoc IKommodo
    function getInterest(uint256 amount, uint256 start, uint256 end) public view override returns(uint256){
        uint256 deltaTime = end - start;
        uint256 yearly = FullMath.mulDiv(amount, rate, 1e6);
        return(FullMath.mulDivRoundingUp(yearly, deltaTime, 31536000));
    }

    //End unix time = start + (interest provided * 31536000 / amount * year rate)
    /// @inheritdoc IKommodo
    function getLoanEnd(address owner, int24 tickBor, bool token0) public view override returns(uint256){
        Loan storage loan = borrower[getKey(owner, tickBor, token0)];
        uint256 yearly = FullMath.mulDiv(loan.amountCol, rate, 1e6);
        uint256 deltaTime = yearly == 0 ? 0 : FullMath.mulDiv(loan.interest, 31536000, yearly);
        return(loan.start + deltaTime);
    }

    //Loan identification key
    /// @inheritdoc IKommodo
    function getKey(address owner, int24 tickBor, bool token0) public pure override returns(bytes32){
        return(keccak256(abi.encode(owner, tickBor, token0)));
    }
}