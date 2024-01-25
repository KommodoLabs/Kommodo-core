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
    } 

    struct Collateral { 
        uint256 collateralId;
        uint128 amount;
    }

    struct Borrower { 
        uint128 liquidity;
        uint128 liquidityCol;
        uint128 interest;
        uint256 lastUsed;
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

    uint128 public fee;
    uint128 public interest;
    int256 public margin;
    //Length is total tickspace 
    uint256[1774544] public availableLiquidity;

    mapping(int24 => Liquidity) public liquidity;
    mapping(int24 => Collateral) public collateral;
    mapping(int24 => mapping(address => uint128)) public lender;
    mapping(int24 => mapping(address => Withdraw)) public withdraws;
    mapping(bytes32 => Borrower) public borrower;

    constructor(address _manager, address _tokenA, address _tokenB, uint24 _poolFee, uint128 _fee, uint128 _interest, int256 _margin) {
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
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), amountA); 
        TransferHelper.safeApprove(tokenA, manager, amountA); 
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), amountB); 
        TransferHelper.safeApprove(tokenB, manager, amountB); 
        //Add liquidity to pool     
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLower, liquidity[tickLower].liquidityId, amountA, amountB);
        //Store individual position
        uint128 share = liquidity[tickLower].shares == 0 ? _liquidity : _liquidity / (liquidity[tickLower].liquidity / liquidity[tickLower].shares);
        require(share > 0, "provide: insufficient share");
        lender[tickLower][msg.sender] += share;
        //Store global liquidity data
        liquidity[tickLower].liquidityId = _id;
        liquidity[tickLower].liquidity += _liquidity; 
        liquidity[tickLower].shares += share;
        //Adjust available liquidity
        availableLiquidity[uint24(tickLower + 887272)] += _liquidity;     
    }

    function take(int24 tickLower, address receiver, uint128 share, uint128 amountMinA, uint128 amountMinB) public {                  
        //Check sufficient liquidity
        uint128 amount = liquidity[tickLower].liquidity / liquidity[tickLower].shares * share;
        require(liquidity[tickLower].liquidity - liquidity[tickLower].locked >= amount, "take: insufficient liquidity");
        //Remove liquidity from pool
        (uint256 amountA, uint256 amountB) = removeLiquidity(liquidity[tickLower].liquidityId, amount, amountMinA, amountMinB);
        //Adjust individual positions
        lender[tickLower][msg.sender] -= share;  
        //Adjust global position  
        liquidity[tickLower].liquidity -= amount;  
        liquidity[tickLower].shares -= share; 
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
    function open(int24 tickLowerBor, int24 tickLowerCol, uint128 amount, uint128 amountAMin, uint128 amountBMin, uint128 colA, uint128 colB, uint128 _interest) public {
        bytes32 key = getKey(msg.sender, tickLowerBor, tickLowerCol);
        //Check liquidity available
        require(tickLowerBor != tickLowerCol, "open: false ticks");
        require(liquidity[tickLowerBor].liquidity - liquidity[tickLowerBor].locked >= amount, "open: insufficient funds available");
        //Check minimal interest
        require(amount > BASE_FEE, "open: insufficient liquidity for startingfee");
        require(_interest > getFee(amount), "open: insufficient interest");
        //Add Collateral to pool                
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), colA); 
        TransferHelper.safeApprove(tokenA, manager, colA);    
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), colB); 
        TransferHelper.safeApprove(tokenB, manager, colB);            
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLowerCol, collateral[tickLowerCol].collateralId, colA, colB);
        //Store global position
        collateral[tickLowerCol].collateralId = _id;
        collateral[tickLowerCol].amount += _liquidity;
        //Check closed
        require(borrower[key].interest >= getInterest(tickLowerBor, tickLowerCol, borrower[key].liquidity, borrower[key].start) + borrower[key].lastUsed, "open: loan closed");
        //Store individual position including collateral poolfee data
        borrower[key].liquidity += amount;
        borrower[key].liquidityCol += _liquidity;
        borrower[key].interest += _interest;
        borrower[key].start = block.timestamp;
        borrower[key].lastUsed += getInterest(tickLowerBor, tickLowerCol, amount, borrower[key].start) + getFee(amount); 
        //Lock loan liquidity
        liquidity[tickLowerBor].locked += amount - _interest;
        //Check requirement collateral >= borrow + margin
        checkRequirement(tickLowerBor, tickLowerCol, borrower[key].liquidity .toInt128(), borrower[key].liquidityCol.toInt128());
        //Burn borrow amounts
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(liquidity[tickLowerBor].liquidityId, amount - _interest, amountAMin, amountBMin);
        //Store available liquidity
        availableLiquidity[uint24(tickLowerBor + 887272)] -= amount - _interest; 
        //Withdraw borrow amounts
        collectLiquidity(liquidity[tickLowerBor].liquidityId, _amountA.toUint128(), _amountB.toUint128(), msg.sender);  
    }

    function close(int24 tickLowerBor, int24 tickLowerCol, address owner, uint128 amountBor, uint128 amountCol) public {
        //Get borrow position
        Borrower memory param = borrower[getKey(owner, tickLowerBor, tickLowerCol)];
        require(param.start != 0, "close: no open position"); 
        //Adjust global collateral position
        collateral[tickLowerCol].amount -= amountCol;  
        //Get interest used
        uint256 required = getInterest(tickLowerBor, tickLowerCol, param.liquidity, param.start) + param.lastUsed;
        require(owner == msg.sender || param.interest < required, "close: not the owner");
        if(param.liquidity == amountBor && param.liquidityCol == amountCol) {
            //Full close position
            //Add received interest to global liquidity
            liquidity[tickLowerBor].liquidity += required.toUint128(); 
            //Unlock returned liquidity  
            liquidity[tickLowerBor].locked -= (amountBor - param.interest); 
            //Adjust borrowed amount for unused interest
            param.interest = required.toUint128() > param.interest ? 0 : param.interest - required.toUint128();
            amountBor -= param.interest;
            //Delete individual position
            delete borrower[getKey(owner, tickLowerBor, tickLowerCol)];     
        } else {
            //Partialy close position   
            require(param.liquidity - amountBor > required.toUint128(), "close: insufficient actual interest");
            Borrower storage _borrower = borrower[getKey(owner, tickLowerBor, tickLowerCol)];
            //Unlock returned liquidity  
            require(param.liquidity - amountBor > param.interest, "close: insufficient interest");
            liquidity[tickLowerBor].locked -= amountBor; 
            //Store interest to date
            _borrower.start = block.timestamp;   
            _borrower.lastUsed = required;
            //check requirement and adjust amounts
            checkRequirement(tickLowerBor, tickLowerCol, (param.liquidity - amountBor).toInt128(), (param.liquidityCol - amountCol).toInt128());
            //adjust amounts
            _borrower.liquidity -= amountBor;
            _borrower.liquidityCol -= amountCol;
        }
        //Deposit liquidity to pool
        (uint160 priceX96,int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        (int256 amountA, int256 amountB) = liquidityToAmounts(tick, tickLowerBor, priceX96, amountBor.toInt128());
        TransferHelper.safeTransferFrom(tokenA, msg.sender, address(this), amountA.toUint256()); 
        TransferHelper.safeApprove(tokenA, manager, amountA.toUint256());  
        TransferHelper.safeTransferFrom(tokenB, msg.sender, address(this), amountB.toUint256()); 
        TransferHelper.safeApprove(tokenB, manager, amountB.toUint256());    
        addLiquidity(tickLowerBor, liquidity[tickLowerBor].liquidityId, (amountA.toUint256()).toUint128(), (amountB.toUint256()).toUint128());
        //Adjust available liquidity
        availableLiquidity[uint24(tickLowerBor + 887272)] += amountBor;  
        //Withdraw collateral from pool
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(collateral[tickLowerCol].collateralId, amountCol, 0, 0);
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
    function getInterest(int24 tickBor, int24 tickCol, uint256 _liquidity, uint256 start) public view returns(uint256 amount){
        //Order ticks
        (int24 tickLow, int24 tickUp) = tickBor > tickCol ? (tickBor, tickCol) : (tickCol, tickBor);
        //Calculate interest and fee
        uint256 deltaTime = (block.timestamp - start);
        uint24 deltaTick = uint24((tickLow - tickUp) / tickDelta);
        uint256 deltaInterest = interest * deltaTime * deltaTick;
        amount = _liquidity * deltaInterest / BASE_INTEREST;
    }

    //Fee = liquidity * start fee
    function getFee(uint256 _liquidity) public view returns(uint256 amount){
        amount = _liquidity * fee / BASE_FEE;
    }

    function getKey(address owner, int24 tickLowerBor, int24 tickLowerCol) public pure returns(bytes32 key){
        key = keccak256(abi.encode(owner, tickLowerBor, tickLowerCol));
    }

}




 


