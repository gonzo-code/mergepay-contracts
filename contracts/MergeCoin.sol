// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MergeCoin is ERC20, Ownable {
    constructor() ERC20("MyNFT", "MNFT") public {}

    function mint(address _account, uint256 _amount) public onlyOwner {
     _mint(_account, _amount);
   }
}
