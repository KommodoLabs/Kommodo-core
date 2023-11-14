// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.19;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-periphery/contracts/libraries/PositionKey.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';

import './libraries/SqrtPriceMath.sol';
import './libraries/TickMath.sol';
import './libraries/SafeCast.sol';
import './interfaces/INonfungiblePositionManager.sol';

/**
* @dev Kommodo - permissionless lending protocol                            
*/
contract Kommodo {
    using SafeCast for uint256;
    using SafeCast for uint128;
    using SafeCast for int256;

    struct Liquidity { 
        uint256 liquidityId;
        uint128 liquidity;
        uint128 locked;
        uint128 shares;
        uint256 feeGrowthLocal0LastX128;
        uint256 feeGrowthLocal1LastX128;   
    } 

    struct Collateral { 
        uint256 collateralId;
        uint128 amount;
    }

    struct Lender {
        uint128 share;
        uint256 feeGrowthLocal0LastX128;
        uint256 feeGrowthLocal1LastX128;
    }

    struct Borrower { 
        int24 tick;
        uint128 liquidity;
        uint128 liquidityCol;
        uint128 interest;
        uint256 start;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    struct Withdraw { 
        uint128 amountA;
        uint128 amountB;
        uint256 timestamp;
    }

    uint128 constant BASE_FEE = 10000;
    uint128 constant BASE_INTEREST = 10e12;
    int256 constant BASE_MARGIN = 10000;
    
    address public tokenA;                                           
    address public tokenB;
    address public manager;
    address public pool;
    int24 public tickDelta;
    uint24 public poolFee; 

    bool public initialized;
    uint128 public fee;
    uint128 public interest;
    int256 public margin;
    //Length is total tickspace 
    uint256[1774544] public availableLiquidity;

    mapping(int24 => Liquidity) public liquidity;
    mapping(int24 => Collateral) public collateral;
    mapping(int24 => mapping(address => Lender)) public lender;
    mapping(int24 => mapping(address => Borrower)) public borrower;
    mapping(int24 => mapping(address => Withdraw)) public withdraws;
    mapping(int24 => uint256[2]) public feeGrowth;

    constructor(address _manager, address _tokenA, address _tokenB, uint24 _poolFee, uint128 _fee, uint128 _interest, int256 _margin) {
        require(initialized == false, "initialize: already initialized");
        initialized = true;
        //Store tokens
        tokenA = _tokenA;
        tokenB = _tokenB;
        //Store AMM data
        poolFee = _poolFee;
        manager = _manager;
        IUniswapV3Factory factory = IUniswapV3Factory(INonfungiblePositionManager(manager).factory());
        pool = factory.getPool(_tokenA, _tokenB, _poolFee);
        require(pool != address(0), "initialize: no existing pool");
        //Store lending pool data
        tickDelta = IUniswapV3Pool(pool).tickSpacing();
        fee = _fee;
        margin = _margin;
        interest = _interest;
    }

    // Lend functions
    function provide(int24 tickLower, uint128 amountA, uint128 amountB) public {
        //Get lender position
        Lender storage param = lender[tickLower][msg.sender];
        Liquidity storage tickLiquidity = liquidity[tickLower];
        //Transfer funds and approve manager
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), amountA); 
        TransferHelper.safeApprove(tokenA, manager, amountA); 
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), amountB); 
        TransferHelper.safeApprove(tokenB, manager, amountB); 
        //Add liquidity to pool     
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLower, tickLiquidity.liquidityId, amountA, amountB);
        //Update pool feegrowth liquidty
        updateLiquidityPoolFee(tickLower);
        //Withdraw poolFee liquidity
        if(param.share != 0){
            uint256 liquidity_ = tickLiquidity.liquidity / tickLiquidity.shares * param.share;
            collectFee(tickLower, liquidity_, tickLiquidity.feeGrowthLocal0LastX128, tickLiquidity.feeGrowthLocal0LastX128, param.feeGrowthLocal0LastX128,  param.feeGrowthLocal1LastX128);
        }
        //Store individual position
        uint128 share = tickLiquidity.shares == 0 ? _liquidity : tickLiquidity.liquidity / tickLiquidity.shares * _liquidity;
        require(share > 0, "provide: insufficient share");
        param.share += share;
        param.feeGrowthLocal0LastX128 = tickLiquidity.feeGrowthLocal0LastX128;
        param.feeGrowthLocal1LastX128 = tickLiquidity.feeGrowthLocal1LastX128;
        //Store global liquidity data
        tickLiquidity.liquidityId = _id;
        tickLiquidity.liquidity += _liquidity; 
        tickLiquidity.shares += share;
        //Adjust available liquidity
        availableLiquidity[uint24(tickLower + 887272)] += _liquidity;     
    }

    function take(int24 tickLower, address receiver, uint128 share, uint128 amountMin0, uint128 amountMin1) public {                  
        //Get lender position
        Lender storage param = lender[tickLower][msg.sender];
        Liquidity storage _liquidity = liquidity[tickLower];
        //Check sufficient liquidity
        uint128 amount = _liquidity.liquidity / _liquidity.shares * share;
        require(_liquidity.liquidity - _liquidity.locked >= amount, "take: insufficient liquidity");
        //Remove liquidity from pool
        (uint256 amountA, uint256 amountB) = removeLiquidity(_liquidity.liquidityId, amount, amountMin0, amountMin1);
        //Update pool feegrowth liquidty
        updateLiquidityPoolFee(tickLower);
        //Withdraw poolFee liquidity
        if(param.share != 0){
            uint256 liquidity_ = _liquidity.liquidity / _liquidity.shares * param.share;
            collectFee(tickLower, liquidity_, _liquidity.feeGrowthLocal0LastX128, _liquidity.feeGrowthLocal1LastX128, param.feeGrowthLocal0LastX128,  param.feeGrowthLocal1LastX128);
        }
        //Adjust individual positions
        param.share -= share;  
        param.feeGrowthLocal0LastX128 = _liquidity.feeGrowthLocal0LastX128;
        param.feeGrowthLocal1LastX128 = _liquidity.feeGrowthLocal1LastX128;
        //Adjust global position  
        _liquidity.liquidity -= amount;  
        _liquidity.shares -= share; 
        //Adjust available liquidity
        availableLiquidity[uint24(tickLower + 887272)] -= amount;
        //Store withdraw 
        withdraws[tickLower][receiver].timestamp = block.timestamp;
        withdraws[tickLower][receiver].amountA += amountA.toUint128();
        withdraws[tickLower][receiver].amountB += amountB.toUint128();
    }

    function withdraw(int24 tickLower) public {
        require(withdraws[tickLower][msg.sender].timestamp != 0, "withdraw: no withdraw");
        require(withdraws[tickLower][msg.sender].timestamp < block.timestamp, "withdraw: pending");
        uint128 withdrawA = withdraws[tickLower][msg.sender].amountA;
        uint128 withdrawB = withdraws[tickLower][msg.sender].amountB;
        //Remove withdraw position
        delete withdraws[tickLower][msg.sender];
        //Withdraw amounts
        collectLiquidity(liquidity[tickLower].liquidityId, withdrawA, withdrawB, msg.sender);  
    }

    // Borrow functions
    // @dev: open() function allows depositing more collateral than needed
    function open(int24 tickLower, int24 tickLowerCol, uint128 amount, uint128 amountAMin, uint128 amountBMin, uint128 colA, uint128 colB, uint128 _interest) public {
        //Check liquidity available
        require(tickLower != tickLowerCol, "open: false ticks");
        require(liquidity[tickLower].liquidity - liquidity[tickLower].locked >= amount, "open: insufficient funds available");
        //Check minimal interest
        require(amount > BASE_FEE, "open: insufficient liquidity for startingfee");
        require(_interest > amount * fee / BASE_FEE, "open: insufficient interest");
        //Add Collateral to pool                
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), colA); 
        TransferHelper.safeApprove(tokenA, manager, colA);    
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), colB); 
        TransferHelper.safeApprove(tokenB, manager, colB);            
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLowerCol, collateral[tickLowerCol].collateralId, colA, colB);
        //Store global position
        collateral[tickLowerCol].collateralId = _id;
        collateral[tickLowerCol].amount += _liquidity;         
        //Store individual position including collateral poolfee data
        require(borrower[tickLowerCol][msg.sender].start == 0, "open: existing position");
    {
        bytes32 positionKey = PositionKey.compute(manager, tickLowerCol, tickLowerCol + tickDelta);
        (, uint256 feeGrowthInside0LastX128c, uint256 feeGrowthInside1LastX128c, , ) = IUniswapV3Pool(pool).positions(positionKey);
        borrower[tickLowerCol][msg.sender] = Borrower(tickLower, amount, _liquidity, _interest, block.timestamp, feeGrowthInside0LastX128c, feeGrowthInside1LastX128c);    
    }    
        //Lock loan liquidity
        liquidity[tickLower].locked += amount - _interest;
        //Check requirement collateral >= borrow + margin
        checkRequirement(tickLower, tickLowerCol, amount.toInt128(), _liquidity.toInt128());
        //Burn borrow amounts
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(liquidity[tickLower].liquidityId, amount - _interest, amountAMin, amountBMin);
        //Update pool feegrowth liquidty
        updateLiquidityPoolFee(tickLower);
        //Store available liquidity
        availableLiquidity[uint24(tickLower + 887272)] -= amount - _interest; 
        //Withdraw borrow amounts
        collectLiquidity(liquidity[tickLower].liquidityId, _amountA.toUint128(), _amountB.toUint128(), msg.sender);  
    }

    function close(int24 tickLowerCol, address owner) public {
        //Get borrow position
        Borrower memory param = borrower[tickLowerCol][owner];
        //Check existance
        require(param.start != 0, "close: no open position");
        //Calculate interest required
        uint256 required = getInterest(param.tick, tickLowerCol, param.liquidity, param.start);
        if (param.interest >= required) {
            //Only owner allowed
            require(owner == msg.sender, "close: not the owner");
            param.interest -= required.toUint128();
            //Return unused interest
            param.liquidity -= param.interest;
        }   
        //Retrieve collateral poolfee
        bytes32 positionKey = PositionKey.compute(manager, tickLowerCol, tickLowerCol + tickDelta);
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , ) = IUniswapV3Pool(pool).positions(positionKey);
        collectFee(tickLowerCol, param.liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, param.feeGrowthInside0LastX128, param.feeGrowthInside1LastX128);
        //Adjust individual collateral position
        collateral[tickLowerCol].amount -= param.liquidityCol;  
        delete borrower[tickLowerCol][owner];     
        //Deposit liquidity to pool
        (uint160 priceX96,int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        (int256 amountA, int256 amountB) = liquidityToAmounts(tick, param.tick, priceX96, param.liquidity.toInt128());
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), amountA.toUint256()); 
        TransferHelper.safeApprove(tokenA, manager, amountA.toUint256());  
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), amountB.toUint256()); 
        TransferHelper.safeApprove(tokenB, manager, amountB.toUint256());    
        addLiquidity(param.tick, liquidity[param.tick].liquidityId, (amountA.toUint256()).toUint128(), (amountB.toUint256()).toUint128());
        //Update pool feegrowth liquidty
        updateLiquidityPoolFee(param.tick);
        //Unlock liquidity
        liquidity[param.tick].locked -= param.liquidity - param.interest; 
        //Add interest to liquidity
        liquidity[param.tick].liquidity += param.interest;  
        //Adjust available liquidity
        availableLiquidity[uint24(param.tick + 887272)] += param.liquidity;
        //Withdraw collateral from pool
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(collateral[tickLowerCol].collateralId, param.liquidityCol, 0, 0);
        collectLiquidity(collateral[tickLowerCol].collateralId, _amountA.toUint128(), _amountB.toUint128(), msg.sender);
    }

    //Internal functions
    function addLiquidity(int24 tickLower, uint256 id, uint128 amountA, uint128 amountB) internal returns(uint256, uint128){
        if (id == 0) {
            //Mint LP pool position
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams(
                tokenA,                                 //address token0;
                tokenB,                                 //address token1;
                poolFee,                                //uint24 fee;
                tickLower,                              //int24 tickLower;
                tickLower + tickDelta,                  //int24 tickUpper;
                amountA,                                //uint256 amount0Desired; 
                amountB,                                //uint256 amount1Desired; 
                0,                                      //uint256 amount0Min;
                0,                                      //uint256 amount1Min;
                address(this),                          //address recipient;
                block.timestamp
            );
            (uint256 _id, uint128 liquidityDelta, , ) = INonfungiblePositionManager(manager).mint(params);
            return (_id, liquidityDelta);
        } else {
            //Add liquidity
            INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager.IncreaseLiquidityParams(
                id,                                     //uint256 tokenId;
                amountA,                                //uint256 amount0Desired; 
                amountB,                                //uint256 amount1Desired; 
                0,                                      //uint256 amount0Min;
                0,                                      //uint256 amount1Min;
                block.timestamp
            );
            (uint128 liquidityDelta , , ) = INonfungiblePositionManager(manager).increaseLiquidity(params);
            return (id, liquidityDelta);
        } 
    }

    function removeLiquidity(uint256 id, uint128 amount, uint128 minAmount0, uint128 minAmount1) internal returns(uint256 amountA, uint256 amountB) {
        //Burn LP
        INonfungiblePositionManager.DecreaseLiquidityParams memory paramsDecrease = INonfungiblePositionManager.DecreaseLiquidityParams(
            id,                                         //uint256 tokenId; 
            amount,                                     //uint128 liquidity;
            minAmount0,                                 //uint256 amount0Min;
            minAmount1,                                 //uint256 amount1Min;
            block.timestamp                             //uint256 deadline;
        );
        (amountA, amountB) = INonfungiblePositionManager(manager).decreaseLiquidity(paramsDecrease);
    }

    function collectLiquidity(uint256 id, uint128 amountA, uint128 amountB, address receiver) internal returns(uint256 amount0, uint256 amount1){
        //Retrieve burned amounts
        INonfungiblePositionManager.CollectParams memory paramsCollect = INonfungiblePositionManager.CollectParams(
            id,                                         //uint256 tokenId;
            receiver,                                   //address recipient;
            amountA,                                    //uint128 amount0Max;
            amountB                                     //uint128 amount1Max;
        );
        (amount0, amount1) = INonfungiblePositionManager(manager).collect(paramsCollect);     
    }

    function collectFee(int24 tickLower, uint256 _liquidity, uint256 feeGrowth0LastX128, uint256 feeGrowth1LastX128, uint256 feeGrowth0PositionX128, uint256 feeGrowth1PositionX128) internal {
        uint256 delta0;
        uint256 delta1;
        unchecked{
            delta0 = feeGrowth0LastX128 - feeGrowth0PositionX128;
            delta1 = feeGrowth1LastX128 - feeGrowth1PositionX128;
        }
        withdraws[tickLower][msg.sender].timestamp = block.timestamp;
        withdraws[tickLower][msg.sender].amountA += uint128(
            FullMath.mulDiv(
                delta0,
                _liquidity,
                FixedPoint128.Q128
            )
        );
        withdraws[tickLower][msg.sender].amountB += uint128(
            FullMath.mulDiv(
                delta1,
                _liquidity,
                FixedPoint128.Q128
            )
        );
    }

    function updateLiquidityPoolFee(int24 tickLower) internal {
        //Adjust feegrowth for difference in liquidity
        bytes32 lendingKey = PositionKey.compute(manager, tickLower, tickLower + tickDelta);
        (, uint256 feeGrowthInside0LastX128l, uint256 feeGrowthInside1LastX128l, , ) = IUniswapV3Pool(pool).positions(lendingKey); 
        if(liquidity[tickLower].liquidity != 0){
            liquidity[tickLower].feeGrowthLocal0LastX128 += feeGrowthInside0LastX128l - feeGrowth[tickLower][0] * availableLiquidity[uint24(tickLower + 887272)] / liquidity[tickLower].liquidity;
            liquidity[tickLower].feeGrowthLocal0LastX128 += feeGrowthInside1LastX128l - feeGrowth[tickLower][1] * availableLiquidity[uint24(tickLower + 887272)] / liquidity[tickLower].liquidity;
            feeGrowth[tickLower][0] = feeGrowthInside0LastX128l;
            feeGrowth[tickLower][1] = feeGrowthInside1LastX128l;
        }
    }

    //View functions
    function checkRequirement(int24 tickBor, int24 tickCol, int128 amountBor, int128 amountCol) public view {
        int256 bor0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickBor),
                TickMath.getSqrtRatioAtTick(tickBor + tickDelta),  
                amountBor
        ); 
        int256 bor1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickBor),
                TickMath.getSqrtRatioAtTick(tickBor + tickDelta),  
                amountBor
        );
        int256 col0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickCol),
                TickMath.getSqrtRatioAtTick(tickCol + tickDelta),  
                amountCol
        ); 
        int256 col1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickCol),
                TickMath.getSqrtRatioAtTick(tickCol + tickDelta),  
                amountCol
        );
        //bor and cor are positive for positve liquidity inputs
        col0 = col0 * (margin + BASE_MARGIN) / BASE_MARGIN;
        col1 = col1 * (margin + BASE_MARGIN) / BASE_MARGIN;
        require(bor0 <= col0 && bor1 <= col1, "checkRequirement: insufficient collateral for borrow");
    }

    function liquidityToAmounts(int24 tickCurrent, int24 tick, uint160 priceX96, int128 _liquidity) public view returns(int256 amount0, int256 amount1){
        if (_liquidity != 0) {
            if (tickCurrent < tick) {
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(tick),
                    TickMath.getSqrtRatioAtTick(tick + tickDelta),
                    _liquidity
                );
            } else if (tickCurrent < tick + tickDelta) {
                amount0 = SqrtPriceMath.getAmount0Delta(
                    priceX96,
                    TickMath.getSqrtRatioAtTick(tick + tickDelta),
                    _liquidity
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tick),
                    priceX96,
                    _liquidity
                );
            } else {
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tick),
                    TickMath.getSqrtRatioAtTick(tick + tickDelta),
                    _liquidity
                );
            }
        }
    }

    //Interest = liquidity * time passed * number ticks passed * interest per second per tick
    //Fee = liquidity * start fee
    function getInterest(int24 tickBor, int24 tickCol, uint256 _liquidity, uint256 start) public view returns(uint256 amount){
        //Order ticks
        (int24 tickLow, int24 tickUp) = tickBor > tickCol ? (tickBor, tickCol) : (tickCol, tickBor);
        //Calculate interest and fee
        uint256 deltaTime = (block.timestamp - start);
        uint24 deltaTick = uint24((tickLow - tickUp) / tickDelta);
        uint256 deltaInterest = interest * deltaTime * deltaTick;
        uint256 _interest = _liquidity * deltaInterest / BASE_INTEREST;
        uint256 _fee = _liquidity * fee / BASE_FEE;
        amount =  _interest + _fee;
    }
}


