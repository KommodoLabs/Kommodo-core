pragma solidity ^0.8.0;

import '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts/access/Ownable.sol';

contract Positions is ERC721, Ownable {
    
    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function mint(address sender, uint256 id) public onlyOwner {
        _mint(sender, id);
    }

    function burn(uint256 id) public onlyOwner {
        _burn(id);
    }

}