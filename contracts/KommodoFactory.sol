// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.19;

import './interfaces/INonfungiblePositionManager.sol';

import './Kommodo.sol';

contract KommodoFactory {

    mapping(address => mapping(address => address)) public kommodo;
    address[] public allKommodo;

    INonfungiblePositionManager public manager;
    uint24 public poolFee;
    uint128 public fee;
    uint128 public interest;
    int256 public margin;
    
    constructor(address _manager, uint24 _poolFee, uint128 _fee, uint128 _interest, int256 _margin) {
        manager = INonfungiblePositionManager(_manager);
        poolFee = _poolFee;
        fee = _fee;
        interest = _interest;
        margin = _margin;
    }

    function allKommodoLength() external view returns (uint) {
        return allKommodo.length;
    }

    function createKommodo(address assetA, address assetB) public returns (address) {
        require(assetA != assetB, "create: identical assets");
        require(assetA != address(0) && assetB != address(0), "create: no address zero");
        require(kommodo[assetA][assetB] == address(0), "create: existing pool");

        (address token0, address token1) = assetA < assetB ? (assetA, assetB) : (assetB, assetA);
        Kommodo _kommodo = new Kommodo(address(manager), token0, token1, poolFee, fee, interest, margin);
        
        kommodo[assetA][assetB] = address(_kommodo);
        kommodo[assetB][assetA] = address(_kommodo);
        allKommodo.push(address(_kommodo));
        return(address(_kommodo));
    }
}
