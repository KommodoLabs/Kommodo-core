// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

import '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';
import '@uniswap/v3-core/contracts/libraries/FixedPoint128.sol';

import './interfaces/INonfungibleLendManager.sol';
import './interfaces/IKommodoFactory.sol';
import './interfaces/IKommodo.sol';
import './libraries/FullMath.sol';

contract NonfungibleLendManager is INonfungibleLendManager, ERC721Enumerable, ReentrancyGuard {
    using SafeERC20 for IERC20; 

    /// @inheritdoc INonfungibleLendManager
    IKommodoFactory public override factory;
    /// @dev global next NFT id for minting
    uint256 private nextId = 1;

    /// @inheritdoc INonfungibleLendManager
    mapping(uint256 => Position) public override position;

    /// @dev prevents calling a function from anyone except the owner address of the token
    modifier isAuthorizedForToken(uint256 tokenId) {
        require(_isApprovedOrOwner(msg.sender, tokenId), 'Not approved');
        _;
    }

    constructor(address _factory) ERC721("Kommodo Lender Position", "KLP") {
        require(address(_factory) != address(0), "constructor: zero factory");
        factory = IKommodoFactory(_factory);
    }

    /// @inheritdoc INonfungibleLendManager
    function poolApprove(address tokenA, address tokenB, uint24 poolFee) public override {
        address pool = factory.kommodo(tokenA, tokenB, poolFee);
        require(pool != address(0), "poolApprove: zero pool");
        IERC20(tokenA).forceApprove(pool, type(uint256).max); 
        IERC20(tokenB).forceApprove(pool, type(uint256).max);
    }

    /// @inheritdoc INonfungibleLendManager
    function deploy(address token0, address token1, uint24 poolFee) public override {
        factory.createKommodo(token0, token1, poolFee);
        poolApprove(token0, token1, poolFee);
    }

    /// @inheritdoc INonfungibleLendManager
    function mint(MintParams calldata params) public override nonReentrant {
        IKommodo pool = IKommodo(factory.kommodo(params.assetA, params.assetB, params.poolFee));
        //Transfer amounts IN
        if(params.amountMaxA > 0) {TransferHelper.safeTransferFrom(params.assetA, msg.sender, address(this), params.amountMaxA);}
        if(params.amountMaxB > 0) {TransferHelper.safeTransferFrom(params.assetB, msg.sender, address(this), params.amountMaxB);}
        //Add liquidity to pool
        (uint128 pre_liquidity, , , , ) = pool.lender(params.tickLower, address(this));
        pool.provide(
            IKommodo.ProvideParams({
                tickLower: params.tickLower,
                liquidity: params.liquidity,
                amountMaxA: params.assetA < params.assetB ? params.amountMaxA : params.amountMaxB,
                amountMaxB: params.assetA < params.assetB ? params.amountMaxB : params.amountMaxA
            })
        );
        //Store position
        uint256 tokenId = nextId++;
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
        //Mint NFT
        _safeMint(msg.sender, tokenId );
        //Transfer RETURN amounts
        uint256 balanceA = IERC20(params.assetA).balanceOf(address(this));
        uint256 balanceB = IERC20(params.assetB).balanceOf(address(this));
        if(balanceA > 0) {TransferHelper.safeTransfer(params.assetA, msg.sender, balanceA);}
        if(balanceB > 0) {TransferHelper.safeTransfer(params.assetB, msg.sender, balanceB);}
    }

    /// @inheritdoc INonfungibleLendManager
    function provide(ProvideParams calldata params) public override nonReentrant {
        require(params.tokenId != 0, "provide: invalid Id");
        Position storage _position = position[params.tokenId];
        IKommodo pool = IKommodo(_position.pool);
        address assetA = address(pool.tokenA());
        address assetB = address(pool.tokenB());
        //Transfer amounts IN
        if(params.amountMaxA > 0) {TransferHelper.safeTransferFrom(assetA, msg.sender, address(this), params.amountMaxA);}
        if(params.amountMaxB > 0) {TransferHelper.safeTransferFrom(assetB, msg.sender, address(this), params.amountMaxB);}
        //Add liquidity to pool
        (uint128 pre_liquidity, , , ) = pool.assets(_position.tickLower);
        pool.provide(
            IKommodo.ProvideParams({
                tickLower: _position.tickLower,
                liquidity: params.liquidity,
                amountMaxA: params.amountMaxA,
                amountMaxB: params.amountMaxB
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
        uint256 balanceA = IERC20(assetA).balanceOf(address(this));
        uint256 balanceB = IERC20(assetB).balanceOf(address(this));
        if(balanceA > 0) {TransferHelper.safeTransfer(assetA, msg.sender, balanceA);}
        if(balanceB > 0) {TransferHelper.safeTransfer(assetB, msg.sender, balanceB);}
    }

    /// @inheritdoc INonfungibleLendManager
    function take(TakeParams calldata params) public override isAuthorizedForToken(params.tokenId) nonReentrant {
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
        startWithdraw(WithdrawParams({
            tokenId: params.tokenId, 
            amountA: type(uint128).max, 
            amountB: type(uint128).max, 
            recipient: params.recipient
        }));
    }

    /// @inheritdoc INonfungibleLendManager
    function withdraw(WithdrawParams memory params) public override isAuthorizedForToken(params.tokenId) nonReentrant {
        startWithdraw(params);
    }

    /// @dev Internal function to split from public function for nonreentrant modifier.
    /// @param params WithdrawParams tokenId/amountA/amountB/recipient
    function startWithdraw(WithdrawParams memory params) internal {
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

    /// @inheritdoc INonfungibleLendManager
    function burn(uint256 tokenId) public override isAuthorizedForToken(tokenId) nonReentrant {
        Position storage _position = position[tokenId];
        require(_position.blocknumber != 0, "burn: no position");
        require(_position.liquidity == 0 && _position.withdrawA == 0 && _position.withdrawB == 0, 'burn: not empty');
        delete position[tokenId];
        _burn(tokenId);
    }
}