// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.19;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-periphery/contracts/libraries/PositionKey.sol';

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
    } 

    struct Collateral { 
        uint256 collateralId;
        uint128 amount;
    }

    struct Borrower { 
        int24 tick;
        uint128 liquidity;
        uint128 liquidityCol;
        uint128 interest;
        uint256 start;
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

    uint256[887272 * 2] public availableLiquidity;

    mapping(int24 => Liquidity) public liquidity;
    mapping(int24 => Collateral) public collateral;
    mapping(int24 => mapping(address => uint128)) public lender;
    mapping(int24 => mapping(address => Borrower)) public borrower;
    mapping(int24 => mapping(address => Withdraw)) public withdraws;

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
        //Transfer funds and approve manager
        //Notice no safety checks for minimal implementation - checks in calling contract 
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), amountA); 
        TransferHelper.safeApprove(tokenA, manager, amountA); 
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), amountB); 
        TransferHelper.safeApprove(tokenB, manager, amountB); 
        //Add liquidity to pool     
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLower, liquidity[tickLower].liquidityId, amountA, amountB);
        //Store user share of liquidity
        uint128 share = liquidity[tickLower].shares == 0 ? _liquidity : liquidity[tickLower].liquidity / liquidity[tickLower].shares * _liquidity;
        require(share > 0, "provide: insufficient share");
        lender[tickLower][msg.sender] += share;
        //Store global liquidity data
        liquidity[tickLower].liquidityId = _id;
        liquidity[tickLower].liquidity += _liquidity; 
        liquidity[tickLower].shares = share;
        //Store available liquidity
        availableLiquidity[uint24(tickLower + 887272)] += _liquidity;     
    }

    function take(int24 tickLower, address receiver, uint128 share, uint128 amountMin0, uint128 amountMin1) public {                  
        uint128 amount = liquidity[tickLower].liquidity / liquidity[tickLower].shares * share;
        require(liquidity[tickLower].liquidity - liquidity[tickLower].locked >= amount, "take: insufficient liquidity");
        //Adjust global position  
        liquidity[tickLower].liquidity -= amount;  
        liquidity[tickLower].shares -= share; 
        //Adjust available liquidity
        availableLiquidity[uint24(tickLower + 887272)] -= amount; 
        //Adjust individual positions
        lender[tickLower][msg.sender] -= share;  
        //Remove liquidity from pool
        (uint256 amountA, uint256 amountB) = removeLiquidity(liquidity[tickLower].liquidityId, amount, amountMin0, amountMin1);
        //Collect withdraw amounts
        collectLiquidity(liquidity[tickLower].liquidityId, amountA.toUint128(), amountB.toUint128(), address(this));  
        //Store withdraw 
        withdraws[tickLower][receiver].amountA += amountA.toUint128();
        withdraws[tickLower][receiver].amountB += amountB.toUint128();
        withdraws[tickLower][receiver].timestamp += block.timestamp;
    }

    function withdraw(int24 tickLower) public {
        require(withdraws[tickLower][msg.sender].timestamp < block.timestamp, "withdraw: pending");
        uint128 withdrawA = withdraws[tickLower][msg.sender].amountA;
        uint128 withdrawB = withdraws[tickLower][msg.sender].amountB;
        delete withdraws[tickLower][msg.sender];
        TransferHelper.safeTransfer(address(tokenA), msg.sender, withdrawA); 
        TransferHelper.safeTransfer(address(tokenB), msg.sender, withdrawB); 
    }

    function collect(int24 tickLower) public {
        uint256 amount0;
        uint256 amount1;
        if(liquidity[tickLower].liquidityId != 0){
            //Collect LP interest
            (uint256 liq0, uint256 liq1) = collectLiquidity(liquidity[tickLower].liquidityId, type(uint128).max, type(uint128).max, address(this)); 
            amount0 += liq0;
            amount1 += liq1;
        }
        if(collateral[tickLower].collateralId != 0){
            //Collect LP interest
            (uint256 col0, uint256 col1) = collectLiquidity(collateral[tickLower].collateralId, type(uint128).max, type(uint128).max, address(this));
            amount0 += col0;
            amount1 += col1;
        }
        //Redeposit LP interest 
        (, uint128 _liquidity) = addLiquidity(tickLower, liquidity[tickLower].liquidityId, amount0.toUint128(), amount1.toUint128());
        //Store available liquidity
        liquidity[tickLower].liquidity += _liquidity; 
        availableLiquidity[uint24(tickLower + 887272)] += _liquidity;     
    }

    // Borrow functions
    // @notice: open() function allows depositing more collateral than needed
    function open(int24 tickLower, int24 tickLowerCol, uint128 amount, uint128 amountAMin, uint128 amountBMin, uint128 colA, uint128 colB, uint128 _interest) public {
        //Check enough assets available
        require(tickLower != tickLowerCol, "open: false ticks");
        require(liquidity[tickLower].liquidity - liquidity[tickLower].locked >= amount, "open: insufficient funds available");
        //Check interest available
        require(_interest > amount * fee / BASE_FEE, "open: insufficient interest");
        require(amount > 10000, "open: insufficient liquidity for startingfee");
        //Add Collateral to pool                
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), colA); 
        TransferHelper.safeApprove(tokenA, manager, colA);    
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), colB); 
        TransferHelper.safeApprove(tokenB, manager, colB);            
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLowerCol, collateral[tickLowerCol].collateralId, colA, colB);
        //Store collateral global and individual
        collateral[tickLowerCol].collateralId = _id;
        collateral[tickLowerCol].amount += _liquidity;         
        borrower[tickLowerCol][msg.sender] = Borrower(tickLower, amount, _liquidity, _interest, block.timestamp);    
        //Lock liquidity for loan 
        liquidity[tickLower].locked += amount - _interest;
        //Adjust available liquidity
        availableLiquidity[uint24(tickLower + 887272)] -= amount - _interest; 
        //Check requirement collateral >= borrow
        checkRequirement(tickLower, tickLowerCol, amount.toInt128(), _liquidity.toInt128());
        //Withdraw liquidity from pool
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(liquidity[tickLower].liquidityId, amount - _interest, amountAMin, amountBMin);
        collectLiquidity(liquidity[tickLower].liquidityId, _amountA.toUint128(), _amountB.toUint128(), msg.sender);  
    }

    function close(int24 tickLowerCol, address owner) public {
        int24 _tickLower = borrower[tickLowerCol][owner].tick;
        uint128 _liquidity = borrower[tickLowerCol][owner].liquidity;
        uint128 _liquidityCol = borrower[tickLowerCol][owner].liquidityCol;
        //Calculate interest
        uint256 required = getInterest(_tickLower, tickLowerCol, _liquidity, borrower[tickLowerCol][owner].start);
        //Release locked liquidity
        liquidity[_tickLower].locked -= _liquidity - borrower[tickLowerCol][owner].interest; 
        if (borrower[tickLowerCol][msg.sender].interest >= required) {
            //Only owner can close open position
            require(owner == msg.sender, "close: not the owner");
            //Return unused interest by lowering the required liquidity deposit
            _liquidity = _liquidity - (borrower[tickLowerCol][owner].interest - required.toUint128());
            //Add interest to liquidity
            liquidity[_tickLower].liquidity += borrower[tickLowerCol][owner].interest - required.toUint128();
        } else {
            //Add interest to liquidity
            liquidity[_tickLower].liquidity += borrower[tickLowerCol][owner].interest;  
        }
        //Adjust available liquidity
        availableLiquidity[uint24(_tickLower + 887272)] += _liquidity;  
        collateral[tickLowerCol].amount -= _liquidityCol;  
        delete borrower[tickLowerCol][owner];     
        //Deposit liquidity to pool
        (uint160 priceX96,int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        (int256 amountA, int256 amountB) = liquidityToAmounts(tick, _tickLower, priceX96, _liquidity.toInt128());
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), amountA.toUint256()); 
        TransferHelper.safeApprove(tokenA, manager, amountA.toUint256());  
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), amountB.toUint256()); 
        TransferHelper.safeApprove(tokenB, manager, amountB.toUint256());    
        addLiquidity(_tickLower, liquidity[_tickLower].liquidityId, (amountA.toUint256()).toUint128(), (amountB.toUint256()).toUint128());
        //Withdraw collateral from pool
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(collateral[tickLowerCol].collateralId, _liquidityCol, 0, 0);
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
                amountB,                                //uint256 amount1De sired; 
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

    //View function
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
        col1 = col0 * (margin + BASE_MARGIN) / BASE_MARGIN;
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

    function getInterest(int24 tickBor, int24 tickCol, uint256 _liquidity, uint256 start) public view returns(uint256 amount){
        uint24 ticks = uint24((tickBor - tickCol) / tickDelta);
        amount = (block.timestamp - start) * interest * ticks * _liquidity / BASE_INTEREST + _liquidity * fee / BASE_FEE;
    }

}


