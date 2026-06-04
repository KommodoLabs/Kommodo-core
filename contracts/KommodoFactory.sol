// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';

import './interfaces/IKommodoFactory.sol';
import './interfaces/IKommodo.sol';
import './Kommodo.sol';

contract KommodoFactory is IKommodoFactory {
    
    /// @inheritdoc IKommodoFactory
    address public immutable override factory;
    /// @inheritdoc IKommodoFactory
    uint24 public immutable override multiplier;

    /// @inheritdoc IKommodoFactory
    mapping(address => mapping(address => mapping(uint24 => address))) public override kommodo;
    /// @inheritdoc IKommodoFactory
    address[] public override allKommodo;
    
    constructor(
        address _factory, 
        uint24 _multiplier 
    ) {
        require(_factory != address(0), "Connector: zero factory"); 
        require(_multiplier != 0, "Connector: zero mulitplier"); 
        factory = _factory;
        multiplier = _multiplier;
    }

    /// @inheritdoc IKommodoFactory
    function allKommodoLength() external override view returns (uint) {
        return allKommodo.length;
    }

    /// @inheritdoc IKommodoFactory
    function createKommodo(
        address assetA, 
        address assetB, 
        uint24 poolFee
    ) public override returns (address) {
        require(assetA != assetB, "create: identical assets");
        (address token0, address token1) = assetA < assetB ? (assetA, assetB) : (assetB, assetA);
        require(token0 != address(0), 'create: no address zero');
        require(kommodo[assetA][assetB][poolFee] == address(0), "create: existing pool");
        int24 tickSpacing = IUniswapV3Factory(factory).feeAmountTickSpacing(poolFee);
        require(tickSpacing != 0, "constructor: invalid poolFee");
        Kommodo _kommodo = new Kommodo(
            IKommodo.CreateParams({
            factory: factory,
            tokenA: token0, 
            tokenB: token1,
            tickSpacing: tickSpacing, 
            fee: poolFee,
            multiplier: multiplier
        }));
        kommodo[assetA][assetB][poolFee] = address(_kommodo);
        kommodo[assetB][assetA][poolFee] = address(_kommodo);
        allKommodo.push(address(_kommodo));
        return(address(_kommodo));
    }
}