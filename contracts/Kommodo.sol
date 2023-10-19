// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.19;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

import './libraries/SqrtPriceMath.sol';
import './libraries/TickMath.sol';
import './libraries/SafeCast.sol';

import './interfaces/INonfungiblePositionManager.sol';
import './Positions.sol';

/**
* @dev Kommodo - loan pool                             
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

    INonfungiblePositionManager public manager;
    IUniswapV3Pool public pool;
    IERC20 public tokenA;                                           
    IERC20 public tokenB;
    Positions public liquidityNFT;
    Positions public collateralNFT;

    bool public initialized;
    int24 public tickDelta;
    uint24 public poolFee; 
    uint24 public interest;

    uint256 private nextLiquidityId = 1;
    uint256 private nextCollateralId = 1;

    mapping(int24 => Liquidity) public liquidity;
    mapping(int24 => Collateral) public collateral;
    mapping(int24 => mapping(uint256 => uint128)) public lender;
    mapping(int24 => mapping(uint256 => Borrower)) public borrower;
    mapping(int24 => mapping(address => Withdraw)) public withdraws;


    function initialize(address _manager, address _factory, address _tokenA, address _tokenB, int24 _tickDelta, uint24 _poolFee, uint24 _interest) public {
        require(initialized == false, "initialize: already initialized");
        initialized = true;
        IUniswapV3Factory factory = IUniswapV3Factory(_factory);
        pool = IUniswapV3Pool(factory.getPool(_tokenA, _tokenB, _poolFee));
        manager = INonfungiblePositionManager(_manager);
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        tickDelta = _tickDelta;
        poolFee = _poolFee;
        interest = _interest;
        liquidityNFT = new Positions("testLiquid", "TSTL");
        collateralNFT = new Positions("testBorrow", "TSTB");
    }

    // Lend functions
    function provide(int24 tickLower, uint128 amountA, uint128 amountB) public {
        //Transfer funds and apporve manager
        TransferHelper.safeTransferFrom(address(tokenA), msg.sender, address(this), amountA); 
        TransferHelper.safeApprove(address(tokenA), address(manager), amountA); 
        TransferHelper.safeTransferFrom(address(tokenB), msg.sender, address(this), amountB); 
        TransferHelper.safeApprove(address(tokenB), address(manager), amountB); 
        //Store Lender Liquidity Position
        uint256 position = nextLiquidityId;
        nextLiquidityId += 1;
        liquidityNFT.mint(msg.sender, position);
        //Add liquidity to pool     
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLower, liquidity[tickLower].liquidityId, amountA, amountB);
        //Store user share of liquidity
        uint128 share = liquidity[tickLower].shares == 0 ? _liquidity : liquidity[tickLower].liquidity / liquidity[tickLower].shares * _liquidity;
        require(share > 0, "provide: insufficient share");
        lender[tickLower][position] += share;
        //Store global liquidity data
        liquidity[tickLower].liquidityId = _id;
        liquidity[tickLower].liquidity += _liquidity; 
        liquidity[tickLower].shares = share;       
    }

    function take(int24 tickLower, uint256 position, address receiver, uint128 share, uint128 amountMin0, uint128 amountMin1) public {                  
        uint128 amount = liquidity[tickLower].liquidity / liquidity[tickLower].shares * share;
        require(liquidityNFT.ownerOf(position) == msg.sender, "take: not the owner");
        require(liquidity[tickLower].liquidity - liquidity[tickLower].locked >= amount, "take: insufficient liquidity");
        //Adjust global position  
        liquidity[tickLower].liquidity -= amount;  
        liquidity[tickLower].shares -= share;  
        //Adjust individual positions
        lender[tickLower][position] -= share;  
        //Remove liquidity from pool
        (uint256 amountA, uint256 amountB) = removeLiquidity(liquidity[tickLower].liquidityId, amount, amountMin0, amountMin1);
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
        collectLiquidity(liquidity[tickLower].liquidityId, withdrawA, withdrawB);  
    }

    // Borrow functions
    function open(int24 tickLower, int24 tickLowerCol, uint128 amount, uint128 _interest, uint128 amountAMin, uint128 amountBMin) public {
        //Check enough assets available
        require(liquidity[tickLower].liquidity - liquidity[tickLower].locked >= amount, "open: insufficient funds available");
        require(tickLower != tickLowerCol, "open: false ticks");
        //Mint Collateral NFT
        uint256 id = nextCollateralId;
        nextCollateralId += 1;
        collateralNFT.mint(msg.sender, id);  
        //Calculate collateral needed 
        (,int24 tick,,,,,) = pool.slot0();
        (int256 colA, int256 colB) = liquidityToCollateral(tick, tickLower, amount.toInt128());
        //Lock interest payment
        liquidity[tickLower].locked += amount;
        //Add Collateral to pool                
        TransferHelper.safeTransferFrom(address(tokenA), msg.sender, address(this), colA.toUint256()); 
        TransferHelper.safeApprove(address(tokenA), address(manager), colA.toUint256());    
        TransferHelper.safeTransferFrom(address(tokenB), msg.sender, address(this), colB.toUint256()); 
        TransferHelper.safeApprove(address(tokenB), address(manager), colB.toUint256());           
    {    
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLowerCol, collateral[tickLowerCol].collateralId, (colA.toUint256()).toUint128(), (colB.toUint256()).toUint128());
        collateral[tickLowerCol] = Collateral(_id, _liquidity);         
        borrower[tickLowerCol][id] = Borrower(tickLower, amount, _liquidity, _interest, block.timestamp);    
    }
        //Withdraw liquidity from pool
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(liquidity[tickLower].liquidityId, amount - _interest, amountAMin, amountBMin);
        checkCollateral(tick, tickLowerCol, amount.toInt128(), _amountA, _amountB);
        collectLiquidity(liquidity[tickLower].liquidityId, _amountA.toUint128(), _amountB.toUint128());  
    }

    function close(int24 tickLowerCol, uint256 id) public {
        int24 _tickLower = borrower[tickLowerCol][id].tick;
        uint128 _liquidity = borrower[tickLowerCol][id].liquidity;
        uint128 _liquidityCol = borrower[tickLowerCol][id].liquidityCol;
        //Interest calculations
        uint256 required = (block.timestamp - borrower[tickLowerCol][id].start) * interest;
        if (borrower[tickLowerCol][id].interest >= required) {
            //Only owner can close open position
            require(collateralNFT.ownerOf(id) == msg.sender, "close: not the owner");
            //Return unused interest by lowering the required liquidity deposit
            _liquidity = _liquidity - (borrower[tickLowerCol][id].interest - required.toUint128());
        } 
        //Add interest to liquidity
        liquidity[_tickLower].liquidity += borrower[tickLowerCol][id].interest;
        //Release locked liquidity
        liquidity[_tickLower].locked -= _liquidity;   
        //Burn collateral NFT
        collateralNFT.burn(id); 
        collateral[tickLowerCol].amount -= _liquidityCol;  
        delete borrower[tickLowerCol][id];
        //Deposit liquidity to pool
        (uint160 priceX96,int24 tick,,,,,) = pool.slot0();
        (int256 amountA, int256 amountB) = liquidityToAmounts(tick, _tickLower, priceX96, _liquidity.toInt128());
        TransferHelper.safeTransferFrom(address(tokenA), msg.sender, address(this), amountA.toUint256()); 
        TransferHelper.safeApprove(address(tokenA), address(manager), amountA.toUint256());  
        TransferHelper.safeTransferFrom(address(tokenB), msg.sender, address(this), amountB.toUint256()); 
        TransferHelper.safeApprove(address(tokenB), address(manager), amountB.toUint256());    
        addLiquidity(_tickLower, liquidity[_tickLower].liquidityId, (amountA.toUint256()).toUint128(), (amountB.toUint256()).toUint128());
        //Withdraw collateral form pool
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(collateral[tickLowerCol].collateralId, _liquidityCol, 0, 0);
        collectLiquidity(collateral[tickLowerCol].collateralId, _amountA.toUint128(), _amountB.toUint128());
    }

    //Internal functions -- liquidity adjustmens to pool
    function addLiquidity(int24 tickLower, uint256 id, uint128 amountA, uint128 amountB) internal returns(uint256, uint128){
        if (id == 0) {
            //Mint LP pool position
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams(
                address(tokenA),                        //address token0;
                address(tokenB),                        //address token1;
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
            (uint256 _id, uint128 liquidityDelta, , ) = manager.mint(params);
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
            (uint128 liquidityDelta , , ) = manager.increaseLiquidity(params);
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
        (amountA, amountB) = manager.decreaseLiquidity(paramsDecrease);
    }

    function collectLiquidity(uint256 id, uint128 amountA, uint128 amountB) internal {
        //Retrieve burned amounts
        INonfungiblePositionManager.CollectParams memory paramsCollect = INonfungiblePositionManager.CollectParams(
            id,                                         //uint256 tokenId;
            msg.sender,                                 //address recipient;
            amountA,                                    //uint128 amount0Max;
            amountB                                     //uint128 amount1Max;
        );
        manager.collect(paramsCollect);     
    }

    function liquidityToAmounts(int24 tickCurrent, int24 tick, uint160 priceX96, int128 _liquidity) internal view returns(int256 amount0, int256 amount1){
        if (_liquidity != 0) {
            if (tickCurrent < tick) {
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(tick),
                    TickMath.getSqrtRatioAtTick(tick + tickDelta),
                    _liquidity
                );
            } else if (tickCurrent < tick + tickDelta) {
                // current tick is inside the passed range
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
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(tick),
                    TickMath.getSqrtRatioAtTick(tick + tickDelta),
                    _liquidity
                );
            }
        }
    }

    function liquidityToCollateral(int24 tickCurrent, int24 tick, int128 amount) internal view returns(int256 amount0, int256 amount1){
        //Inverse of liquidityToAmounts() 
        if(tick < tickCurrent) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tick),
                TickMath.getSqrtRatioAtTick(tick + tickDelta),  
                amount
            );  
        } else if (tick > tickCurrent) {
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tick),
                TickMath.getSqrtRatioAtTick(tick + tickDelta),  
                amount
            );
        } else {
            revert("Open: ticks not outside current tick");
        }
    }

    function checkCollateral(int24 tickCurrent, int24 tick, int128 amount, uint256 _amountA, uint256 _amountB) internal view {
        (int256 valueA, int256 valueB) = liquidityToCollateral(tickCurrent, tick, amount);
        require(valueA.toUint256() > _amountA && valueB == 0 || valueA == 0 && valueB.toUint256() > _amountB, "checkCollateral: collateral value below borrow value");   
    }
}


