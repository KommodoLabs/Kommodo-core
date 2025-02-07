// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.19;

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import './interfaces/IKommodo.sol';
import './Kommodo.sol';

contract KommodoFactory {
    
    address public factory;
    uint128 public multiplier;
    uint256 public delay;
    
    mapping(address => mapping(address => address)) public kommodo;
    address[] public allKommodo;
    
    constructor(
        address _factory, 
        uint128 _multiplier, 
        uint256 _delay
    ) {
        factory = _factory;
        multiplier = _multiplier;
        delay = _delay;
    }

    function allKommodoLength() external view returns (uint) {
        return allKommodo.length;
    }

    function createKommodo(
        address assetA, 
        address assetB, 
        uint24 poolFee
    ) public returns (address) {
        require(assetA != assetB, "create: identical assets");
        (address token0, address token1) = assetA < assetB ? (assetA, assetB) : (assetB, assetA);
        require(token0 != address(0), 'create: no address zero');
        require(kommodo[assetA][assetB] == address(0), "create: existing pool");
        int24 tickSpacing = IUniswapV3Factory(factory).feeAmountTickSpacing(poolFee);
        require(tickSpacing != 0, "constructor: invalid poolFee");
        Kommodo _kommodo = new Kommodo(
            IKommodo.CreateParams({
            factory: factory,
            tokenA: token0, 
            tokenB: token1,
            tickSpacing: tickSpacing, 
            fee: poolFee,
            multiplier: multiplier, 
            delay: delay  
        }));
        kommodo[assetA][assetB] = address(_kommodo);
        kommodo[assetB][assetA] = address(_kommodo);
        allKommodo.push(address(_kommodo));
        return(address(_kommodo));
    }
}
