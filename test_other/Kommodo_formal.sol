pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import '../contracts/Kommodo.sol';
import '../contracts/interfaces/IKommodo.sol';

import './MockUniPool.sol';
import '../contracts/test/Token.sol';

contract KommodoTestFormal is Test {
    address mockUniPool;
    Kommodo kommodo;

    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;
    int24 constant TICKSPACING = 10;
    uint24 constant FEE = 500;

    address TOKEN0 = address(0x1000);
    address TOKEN1 = address(0x2000);
    address constant UNI_FACTORY = address(0x3000);

    function setUp() public {
        //Deploy mock uniswap pool
        bytes32 salt = keccak256(abi.encode(TOKEN0, TOKEN1, FEE));
        bytes32 POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
        address MockUniswap = address(uint160(uint256(
            keccak256(abi.encodePacked(hex"ff", UNI_FACTORY, salt, POOL_INIT_CODE_HASH))
        )));
        mockUniPool = MockUniswap;
        vm.etch(MockUniswap, type(MockUniPool).runtimeCode);
        assertGt(MockUniswap.code.length, 0);

        //Deploy token
        vm.etch(TOKEN0, type(Token).runtimeCode);
        vm.etch(TOKEN1, type(Token).runtimeCode);

        //Deploy kommodo pool
        IKommodo.CreateParams memory create_params = IKommodo.CreateParams({
            factory: UNI_FACTORY,
            tokenA: TOKEN0,
            tokenB: TOKEN1,
            tickSpacing: TICKSPACING,
            fee: 500,
            multiplier: 5
        });
        kommodo = new Kommodo(create_params);
    } 
    function check_kommodo_lender_provide(
        uint128 amountA,
        uint128 amountB
    ) public {   
        // Preconditions: limit to 3 ticks
        vm.assume(amountA > 0 && amountB == 0 || amountA == 0 && amountB > 0);
        int24 min_tick = -600000;
        int24 max_tick = 600000;
        int24[3] memory allowed = [min_tick, 0+TICKSPACING, max_tick];
        int24 tickLower = allowed[uint256(bound(int24(0), 0, 2))];
        (uint128 liquidity_provide_lender_before, , , ) = kommodo.assets(tickLower);
        (uint128 liquidity_provide_before, , , , uint256 blocknumber_provide_before) = kommodo.lender(tickLower, address(this));
        assertEq(liquidity_provide_before, 0); 
        assertEq(liquidity_provide_lender_before, 0); 
        assertEq(blocknumber_provide_before, 0); 
        // Action: provide
        IKommodo.ProvideParams memory provide_params = IKommodo.ProvideParams({
            tickLower: tickLower,
            liquidity: amountA + amountB,                          
            amountMaxA: amountA,                   
            amountMaxB: amountB      
        });
        kommodo.provide(provide_params);
        // Postconditions
        (uint128 liquidity_provide_after, , , ) = kommodo.assets(tickLower);
        (uint128 liquidity_provide_lender_after, uint128 locked_provide_lender_after, , , uint256 blocknumber_provide_after) = kommodo.lender(tickLower, address(this));
        assertNotEq(liquidity_provide_after, 0); 
        assertNotEq(liquidity_provide_lender_after, 0); 
        assertNotEq(blocknumber_provide_after, 0); 
        assertEq(amountA + amountB, liquidity_provide_lender_after);
        assertEq(liquidity_provide_after, liquidity_provide_lender_after); 
        assertEq(locked_provide_lender_after, liquidity_provide_lender_after); 
    }
    function check_kommodo_lender_take(
        uint128 amountA,
        uint128 amountB
    ) public {   
        // Preconditions: limit to 3 ticks
        vm.assume(amountA > 0 && amountB == 0 || amountA == 0 && amountB > 0);
        int24 min_tick = -600000;
        int24 max_tick = 600000;
        int24[3] memory allowed = [min_tick, 0+TICKSPACING, max_tick];
        int24 tickLower = allowed[uint256(bound(int24(0), 0, 2))];
        IKommodo.ProvideParams memory provide_params = IKommodo.ProvideParams({
            tickLower: tickLower,
            liquidity: amountA + amountB,                          
            amountMaxA: amountA,                   
            amountMaxB: amountB  
        });
        kommodo.provide(provide_params);
        (uint128 liquidity_take_before, , , ) = kommodo.assets(tickLower);
        (uint128 liquidity_take_lender_before, uint128 locked_take_lender_before, , , uint256 blocknumber_take_before) = kommodo.lender(tickLower, address(this));
        vm.assume(liquidity_take_before > 0);
        vm.assume(liquidity_take_before == liquidity_take_lender_before);
        vm.assume(locked_take_lender_before == liquidity_take_lender_before);    
        vm.assume(amountA + amountB == liquidity_take_lender_before);   
        vm.assume(block.number > 0);
        vm.assume(blocknumber_take_before == block.number);
        vm.roll(block.number + 1);
        vm.assume(blocknumber_take_before < block.number);
        // Action: take
        IKommodo.TakeParams memory take_params = IKommodo.TakeParams({
            tickLower: tickLower,
            liquidity: liquidity_take_lender_before,
            amountMinA: 0, 
            amountMinB: 0 
        });
        vm.assume(take_params.liquidity == locked_take_lender_before);
        kommodo.take(take_params);
        // Postconditions  
        (uint128 liquidity_take_after, , , ) = kommodo.assets(tickLower);
        (uint128 liquidity_take_lender_after, uint128 locked_take_lender_after, , , uint256 blocknumber_take_after) = kommodo.lender(tickLower, address(this));
        assertEq(liquidity_take_after, 0); 
        assertEq(liquidity_take_lender_after, 0); 
        assertEq(locked_take_lender_after, 0); 
        assertNotEq(blocknumber_take_after, 0); 
    }
    function check_kommodo_borrow_open(
        uint128 amountA,
        uint128 amountB
    ) public { 
        // Preconditions: limit to 3 ticks
        address lender = address(0x1);
        address borrower = address(0x2);
        vm.assume(amountA > 0 && amountB == 0 || amountA == 0 && amountB > 0);
        int24 min_tick = -600000;
        int24 max_tick = 600000;
        int24[3] memory allowed = [min_tick, 0+TICKSPACING, max_tick];
        int24 tickLower = allowed[uint256(bound(int24(0), 0, 2))];
        vm.startPrank(lender);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        IKommodo.ProvideParams memory provide_params = IKommodo.ProvideParams({
            tickLower: tickLower,
            liquidity: amountA + amountB,                          
            amountMaxA: amountA,                   
            amountMaxB: amountB  
        });
        kommodo.provide(provide_params);
        (uint128 liquidity_open_before, uint128 locked_open_before, , ) = kommodo.assets(tickLower);
        vm.assume(liquidity_open_before > 0);
        vm.assume(locked_open_before == 0);
        vm.assume(amountA + amountB == liquidity_open_before);   
        (uint128 liquidity_borrower_open_before, , , ) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        vm.assume(liquidity_borrower_open_before == 0);
        vm.stopPrank();
        // Action: borrow 
        vm.startPrank(borrower);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: true,
            tickBor: tickLower,
            liquidityBor: liquidity_open_before,
            borAMin: 0,
            borBMin: 0,
            colAmount: amountA + amountB,
            interest: 100
        });
        kommodo.open(open_params);
        vm.stopPrank();
        // Postconditions  
        (uint128 liquidity_borrower_open_after, , uint128 interest_open_after, uint256 start_open_after) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        (uint128 liquidity_open_after, uint128 locked_open_after, , ) = kommodo.assets(tickLower);
        assertEq(liquidity_open_after, liquidity_open_before); 
        assertEq(liquidity_open_after, locked_open_after); 
        assertEq(liquidity_open_after, liquidity_borrower_open_after); 
        assertEq(interest_open_after, 100); 
        assertNotEq(start_open_after, 0); 
    }
    function check_kommodo_borrow_close(
        uint128 liquidity
    ) public {
        // Preconditions: limit to 3 ticks
        address lender = address(0x1);
        address borrower = address(0x2);
        vm.assume(liquidity > 0);
        int24 min_tick = -600000;
        int24 max_tick = 600000;
        int24[3] memory allowed = [min_tick, 0+TICKSPACING, max_tick];
        int24 tickLower = allowed[uint256(bound(int24(0), 0, 2))];
        vm.startPrank(lender);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        IKommodo.ProvideParams memory provide_params = IKommodo.ProvideParams({
            tickLower: tickLower,
            liquidity: type(uint128).max,                          
            amountMaxA: type(uint128).max,                   
            amountMaxB: type(uint128).max  
        });
        kommodo.provide(provide_params);
        (uint128 liquidity_open_before, uint128 locked_open_before, , ) = kommodo.assets(tickLower);
        vm.assume(liquidity_open_before > 0);
        vm.assume(locked_open_before == 0);
        (uint128 liquidity_borrower_open_before, , , ) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        vm.assume(liquidity_borrower_open_before == 0);
        vm.stopPrank();
        vm.startPrank(borrower);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: true,
            tickBor: tickLower,
            liquidityBor: liquidity,
            borAMin: 0,
            borBMin: 0,
            colAmount: type(uint128).max / 1e6,
            interest: 100
        });
        kommodo.open(open_params);
        (uint128 liquidity_borrower_open_after, , , ) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        vm.assume(liquidity_borrower_open_after == liquidity);
        //Action: close
        {
        IKommodo.CloseParams memory close_params = IKommodo.CloseParams({
            token0: true,
            owner: borrower,
            tickBor: tickLower,
            borAMax: type(uint128).max,
            borBMax: type(uint128).max
        });
        kommodo.close(close_params); 
        }
        vm.stopPrank();
        // Postconditions  
        (uint128 liquidity_borrower_close_after, , uint128 interest_close_after, uint256 start_close_after) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        (uint128 liquidity_close_after, uint128 locked_close_after, , ) = kommodo.assets(tickLower);
        assertEq(liquidity_close_after, liquidity_open_before); 
        assertEq(locked_close_after, 0); 
        assertEq(liquidity_borrower_close_after, 0); 
        assertEq(interest_close_after, 0); 
        assertEq(start_close_after, 0); 
    }
    function check_kommodo_borrow_adjust(
        uint128 liquidity,
        uint128 liquidity_adjust
    ) public {
        // Preconditions: limit to 3 ticks
        address lender = address(0x1);
        address borrower = address(0x2);
        vm.assume(liquidity > 0);        
        int24 min_tick = -600000;
        int24 max_tick = 600000;
        int24[3] memory allowed = [min_tick, 0+TICKSPACING, max_tick];
        int24 tickLower = allowed[uint256(bound(int24(0), 0, 2))];
        vm.startPrank(lender);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        IKommodo.ProvideParams memory provide_params = IKommodo.ProvideParams({
            tickLower: tickLower,
            liquidity: type(uint128).max,                          
            amountMaxA: type(uint128).max,                   
            amountMaxB: type(uint128).max  
        });
        kommodo.provide(provide_params);
        (uint128 liquidity_open_before, uint128 locked_open_before, , ) = kommodo.assets(tickLower);
        vm.assume(liquidity_open_before > 0);
        vm.assume(locked_open_before == 0);
        {
        (uint128 liquidity_borrower_open_before, , , ) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        vm.assume(liquidity_borrower_open_before == 0);    
        }
        vm.stopPrank();
        vm.startPrank(borrower);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: true,
            tickBor: tickLower,
            liquidityBor: liquidity,
            borAMin: 0,
            borBMin: 0,
            colAmount: type(uint128).max / 1e6,
            interest: 100
        });
        kommodo.open(open_params);
        {
        (uint128 liquidity_borrower_open_after, , , ) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        vm.assume(liquidity_borrower_open_after == liquidity);         
        }
        //Action: adjust
        vm.assume(liquidity_adjust > 0); 
        vm.assume(liquidity_adjust < liquidity);         
        IKommodo.AdjustParams memory adjust_params = IKommodo.AdjustParams({
            token0: true,
            tickBor: tickLower, 
            liquidityBor: liquidity_adjust,
            borAMax: type(uint128).max,
            borBMax: type(uint128).max,
            amountCol: 1,
            interest: 90 
        });
        kommodo.adjust(adjust_params);
        vm.stopPrank();
        // Postconditions
        uint128 new_liq = liquidity - liquidity_adjust;
        (uint128 liquidity_borrower_close_after, uint128 collateral_borrower_after, , uint256 start_close_after) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        (uint128 liquidity_close_after, , , ) = kommodo.assets(tickLower);
        assertEq(liquidity_close_after, liquidity_open_before);
        assertEq(collateral_borrower_after,  type(uint128).max / 1e6 - 1);        
        assertEq(liquidity_borrower_close_after, new_liq); 
        assertNotEq(start_close_after, 0);   
    }
    function check_kommodo_feegrowth_interest(
        uint128 liquidity
    ) public {
        // Preconditions: limit to 3 ticks
        address lender = address(0x1);
        address borrower = address(0x2);
        vm.assume(liquidity > 0);
        int24 min_tick = -600000;
        int24 max_tick = 600000;
        int24[3] memory allowed = [min_tick, 0+TICKSPACING, max_tick];
        int24 tickLower = allowed[uint256(bound(int24(0), 0, 2))];
        vm.startPrank(lender);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        IKommodo.ProvideParams memory provide_params = IKommodo.ProvideParams({
            tickLower: tickLower,
            liquidity: type(uint128).max,                          
            amountMaxA: type(uint128).max,                   
            amountMaxB: type(uint128).max  
        });
        kommodo.provide(provide_params);
        {
        (uint128 liqPool_before, uint128 lockedPool_before, uint256 feeGrowth0X128_assets, uint256 feeGrowth1X128_assets) = kommodo.assets(tickLower);  
        (, , uint256 feeGrowth0X128, uint256 feeGrowth1X128, ) = kommodo.lender(tickLower, address(lender));
        (uint128 liqBorrower_before, , , ) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        vm.assume(feeGrowth0X128 == 0);
        vm.assume(feeGrowth1X128 == 0);
        vm.assume(liqPool_before > 0);
        vm.assume(lockedPool_before == 0);
        vm.assume(feeGrowth0X128_assets == 0);
        vm.assume(feeGrowth1X128_assets == 0);
        vm.assume(liqBorrower_before == 0);    
        }
        vm.stopPrank();
        vm.startPrank(borrower);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        //Action: pay fee open (borrow)
        IKommodo.OpenParams memory open_params = IKommodo.OpenParams({
            token0: false,
            tickBor: tickLower,
            liquidityBor: liquidity,
            borAMin: 0,
            borBMin: 0,
            colAmount: type(uint128).max / 1e6, 
            interest: 1
        });
        kommodo.open(open_params);
        {
        (uint128 liquidity_borrower, , , ) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, false)));
        vm.assume(liquidity_borrower > 0);  
        vm.assume(liquidity == liquidity_borrower);  
        }
        vm.stopPrank();    
        // Postconditions  
        vm.startPrank(lender);
        address _lender = address(lender);       
        kommodo.withdraw(tickLower, _lender, 0, 0);
        vm.stopPrank();      
        (uint128 withdrawA, uint128 withdrawB) = kommodo.withdraws(tickLower, _lender);
        assertEq(withdrawA, 0);     
        assertGt(withdrawB, 0);          
    }
    function check_kommodo_feegrowth_swap(
        uint128 amountA,
        uint128 amountB
    ) public {
        // Preconditions: limit to 3 ticks
        address lender = address(0x1);
        address borrower = address(0x2);
        vm.assume(amountA > 1);
        vm.assume(amountB > 1);
        int24 min_tick = -600000;
        int24 max_tick = 600000;
        int24[3] memory allowed = [min_tick, 0+TICKSPACING, max_tick];
        int24 tickLower = allowed[uint256(bound(int24(0), 0, 2))];
        vm.startPrank(lender);
        Token(TOKEN0).mint(type(uint128).max);
        Token(TOKEN1).mint(type(uint128).max);
        Token(TOKEN0).approve(address(kommodo), type(uint256).max);
        Token(TOKEN1).approve(address(kommodo), type(uint256).max);
        IKommodo.ProvideParams memory provide_params = IKommodo.ProvideParams({
            tickLower: tickLower,
            liquidity: type(uint128).max,                          
            amountMaxA: type(uint128).max,                   
            amountMaxB: type(uint128).max  
        });
        kommodo.provide(provide_params);
        {
        (uint128 liqPool_before, uint128 lockedPool_before, uint256 feeGrowth0X128_assets, uint256 feeGrowth1X128_assets) = kommodo.assets(tickLower);  
        (, , uint256 feeGrowth0X128, uint256 feeGrowth1X128, ) = kommodo.lender(tickLower, address(lender));
        (uint128 liqBorrower_before, , , ) = kommodo.borrower(keccak256(abi.encode(borrower, tickLower, true)));
        vm.assume(feeGrowth0X128 == 0);
        vm.assume(feeGrowth1X128 == 0);
        vm.assume(liqPool_before > 0);
        vm.assume(lockedPool_before == 0);
        vm.assume(feeGrowth0X128_assets == 0);
        vm.assume(feeGrowth1X128_assets == 0);
        vm.assume(liqBorrower_before == 0);    
        }
        //Action: update interest uniswap pool
        {
        (uint256 a, uint256 b) = MockUniPool(mockUniPool).collect(address(0), 0, 0, 0 ,0);
        assertEq(a,0);
        assertEq(b,0);
        }
        MockUniPool(mockUniPool).set_collect(amountA, amountB);
        {
        (uint256 c, uint256 d) = MockUniPool(mockUniPool).collect(address(0), 0, 0, 0 ,0);
        assertEq(c, amountA);
        assertEq(d, amountB);
        }
        //Postconditions 
        kommodo.withdraw(tickLower, address(lender), 0, 0);
        vm.stopPrank();
        address _lender = address(lender);
        (, , uint256 feeGrowth0X128_assets_after, uint256 feeGrowth1X128_assets_after) = kommodo.assets(tickLower); 
        (, , uint256 feeGrowth0X128_lender, uint256 feeGrowth1X128_lender, ) = kommodo.lender(tickLower, _lender); 
        assertGt(feeGrowth0X128_assets_after,0);
        assertGt(feeGrowth1X128_assets_after,0);
        assertEq(feeGrowth0X128_lender, feeGrowth0X128_assets_after);
        assertEq(feeGrowth1X128_lender, feeGrowth1X128_assets_after);
        //Notice: no check on withdraw amount, too many paths. Check indirect feegrowth change kommodo
    }
}