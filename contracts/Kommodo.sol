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
        uint128 fee;
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
    
    //Interest as minimal interest per second per tickdelta -> 10^12 value 
    uint128 public BASE_FEE = 10000;
    uint128 public BASE_INTEREST = 10e12;
    uint128 public fee;
    uint128 public interest;
   
    uint256 private nextLiquidityId = 1;
    uint256 private nextCollateralId = 1;

    mapping(int24 => Liquidity) public liquidity;
    mapping(int24 => Collateral) public collateral;
    mapping(int24 => mapping(uint256 => uint128)) public lender;
    mapping(int24 => mapping(uint256 => Borrower)) public borrower;
    mapping(int24 => mapping(address => Withdraw)) public withdraws;

    function initialize(address _manager, address _factory, address _tokenA, address _tokenB, int24 _tickDelta, uint24 _poolFee, uint128 _fee, uint128 _interest) public {
        require(initialized == false, "initialize: already initialized");
        initialized = true;
        IUniswapV3Factory factory = IUniswapV3Factory(_factory);
        pool = IUniswapV3Pool(factory.getPool(_tokenA, _tokenB, _poolFee));
        manager = INonfungiblePositionManager(_manager);
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        tickDelta = _tickDelta;
        poolFee = _poolFee;
        fee = _fee;
        interest = _interest;
        liquidityNFT = new Positions("testLiquid", "TSTL");
        collateralNFT = new Positions("testBorrow", "TSTB");
    }

    // Lend functions
    function provide(int24 tickLower, uint128 amountA, uint128 amountB) public {
        //Transfer funds and approve manager
        //Notice no safety checks for minimal implementation - checks in calling contract 
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
    // @notice: open() function allows depositing more collateral than needed
    function open(int24 tickLower, int24 tickLowerCol, uint128 amount, uint128 amountAMin, uint128 amountBMin, uint128 colA, uint128 colB, uint128 _interest) public {
        //Check enough assets available
        require(tickLower != tickLowerCol, "open: false ticks");
        require(liquidity[tickLower].liquidity - liquidity[tickLower].locked >= amount, "open: insufficient funds available");
        //Check interest available
        require(_interest != 0, "open: insufficient interest");
        require(amount > 10000, "open: insufficient liquidity for startingfee");
        //Mint Collateral NFT
        uint256 id = nextCollateralId;
        nextCollateralId += 1;
        collateralNFT.mint(msg.sender, id);  
        //Add Collateral to pool                
        TransferHelper.safeTransferFrom(address(tokenA), msg.sender, address(this), colA); 
        TransferHelper.safeApprove(address(tokenA), address(manager), colA);    
        TransferHelper.safeTransferFrom(address(tokenB), msg.sender, address(this), colB); 
        TransferHelper.safeApprove(address(tokenB), address(manager), colB);            
        (uint256 _id, uint128 _liquidity) = addLiquidity(tickLowerCol, collateral[tickLowerCol].collateralId, colA, colB);
        //Store collateral global and individual
        collateral[tickLowerCol].collateralId = _id;
        collateral[tickLowerCol].amount += _liquidity;         
        borrower[tickLowerCol][id] = Borrower(tickLower, amount, _liquidity, _interest, amount * 10 / 10000,block.timestamp);    
        //Add starting fee to interest
        _interest += amount * 10 / BASE_FEE;
        //Lock liquidity for loan 
        liquidity[tickLower].locked += amount - _interest;
        //Check requirement collateral >= borrow
        checkRequirement(tickLower, tickLowerCol, amount.toInt128(), _liquidity.toInt128());
        //Withdraw liquidity from pool
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(liquidity[tickLower].liquidityId, amount - _interest, amountAMin, amountBMin);
        collectLiquidity(liquidity[tickLower].liquidityId, _amountA.toUint128(), _amountB.toUint128());  
    }

    function close(int24 tickLowerCol, uint256 id) public {
        int24 _tickLower = borrower[tickLowerCol][id].tick;
        uint128 _liquidity = borrower[tickLowerCol][id].liquidity;
        uint128 _liquidityCol = borrower[tickLowerCol][id].liquidityCol;
        //Calculate interest
        uint256 required = tickInterest(_tickLower, tickLowerCol, _liquidity, borrower[tickLowerCol][id].start);
        //Release locked liquidity
        liquidity[_tickLower].locked -= _liquidity - borrower[tickLowerCol][id].interest - borrower[tickLowerCol][id].fee;   
        if (borrower[tickLowerCol][id].interest >= required) {
            //Only owner can close open position
            require(collateralNFT.ownerOf(id) == msg.sender, "close: not the owner");
            //Return unused interest by lowering the required liquidity deposit
            _liquidity = _liquidity - (borrower[tickLowerCol][id].interest - required.toUint128());
            //Add interest to liquidity
            liquidity[_tickLower].liquidity += borrower[tickLowerCol][id].interest - required.toUint128();
        } 
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
        //Withdraw collateral from pool
        (uint256 _amountA, uint256 _amountB) = removeLiquidity(collateral[tickLowerCol].collateralId, _liquidityCol, 0, 0);
        collectLiquidity(collateral[tickLowerCol].collateralId, _amountA.toUint128(), _amountB.toUint128());
    }

    //Internal functions
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

    function checkRequirement(int24 tickBor, int24 tickCol, int128 amountBor, int128 amountCol) internal view {
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
        require(bor0 <= col0 && bor1 <= col1, "checkRequirement: insufficient collateral for borrow");
    }

    //View function
    function liquidityToAmounts(int24 tickCurrent, int24 tick, uint160 priceX96, int128 _liquidity) public view returns(int256 amount0, int256 amount1){
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

    function tickInterest(int24 tickBor, int24 tickCol, uint256 _liquidity, uint256 start) public view returns(uint256 amount){
        uint24 ticks = uint24((tickBor - tickCol) / tickDelta);
        amount = (block.timestamp - start) * interest * ticks * _liquidity / BASE_INTEREST;
    }
}


