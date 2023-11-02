// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.19;

import './interfaces/INonfungiblePositionManager.sol';

import './Kommodo.sol';

contract KommodoFactory {
    //AMMs variables
    address public manager;
    uint24 public poolFee;
    uint128 public fee;
    //Lending pool variables
    uint128 public interest;
    int256 public margin;

    mapping(address => mapping(address => address)) public kommodo;
    address[] public allKommodo;
    
    constructor(address _manager, uint24 _poolFee, uint128 _fee, uint128 _interest, int256 _margin) {
        manager = _manager;
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
        (address token0, address token1) = assetA < assetB ? (assetA, assetB) : (assetB, assetA);
        require(token0 != address(0), 'create: no address zero');
        require(kommodo[assetA][assetB] == address(0), "create: existing pool");
        Kommodo _kommodo = new Kommodo(manager, token0, token1, poolFee, fee, interest, margin);
        kommodo[assetA][assetB] = address(_kommodo);
        kommodo[assetB][assetA] = address(_kommodo);
        allKommodo.push(address(_kommodo));
        return(address(_kommodo));
    }
}
