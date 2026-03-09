// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.8.24;

/**
* @dev Interface Kommodo - permissionless lending protocol                            
*/
interface IKommodoFactory {
    
    function kommodo(address assetA, address assetB, uint24 poolFee)
        external view returns (address);

    function createKommodo(address assetA, address assetB, uint24 poolFee)
        external returns (address);

}