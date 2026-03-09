// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';

import './interfaces/IKommodoFactory.sol';
import './interfaces/IKommodo.sol';
import './libraries/FullMath.sol';

contract NonfungibleLendManager is ERC721Enumerable {

    IKommodoFactory public factory;
    uint256 private nextId = 1;

    struct MintParams { 
        address assetA;
        address assetB;
        uint24 poolFee;
        int24 tickLower; 
        uint128 amountA; 
        uint128 amountB;     
    } 

    struct ProvideParams { 
        uint256 tokenId;
        address assetA;
        address assetB;
        uint128 amountA; 
        uint128 amountB;     
    } 

    struct TakeParams { 
        uint256 tokenId;
        uint128 liquidity; 
        uint128 amountMinA; 
        uint128 amountMinB; 
        address recipient;   
    }

    struct WithdrawParams { 
        uint256 tokenId;
        uint128 amountA; 
        uint128 amountB;  
        address recipient; 
    }

    struct Position { 
        address pool;
        int24 tickLower;
        uint128 locked;
        uint128 liquidity;
        uint256 blocknumber;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint128 withdrawA;
        uint128 withdrawB; 
    }  

    mapping(uint256 => Position) public position;

    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), 'Not approved');
        _;
    }

    constructor(address _factory) ERC721("Kommodo Lender Position", "KLP") {
        require(address(_factory) != address(0), "constructor: zero factory");
        factory = IKommodoFactory(_factory);
    }

    //Approve kommodo pool
    function poolApprove(address tokenA, address tokenB, uint24 poolFee) public {
        address pool = factory.kommodo(tokenA, tokenB, poolFee);
        IERC20(tokenA).approve(pool, type(uint256).max);
        IERC20(tokenB).approve(pool, type(uint256).max);
    }

    //Deploy and approve kommodo pool
    function deploy(address token0, address token1, uint24 poolFee) public {
        factory.createKommodo(token0, token1, poolFee);
        poolApprove(token0, token1, poolFee);
    }

    //Mint new NFT for kommodo pool lender position
    function mint(MintParams calldata params) public {
        IKommodo pool = IKommodo(factory.kommodo(params.assetA, params.assetB, params.poolFee));
        //Transfer amounts IN
        TransferHelper.safeTransferFrom(params.assetA, msg.sender, address(this), params.amountA);
        TransferHelper.safeTransferFrom(params.assetB, msg.sender, address(this), params.amountB);
        //Add liquidity to pool
        (uint128 pre_liquidity, , , , ) = pool.lender(params.tickLower, address(this));
        pool.provide(
            IKommodo.ProvideParams({
                tickLower: params.tickLower,
                amountA: params.amountA,
                amountB: params.amountB
            })
        );
        //Mint NFT
        uint256 tokenId;
        _safeMint(msg.sender, tokenId = nextId++);
        //Store position
        (   uint128 post_liquidity, , 
            uint256 feeGrowth0X128, 
            uint256 feeGrowth1X128, 
            uint256 blocknumber
        ) = pool.lender(params.tickLower, address(this));
        position[tokenId] = Position(
            address(pool), 
            params.tickLower, 
            post_liquidity - pre_liquidity,
            post_liquidity - pre_liquidity,
            blocknumber,
            feeGrowth0X128,
            feeGrowth1X128,
            0,
            0
        );
        //Transfer RETURN amounts
        TransferHelper.safeTransfer(params.assetA, msg.sender, IERC20(params.assetA).balanceOf(address(this)));
        TransferHelper.safeTransfer(params.assetB, msg.sender, IERC20(params.assetB).balanceOf(address(this)));
    }

    //Add liquidity to NFT lender position
    function provide(ProvideParams calldata params) public {
        require(params.tokenId != 0, "provide: invalid Id");
        Position storage _position = position[params.tokenId];
        IKommodo pool = IKommodo(_position.pool);
        //Transfer amounts IN
        TransferHelper.safeTransferFrom(params.assetA, msg.sender, address(this), params.amountA);
        TransferHelper.safeTransferFrom(params.assetB, msg.sender, address(this), params.amountB);
        //Add liquidity to pool
        (uint128 pre_liquidity, , , ) = pool.assets(_position.tickLower);
        pool.provide(
            IKommodo.ProvideParams({
                tickLower: _position.tickLower,
                amountA: params.amountA,
                amountB: params.amountB
            })
        );
        //Store position - notice: overflow is safe for feegrowth
        (   uint128 post_liquidity, , 
            uint256 feeGrowth0X128, 
            uint256 feeGrowth1X128
        ) = pool.assets(_position.tickLower);
        uint128 delta = post_liquidity - pre_liquidity;  
        uint256 delta_feeGrowth0X128;
        uint256 delta_feeGrowth1X128;   
        unchecked{delta_feeGrowth0X128 = feeGrowth0X128 - _position.feeGrowth0X128;}
        unchecked{delta_feeGrowth1X128 = feeGrowth1X128 - _position.feeGrowth1X128;}
        _position.withdrawA += uint128(
            FullMath.mulDiv(
                delta_feeGrowth0X128,
                _position.liquidity,
                FixedPoint128.Q128
            )
        );
        _position.withdrawB += uint128(
            FullMath.mulDiv(
                delta_feeGrowth1X128,
                _position.liquidity,
                FixedPoint128.Q128
            )
        );
        _position.locked = position[params.tokenId].blocknumber < block.number ? delta : position[params.tokenId].locked + delta;
        _position.blocknumber = block.number;
        _position.liquidity += delta;
        _position.feeGrowth0X128 = feeGrowth0X128;
        _position.feeGrowth1X128 = feeGrowth1X128;
        //Transfer RETURN amounts
        TransferHelper.safeTransfer(params.assetA, msg.sender, IERC20(params.assetA).balanceOf(address(this)));
        TransferHelper.safeTransfer(params.assetB, msg.sender, IERC20(params.assetB).balanceOf(address(this)));
    }

    function take(TakeParams calldata params) public isAuthorizedForToken(params.tokenId) {
        Position storage _position = position[params.tokenId];
        IKommodo pool = IKommodo(_position.pool);
        //Remove liquidity from pool
        (uint256 amountA, uint256 amountB) = pool.take(
            IKommodo.TakeParams({
            tickLower: _position.tickLower,
            liquidity: params.liquidity,
            amountMinA: params.amountMinA,
            amountMinB: params.amountMinB
        }));      
        //Store position - notice: overflow is safe for feegrowth
        (   , ,   
            uint256 feeGrowth0X128, 
            uint256 feeGrowth1X128
        ) = pool.assets(_position.tickLower);
        uint256 delta_feeGrowth0X128;
        uint256 delta_feeGrowth1X128;   
        unchecked{delta_feeGrowth0X128 = feeGrowth0X128 - _position.feeGrowth0X128;}
        unchecked{delta_feeGrowth1X128 = feeGrowth1X128 - _position.feeGrowth1X128;}
        _position.withdrawA += 
            uint128(amountA) +
            uint128(
                FullMath.mulDiv(
                    delta_feeGrowth0X128,
                    _position.liquidity,
                    FixedPoint128.Q128
                )
            );
        _position.withdrawB += 
            uint128(amountB) +
            uint128(
                FullMath.mulDiv(
                    delta_feeGrowth1X128,
                    _position.liquidity,
                    FixedPoint128.Q128
                )
            );
        _position.locked = _position.blocknumber < block.number ? 0 : _position.locked;
        require(_position.liquidity - _position.locked >= params.liquidity, "take: liquidity locked");
        _position.blocknumber = block.number;
        _position.liquidity -= params.liquidity;
        _position.feeGrowth0X128 = feeGrowth0X128;
        _position.feeGrowth1X128 = feeGrowth1X128;
        //Withdraw amounts 
        withdraw(WithdrawParams({
            tokenId: params.tokenId, 
            amountA: type(uint128).max, 
            amountB: type(uint128).max, 
            recipient: params.recipient
        }));
    }

    function withdraw(WithdrawParams memory params) public isAuthorizedForToken(params.tokenId){
        Position storage _position = position[params.tokenId];
        IKommodo pool = IKommodo(_position.pool);
        require(params.recipient != address(0), "withdraw: zero recipient");
        //Update position - notice: overflow is safe for feegrowth
        if(_position.liquidity > 0){
            (   , ,   
                uint256 feeGrowth0X128, 
                uint256 feeGrowth1X128 
                
            ) = pool.assets(_position.tickLower);
            uint256 delta_feeGrowth0X128;
            uint256 delta_feeGrowth1X128;   
            unchecked{delta_feeGrowth0X128 = feeGrowth0X128 - _position.feeGrowth0X128;}
            unchecked{delta_feeGrowth1X128 = feeGrowth1X128 - _position.feeGrowth1X128;}
            _position.withdrawA += uint128(
                FullMath.mulDiv(
                    delta_feeGrowth0X128,
                    _position.liquidity,
                    FixedPoint128.Q128
                )
            );
            _position.withdrawB += uint128(
                FullMath.mulDiv(
                    delta_feeGrowth1X128,
                    _position.liquidity,
                    FixedPoint128.Q128
                )
            );
            _position.feeGrowth0X128 = feeGrowth0X128;
            _position.feeGrowth1X128 = feeGrowth1X128;
        }
        //Withdraw amounts from position
        uint128 withdrawA = _position.withdrawA > params.amountA ? params.amountA : _position.withdrawA;
        uint128 withdrawB = _position.withdrawB > params.amountB ? params.amountB : _position.withdrawB;
        _position.withdrawA -= withdrawA;
        _position.withdrawB -= withdrawB;
        pool.withdraw(
            _position.tickLower,
            params.recipient,
            withdrawA,
            withdrawB
        );  
    }

    function burn(uint256 tokenId) public isAuthorizedForToken(tokenId){
        Position storage _position = position[tokenId];
        require(_position.blocknumber != 0, "burn: no position");
        require(_position.liquidity == 0 && _position.withdrawA == 0 && _position.withdrawB == 0, 'burn: not empty');
        delete position[tokenId];
        _burn(tokenId);
    }
}