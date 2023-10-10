pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract Token is ERC20, Ownable {
    constructor() ERC20('Token', 'TO') {}

    function mint(uint256 amount) public {
        _mint(msg.sender, amount);
    }
}