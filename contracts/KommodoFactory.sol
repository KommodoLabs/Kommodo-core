// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.19;

import './interfaces/INonfungiblePositionManager.sol';
import './Kommodo.sol';

contract KommodoFactory {
    //AMM variables
    address public factory;
    uint24 public poolFee;
    int24 public poolSpacing;
    
    //Lending pool variables
    uint128 public fee;
    uint128 public interest;
    uint128 public margin;
    
    mapping(address => mapping(address => address)) public kommodo;
    address[] public allKommodo;
    
    constructor(address _factory, uint24 _poolFee, int24 _poolSpacing, uint128 _fee, uint128 _interest, uint128 _margin) {
        require(_margin > 0, "false margin");
        factory = _factory;
        poolFee = _poolFee;
        poolSpacing = _poolSpacing;

        fee = _fee;
        interest = _interest;
        margin = _margin;
    }

    function allKommodoLength() external view returns (uint) {
        return allKommodo.length;
    }

    function createKommodo(address assetA, address assetB) public returns (address) {
        require(assetA != assetB, "create: identical assets");
        (address token0, address token1) = assetA < assetB ? (assetA, assetB) : (assetB, assetA);
        require(token0 != address(0), 'create: no address zero');
        require(kommodo[assetA][assetB] == address(0), "create: existing pool");
        Kommodo _kommodo = new Kommodo(factory, token0, token1, poolSpacing, poolFee, fee, interest, margin);
        kommodo[assetA][assetB] = address(_kommodo);
        kommodo[assetB][assetA] = address(_kommodo);
        allKommodo.push(address(_kommodo));
        return(address(_kommodo));
    }
}
