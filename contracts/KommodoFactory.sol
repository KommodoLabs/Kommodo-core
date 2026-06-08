// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';

import './interfaces/IKommodoFactory.sol';
import './interfaces/IKommodo.sol';
import './Kommodo.sol';

contract KommodoFactory is IKommodoFactory {
    using Clones for address;
    
    /// @inheritdoc IKommodoFactory
    address public immutable override factory;
    /// @inheritdoc IKommodoFactory
    uint24 public immutable override multiplier;
    
    /// @inheritdoc IKommodoFactory
    address public immutable implementation;

    /// @inheritdoc IKommodoFactory
    mapping(address => mapping(address => mapping(uint24 => address))) public override kommodo;
    /// @inheritdoc IKommodoFactory
    address[] public override allKommodo;
    
    constructor(
        address _factory, 
        uint24 _multiplier,
        address _implementation 
    ) {
        require(_factory != address(0), "constructor: zero factory"); 
        require(_multiplier != 0, "constructor: zero mulitplier"); 
        require(_implementation != address(0), "constructor: zero implementation");
        factory = _factory;
        multiplier = _multiplier;
        implementation = _implementation;
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
        require(tickSpacing != 0, "create: invalid poolFee");
        address clone = implementation.clone();
        IKommodo(clone).initialize(
            IKommodo.CreateParams({
                factory: factory,
                tokenA: token0,
                tokenB: token1,
                tickSpacing: tickSpacing,
                fee: poolFee,
                multiplier: multiplier
            })
        );
        kommodo[assetA][assetB][poolFee] = clone;
        kommodo[assetB][assetA][poolFee] = clone;
        allKommodo.push(clone);
        return(clone);
    }
}