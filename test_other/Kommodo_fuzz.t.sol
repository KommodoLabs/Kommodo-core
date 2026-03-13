pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-periphery/contracts/libraries/PositionKey.sol';

import '../contracts/interfaces/INonfungiblePositionManager.sol';
import '../contracts/interfaces/IKommodoFactory.sol';
import '../contracts/interfaces/IKommodo.sol';
import '../contracts/interfaces/INonfungibleLendManager.sol';

import '../contracts/libraries/LiquidityAmounts.sol';
import "../contracts/libraries/FullMath.sol";

import '../contracts/test/Router.sol';

interface IWETH {
    function name() external returns(string memory);
    function deposit() external payable;
    function withdraw(uint) external;
    function approve(address, uint) external returns(bool);
    function transfer(address, uint) external returns(bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

contract KommodoTestFuzz is Test {
    IWETH weth;
    IWETH weth2;
    IUniswapV3Factory uniFactory;
    INonfungiblePositionManager uniPositionManager;
    IUniswapV3Pool uniPool;
    Router mockRouter;

    IKommodoFactory kommodoFactory;
    IKommodo kommodoPool;
    INonfungibleLendManager kommodoLendManager;

    address public lender = address(0x100);
    address public borrower = address(0x200);

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545");
        vm.deal(lender, 1000 ether); // Forge cheatcode
        vm.deal(borrower, 1000 ether); // Forge cheatcode
        //Setup uniswap pool
        weth = IWETH(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512);
        weth2 = IWETH(0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9);
        uniFactory = IUniswapV3Factory(0x5FbDB2315678afecb367f032d93F642f64180aa3);
        uniPositionManager = INonfungiblePositionManager(0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0);
        uniPool = IUniswapV3Pool(0x949fFf0C0AdEcF746169BBfBD680B04eABeFAe8A);
        mockRouter = Router(0x5FC8d32690cc91D4c39d9d3abcBD16989F875707);
        //Setup kommodo pool
        kommodoFactory = IKommodoFactory(0xa513E6E4b8f2a923D98304ec87F64353C4D5C853);
        kommodoPool = IKommodo(0x9bd03768a7DCc129555dE410FF8E85528A4F88b5);
        kommodoLendManager = INonfungibleLendManager(0x8A791620dd6260079BF849Dc5567aDC3F2FdC318);
        //Mint && approve tokens
        vm.startPrank(lender);
        weth.deposit{value: 100 ether}();
        weth2.deposit{value: 100 ether}();
        weth.approve(address(kommodoPool), 100 ether);
        weth2.approve(address(kommodoPool), 100 ether);
        vm.stopPrank();
        vm.startPrank(borrower);
        weth.deposit{value: 100 ether}();
        weth2.deposit{value: 100 ether}();
        weth.approve(address(kommodoPool), 100 ether);
        weth2.approve(address(kommodoPool), 100 ether);
        vm.stopPrank();
    } 
    
    function test_fuzz_kommodo_provide(uint128 depositAmount) public {   
        vm.startPrank(lender);
        //Pre conditions
        depositAmount = uint128(bound(depositAmount, 1, 100 ether));  
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        uint256 balanceWETH_before = weth.balanceOf(address(lender));
        uint256 balanceWETH2_before = weth2.balanceOf(address(lender));
        //Action
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick, 
            liquidity: depositAmount,                          
            amountMaxA: depositAmount,                   
            amountMaxB: 0      
        });
        kommodoPool.provide(provideParams);
        vm.stopPrank();
        //Post check
        (uint128 liqPool, , , ) = kommodoPool.assets(next_tick);
        (uint128 liqPosition, , , , ) = kommodoPool.lender(next_tick, address(lender));
        assertNotEq(liqPool, 0);
        assertNotEq(liqPosition, 0);
        assertEq(depositAmount, liqPosition);
        assertEq(liqPool, liqPosition);
        uint256 balanceWETH_after = weth.balanceOf(address(lender));
        uint256 balanceWETH2_after = weth2.balanceOf(address(lender));
        assertGt(balanceWETH2_before - balanceWETH2_after, 0);
        assertEq(0, balanceWETH_before - balanceWETH_after);
    }
    function test_fuzz_kommodo_take(uint128 depositAmount) public {  
        vm.startPrank(lender);
        //Pre conditions
        depositAmount = uint128(bound(depositAmount, 1, 100 ether));  
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick, 
            liquidity: depositAmount,                          
            amountMaxA: depositAmount,                   
            amountMaxB: 0      
        });
        kommodoPool.provide(provideParams);
        vm.roll(block.number + 1);
        //Pre check 
        (uint128 liqPool_before, , , ) = kommodoPool.assets(next_tick);    
        (uint128 liqPosition_before, , , , ) = kommodoPool.lender(next_tick, address(lender));
        assertNotEq(liqPool_before, 0);
        assertNotEq(liqPosition_before, 0);
        assertEq(depositAmount, liqPosition_before);
        assertEq(liqPool_before, liqPosition_before);
        uint256 balanceWETH_before = weth.balanceOf(address(lender));
        uint256 balanceWETH2_before = weth2.balanceOf(address(lender));
        //Action
        IKommodo.TakeParams memory take_params = IKommodo.TakeParams({
            tickLower: next_tick,
            liquidity: liqPosition_before,
            amountMinA: 0, 
            amountMinB: 0 
        });
        kommodoPool.take(take_params);
        vm.stopPrank();
        //Post check
        (uint128 liqPool_after, , , ) = kommodoPool.assets(next_tick);    
        (uint128 liqPosition_after, , , , ) = kommodoPool.lender(next_tick, address(lender));
        assertEq(liqPool_after, 0);
        assertEq(liqPosition_after, 0);
        uint256 balanceWETH_after = weth.balanceOf(address(lender));
        uint256 balanceWETH2_after = weth2.balanceOf(address(lender));
        assertEq(balanceWETH2_after, balanceWETH2_before);
        assertEq(balanceWETH_after, balanceWETH_before);
    }
    function test_fuzz_kommodo_withdraw(uint128 depositAmount) public {  
        vm.startPrank(lender);
        //Pre conditions
        depositAmount = uint128(bound(depositAmount, 1e6, 100 ether));  
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick, 
            liquidity: depositAmount,                          
            amountMaxA: depositAmount,                   
            amountMaxB: 0                                   
        });
        kommodoPool.provide(provideParams);
        vm.roll(block.number + 1);
        (uint128 liqPosition_before, , , , ) = kommodoPool.lender(next_tick, address(lender));
        assertEq(liqPosition_before, depositAmount);
        IKommodo.TakeParams memory take_params = IKommodo.TakeParams({
            tickLower: next_tick,
            liquidity: liqPosition_before,
            amountMinA: 0, 
            amountMinB: 0 
        });
        kommodoPool.take(take_params);
        //Pre check 
        (uint128 liqPool_after, , , ) = kommodoPool.assets(next_tick);    
        (uint128 liqPosition_after, , , , ) = kommodoPool.lender(next_tick, address(lender));
        assertEq(liqPool_after, 0);
        assertEq(liqPosition_after, 0);
        //check withdraw available
        (uint128 withdrawA, uint128 withdrawB) = kommodoPool.withdraws(next_tick, address(lender));
        assertGt(withdrawA, 0); 
        assertEq(withdrawB, 0);
        uint256 balanceWETH_before = weth.balanceOf(address(lender));
        uint256 balanceWETH2_before = weth2.balanceOf(address(lender));
        //Action
        kommodoPool.withdraw(next_tick, address(lender), withdrawA, withdrawB);
        vm.stopPrank();
        //Post check
        uint256 balanceWETH_after = weth.balanceOf(address(lender));
        uint256 balanceWETH2_after = weth2.balanceOf(address(lender));
        assertEq(withdrawA, balanceWETH2_after - balanceWETH2_before);
        assertEq(withdrawB, balanceWETH_after - balanceWETH_before);
    }
    function test_fuzz_kommodo_open(uint128 depositAmount) public {  
        //Pre conditions
        vm.startPrank(lender);
        depositAmount = uint128(bound(depositAmount, 1e6, 100 ether));  //start 10 for rounding 0 
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick, 
            liquidity: depositAmount,                          
            amountMaxA: depositAmount,                   
            amountMaxB: 0                                    
        });
        kommodoPool.provide(provideParams);
        //Pre check 
        (uint128 liqPool_before, , , ) = kommodoPool.assets(next_tick);    
        (uint128 liqPosition_before, , , , ) = kommodoPool.lender(next_tick, address(lender));
        assertNotEq(liqPool_before, 0);
        assertNotEq(liqPosition_before, 0);
        assertEq(liqPosition_before, depositAmount);
        assertEq(liqPool_before, liqPosition_before);
        vm.stopPrank();
        uint256 balanceWETH_before = weth.balanceOf(address(borrower));
        uint256 balanceWETH2_before = weth2.balanceOf(address(borrower));
        //Action
        vm.startPrank(borrower);
        uint128 collateralAmount =  depositAmount / 3 + 10;
        uint128 borrowLiquidity = liqPool_before / 4;
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: false,
            tickBor: next_tick,
            liquidityBor: borrowLiquidity,
            borAMin: 0,
            borBMin: 0,
            colAmount: collateralAmount,  // borrow amount = 1/4 * depositamount && collateral amount = 1/3 * depositamount (+ 10 margin for rounding cases)
            interest: 1
        });
        kommodoPool.open(open_params);
        vm.stopPrank();
        //Post check
        {
        (uint128 liqPool_after, uint128 lockPool_after, , ) = kommodoPool.assets(next_tick);    
        assertNotEq(liqPool_after, 0);
        assertEq(borrowLiquidity, lockPool_after);
        }
        {
        (uint128 liquidity_borrower, uint128 collater_borrower, uint128 interest, uint256 start) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        assertEq(borrowLiquidity, liquidity_borrower);
        assertEq(collateralAmount, collater_borrower);
        assertEq(1, interest);
        assertEq(block.timestamp, start);
        }
        {
        uint256 balanceWETH_after = weth.balanceOf(address(borrower));
        uint256 balanceWETH2_after = weth2.balanceOf(address(borrower));
        assertNotEq(0, balanceWETH2_after - balanceWETH2_before);
        uint256 fee = kommodoPool.getFee(collateralAmount);
        uint256 interest_fee = fee+1;
        assertEq(collateralAmount + interest_fee, balanceWETH_before - balanceWETH_after);  
        }
    }
    function test_fuzz_kommodo_close(uint128 depositAmount) public {  
        //Pre conditions
        vm.startPrank(lender);
        depositAmount = uint128(bound(depositAmount, 1e6, 100 ether));  
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick,                           
            liquidity: depositAmount,                          
            amountMaxA: depositAmount,                   
            amountMaxB: 0             
        });
        kommodoPool.provide(provideParams);
        vm.stopPrank();
        vm.startPrank(borrower);
        (uint128 liqPool_before, , , ) = kommodoPool.assets(next_tick); 
        assertEq(liqPool_before, depositAmount);   
        uint128 borrowLiquidity = liqPool_before / 4;
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: false,
            tickBor: next_tick,
            liquidityBor: borrowLiquidity,
            borAMin: 0,
            borBMin: 0,
            colAmount: depositAmount / 3 + 10,  // borrow amount = 1/4 * depositamount && collateral amount = 1/3 * depositamount (+ 10 margin for rounding cases)
            interest: 1
        });
        kommodoPool.open(open_params);
        //Pre check
        (uint128 liquidity_borrower_pre, uint128 collater_borrower_pre , , ) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        {
        (uint128 liqPool_after, uint128 lockPool_after, , ) = kommodoPool.assets(next_tick);    
        assertNotEq(liqPool_after, 0);
        assertEq(borrowLiquidity, lockPool_after);
        assertEq(borrowLiquidity, liquidity_borrower_pre);  
        assertNotEq(collater_borrower_pre, 0);  
        }
        uint256 balanceWETH_before = weth.balanceOf(address(borrower));
        uint256 balanceWETH2_before = weth2.balanceOf(address(borrower));
        //Action
        {
        IKommodo.CloseParams memory close_params = IKommodo.CloseParams({
            token0: false,
            owner: address(borrower),
            tickBor: next_tick,
            borAMax: type(uint128).max,
            borBMax: type(uint128).max
        });
        kommodoPool.close(close_params);
        }

        vm.stopPrank();
        //Post check
        {
        (uint128 liqPool_after, uint128 lockPool_after, , ) = kommodoPool.assets(next_tick);    
        assertNotEq(liqPool_after, 0);
        assertEq(lockPool_after, 0);
        }
        {
        (uint128 liquidity_borrower_post, uint128 collater_borrower_post, uint128 interest, uint256 start) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        assertEq(liquidity_borrower_post, 0);
        assertEq(collater_borrower_post, 0);
        assertEq(interest, 0);
        assertEq(start, 0);
        } 
        uint256 balanceWETH_after = weth.balanceOf(address(borrower));
        uint256 balanceWETH2_after = weth2.balanceOf(address(borrower));
        assertNotEq(0, balanceWETH2_before - balanceWETH2_after);
        assertEq(collater_borrower_pre + 1, balanceWETH_after -  balanceWETH_before);  //+1 is interest returned
    }
    function test_fuzz_kommodo_adjust(uint128 depositAmount) public { 
        //Pre conditions
        vm.startPrank(lender);
        depositAmount = uint128(bound(depositAmount, 1e6, 100 ether));  
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick,                           
            liquidity: depositAmount,                          
            amountMaxA: depositAmount,                   
            amountMaxB: 0     
        });
        kommodoPool.provide(provideParams);
        vm.stopPrank();
        vm.startPrank(borrower);
        (uint128 liqPool_before, , , ) = kommodoPool.assets(next_tick);   
        assertEq(liqPool_before, depositAmount);    
        uint128 borrowLiquidity = liqPool_before / 4;
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: false,
            tickBor: next_tick,
            liquidityBor: borrowLiquidity,
            borAMin: 0,
            borBMin: 0,
            colAmount: depositAmount / 3 + 10,  // borrow amount = 1/4 * depositamount && collateral amount = 1/3 * depositamount (+ 10 margin for rounding cases)
            interest: 1
        });
        kommodoPool.open(open_params);
        //Pre check
        {
        (uint128 liqPool_after, uint128 lockPool_after, , ) = kommodoPool.assets(next_tick);    
        assertNotEq(liqPool_after, 0);
        assertEq(borrowLiquidity, lockPool_after);
        (uint128 liquidity_borrower, , , ) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        assertEq(borrowLiquidity, liquidity_borrower);  
        }
        uint256 balanceWETH_before = weth.balanceOf(address(borrower));
        uint256 balanceWETH2_before = weth2.balanceOf(address(borrower));
        //Action
        IKommodo.AdjustParams memory adjust_params = IKommodo.AdjustParams({
            token0: false,
            tickBor: next_tick, 
            liquidityBor: 1,
            borAMax: type(uint128).max,
            borBMax: type(uint128).max,
            amountCol: 2,
            interest: 1
        });
        kommodoPool.adjust(adjust_params);
        vm.stopPrank();
        //Post check
        {
        (uint128 liqPool_after, uint128 lockPool_after, , ) = kommodoPool.assets(next_tick);    
        assertNotEq(liqPool_after, 0);
        assertEq(borrowLiquidity - 1, lockPool_after);
        }
        {
        uint128 new_col = depositAmount / 3 + 10 - 2;
        (uint128 liquidity_borrower, uint128 collater_borrower, uint128 interest, uint256 start) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        assertEq(borrowLiquidity - 1, liquidity_borrower);
        assertEq(new_col, collater_borrower);
        assertEq(2, interest);
        assertEq(block.timestamp, start);
        }
        uint256 balanceWETH_after = weth.balanceOf(address(borrower));
        uint256 balanceWETH2_after = weth2.balanceOf(address(borrower));
        assertNotEq(0, balanceWETH2_before - balanceWETH2_after);
        assertEq(2 -1, balanceWETH_after -  balanceWETH_before);  //2 collateral withdraw - 1 interest deposit
    }
    function test_fuzz_kommodo_setInterest(uint128 depositAmount) public {  
        //Pre conditions
        vm.startPrank(lender);
        depositAmount = uint128(bound(depositAmount, 1e6, 100 ether));  
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick,                           
            liquidity: depositAmount,                          
            amountMaxA: depositAmount,                   
            amountMaxB: 0         
        });
        kommodoPool.provide(provideParams);
        vm.stopPrank();
        vm.startPrank(borrower);
        (uint128 liqPool_before, , , ) = kommodoPool.assets(next_tick);
        assertEq(liqPool_before, depositAmount);       
        uint128 borrowLiquidity = liqPool_before / 4;
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: false,
            tickBor: next_tick,
            liquidityBor: borrowLiquidity,
            borAMin: 0,
            borBMin: 0,
            colAmount: depositAmount / 3 + 10,  // borrow amount = 1/4 * depositamount && collateral amount = 1/3 * depositamount (+ 10 margin for rounding cases)
            interest: 1
        });
        kommodoPool.open(open_params);
        //Pre check
        {
        (uint128 liqPool_after, uint128 lockPool_after, , ) = kommodoPool.assets(next_tick);    
        assertNotEq(liqPool_after, 0);
        assertEq(borrowLiquidity, lockPool_after);
        (uint128 liquidity_borrower, , , ) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        assertEq(borrowLiquidity, liquidity_borrower);  
        }
        uint256 balanceWETH_before = weth.balanceOf(address(borrower));
        //Action - increase interest
        kommodoPool.setInterest(false, next_tick, 10);
        (, , uint128 interest_increase, ) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        uint256 balanceWETH_after_increase = weth.balanceOf(address(borrower));
        //Action decrease interest
        kommodoPool.setInterest(false, next_tick, -5);
        (, , uint128 interest_decrease, ) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        uint256 balanceWETH_after_decrease = weth.balanceOf(address(borrower));
        //Post check
        assertEq(interest_increase, 11);   
        assertEq(10, balanceWETH_before - balanceWETH_after_increase);  //10 interest deposit
        assertEq(interest_decrease, 6);
        assertEq(5, balanceWETH_after_decrease - balanceWETH_after_increase);  //5 interest withdraw
    }
    function test_fuzz_kommodo_borrow_interest_withdraw(uint128 depositAmount) public {  
        //Pre conditions
        vm.startPrank(lender);
        depositAmount = uint128(bound(depositAmount, 1e6, 100 ether));  //start 10000 because of rounding withdraw amount
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick,                           
            liquidity: depositAmount,                          
            amountMaxA: depositAmount,                   
            amountMaxB: 0      
        });
        kommodoPool.provide(provideParams);
        vm.stopPrank();
        vm.startPrank(borrower);
        {
        (, , uint256 feeGrowth0X128, uint256 feeGrowth1X128, ) = kommodoPool.lender(next_tick, address(lender));
        assertEq(feeGrowth0X128, 0);
        assertEq(feeGrowth1X128, 0);
        }
        (uint128 liqPool_before, , uint256 feeGrowth0X128_assets, uint256 feeGrowth1X128_assets) = kommodoPool.assets(next_tick);
        assertEq(liqPool_before, depositAmount);    
        assertEq(feeGrowth0X128_assets, 0);
        assertEq(feeGrowth1X128_assets, 0);
        uint128 borrowLiquidity = liqPool_before / 4;
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: false,
            tickBor: next_tick,
            liquidityBor: borrowLiquidity,
            borAMin: 0,
            borBMin: 0,
            colAmount: depositAmount / 3 + 10,  // borrow amount = 1/4 * depositamount && collateral amount = 1/3 * depositamount (+ 10 margin for rounding cases)
            interest: 1
        });
        kommodoPool.open(open_params);
        //Pre check
        {
        (uint128 liqPool_after, uint128 lockPool_after, uint256 feeGrowth0X128_assets_a, uint256 feeGrowth1X128_assets_a) = kommodoPool.assets(next_tick);    
        assertNotEq(liqPool_after, 0);
        assertEq(borrowLiquidity, lockPool_after);
        assertEq(feeGrowth0X128_assets_a, 0);
        assertNotEq(feeGrowth1X128_assets_a, 0);
        (uint128 liquidity_borrower, , , ) = kommodoPool.borrower(keccak256(abi.encode(borrower, next_tick, false)));
        assertEq(borrowLiquidity, liquidity_borrower);  
        }
        vm.stopPrank();  
        vm.startPrank(lender);
        kommodoPool.withdraw(next_tick, address(lender), 0, 0);
        {
        (, , uint256 feeGrowth0X128_after, uint256 feeGrowth1X128_after, ) = kommodoPool.lender(next_tick, address(lender));
        (uint128 withdrawA, uint128 withdrawB) = kommodoPool.withdraws(next_tick, address(lender));
        assertEq(feeGrowth0X128_after, 0);
        assertNotEq(feeGrowth1X128_after, 0);
        assertEq(withdrawA, 0);
        assertNotEq(withdrawB, 0);
        }
        uint256 balanceWETH_before = weth.balanceOf(address(lender));
        uint256 balanceWETH2_before = weth2.balanceOf(address(lender));
        //Action
        kommodoPool.withdraw(next_tick, address(lender), 0, 100 ether);
        // Postconditions 
        uint256 balanceWETH_after = weth.balanceOf(address(lender));
        uint256 balanceWETH2_after = weth2.balanceOf(address(lender));
        assertGt(balanceWETH_after - balanceWETH_before, 0);
        assertEq(balanceWETH2_after - balanceWETH2_before, 0);
    }  
    function test_fuzz_kommodo_swap_fee_withdraw(int256 depositAmount) public {  
        //Pre conditions
        vm.startPrank(lender);
        depositAmount = int256(bound(depositAmount, 1e6, 100 ether));  //start 1 ether because of rounding withdraw low liquidity
        weth.deposit{value: 100 ether}();
        weth2.deposit{value: 100 ether}();
        weth.transfer(address(mockRouter), 100 ether);
        weth2.transfer(address(mockRouter), 100 ether);
        (, int24 tick, , , , , ) = uniPool.slot0();
        int24 spacing = uniPool.tickSpacing();
        int24 next_tick = tick + spacing;
        IKommodo.ProvideParams memory provideParams = IKommodo.ProvideParams({
            tickLower: next_tick,
            liquidity: uint128(uint256(depositAmount)),                          
            amountMaxA: uint128(uint256(depositAmount)),                   
            amountMaxB: 0                               
        });
        kommodoPool.provide(provideParams);
        {        
        uint256 feegrowth0Before = uniPool.feeGrowthGlobal0X128();
        uint256 feegrowth1Before = uniPool.feeGrowthGlobal1X128();
        (, , uint256 feeGrowth0X128_lb, uint256 feeGrowth1X128_lb, ) = kommodoPool.lender(next_tick, address(lender));
        (uint128 withdrawA, uint128 withdrawB) = kommodoPool.withdraws(next_tick, address(lender));
        assertEq(feegrowth0Before, 0);
        assertEq(feegrowth1Before, 0);
        assertEq(feeGrowth0X128_lb, 0);
        assertEq(feeGrowth1X128_lb, 0);
        assertEq(withdrawA, 0);
        assertEq(withdrawB, 0);
        }
        //Action
        {
        uint160 sqrt = 1461446703485210103287273052203988822378723970341;
        mockRouter.swap(address(mockRouter), false, depositAmount, sqrt, "");
        }
        kommodoPool.withdraw(next_tick, address(lender), 0, 0);
        (uint128 withdrawA_a, uint128 withdrawB_a) = kommodoPool.withdraws(next_tick, address(lender));   
        // Postconditions 
        {
        uint256 balanceB_before = weth.balanceOf(address(lender));
        kommodoPool.withdraw(next_tick, address(lender), type(uint128).max, type(uint128).max);
        uint256 balanceB_after = weth.balanceOf(address(lender));   
        assertEq(balanceB_after - balanceB_before, withdrawB_a);
        }
        vm.stopPrank();  
        uint256 feegrowth0After = uniPool.feeGrowthGlobal0X128();
        uint256 feegrowth1After = uniPool.feeGrowthGlobal1X128();
        (uint128 liquidity_kom, , uint256 feeGrowth0X128_la, uint256 feeGrowth1X128_la, ) = kommodoPool.lender(next_tick, address(lender));
        assertEq(feegrowth0After, 0);
        assertNotEq(feegrowth1After, 0);
        assertEq(feeGrowth0X128_la, 0);
        assertEq(withdrawA_a, 0);
        bytes32 positionKey = PositionKey.compute(address(kommodoPool), next_tick, next_tick+spacing);
        (uint128 liquidity_uni, , uint256 feeGrowthInside1LastX128, , ) = uniPool.positions(positionKey);
        (, , , uint256 feeGrowth1X128_aa) = kommodoPool.assets(next_tick);
        assertEq(liquidity_uni, liquidity_kom);
        //max size based on 
        uint256 expectedAmount_uni = FullMath.mulDiv(feegrowth1After, liquidity_uni, type(uint128).max);
        uint256 expectedFeegrowt_kommodo = FullMath.mulDiv(expectedAmount_uni, type(uint128).max, liquidity_kom);
        uint256 expectedAmount_kommodo = FullMath.mulDiv(expectedFeegrowt_kommodo, liquidity_uni, type(uint128).max);
        assertEq(feegrowth1After, feeGrowthInside1LastX128);
        assertEq(feeGrowth1X128_la, feeGrowth1X128_aa);
        assertEq(feeGrowth1X128_la, expectedFeegrowt_kommodo);
        assertEq(withdrawB_a, expectedAmount_kommodo);
    }
    //solvency guarantee fuzz
    function test_kommodo_solvency_guarantee_col0(
        uint128 collateralAmount,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioX96
    ) public pure {   
        // Preconditions
        vm.assume(collateralAmount > 0);
        vm.assume(sqrtRatioAX96 > 4295128739);
        vm.assume(sqrtRatioAX96 < 1461446703485210103287273052203988822378723970342 / 2 -1);
        uint160 sqrtRatioBX96 = 2 * sqrtRatioAX96;
        vm.assume(sqrtRatioBX96 < 1461446703485210103287273052203988822378723970342);
        vm.assume(sqrtRatioX96 > 4295128739);
        vm.assume(sqrtRatioX96 < 1461446703485210103287273052203988822378723970342);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, FixedPoint96.Q96);
        uint256 temp = FullMath.mulDiv(collateralAmount, intermediate, sqrtRatioBX96 - sqrtRatioAX96);
        vm.assume(temp < type(uint128).max); //limit input to max uint128 output
        // Action: solvency guarantee for collateral 0 - calc borrow value as amount0 
        uint128 liquidity0 = LiquidityAmounts.getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, collateralAmount); 
        vm.assume(liquidity0 > 0);
        (uint256 amount0_col0, uint256 amount1_col0) = LiquidityAmounts.getAmountsForLiquidity(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, liquidity0);
        uint256 amount1_value0  = FullMath.mulDiv(FullMath.mulDiv(amount1_col0, 1 << 96, sqrtRatioX96), 1 << 96, sqrtRatioX96);        
        // Postconditions 
        assertGe(collateralAmount, amount0_col0 + amount1_value0); // for any collateral amount = collateral_value >= borrow_value
    }
    function test_kommodo_solvency_guarantee_col1(
        uint128 collateralAmount,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioX96
    ) public pure {   
        // Preconditions
        vm.assume(collateralAmount > 0);
        vm.assume(sqrtRatioAX96 > 4295128739);
        vm.assume(sqrtRatioAX96 < 1461446703485210103287273052203988822378723970342 / 2 -1);
        uint160 sqrtRatioBX96 = 2 * sqrtRatioAX96;
        vm.assume(sqrtRatioBX96 < 1461446703485210103287273052203988822378723970342);
        vm.assume(sqrtRatioX96 > 4295128739);
        vm.assume(sqrtRatioX96 < 1461446703485210103287273052203988822378723970342);
        uint256 intermediate = FullMath.mulDiv(collateralAmount, FixedPoint96.Q96, sqrtRatioBX96 - sqrtRatioAX96);
        vm.assume(intermediate < type(uint128).max); //limit input to max uint128 output
        // Action: solvency guarantee for collateral 1 - calc borrow value as amount1 
        uint128 liquidity1 = LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, collateralAmount); 
        vm.assume(liquidity1 > 0);
        (uint256 amount0_col1, uint256 amount1_col1) = LiquidityAmounts.getAmountsForLiquidity(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, liquidity1);
        uint256 amount0_value1  = FullMath.mulDiv(FullMath.mulDiv(amount0_col1, sqrtRatioX96, 1 << 96), sqrtRatioX96, 1 << 96);      
        // Postconditions 
        assertGe(collateralAmount, amount0_value1 + amount1_col1); // for any collateral amount = collateral_value >= borrow_value
    }
}