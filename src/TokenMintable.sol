// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TokenMintable is ERC20("Panic Mintable Dummy Pool", "dPANIC"), Ownable {
    constructor() {
        _mint(msg.sender, 1e18);
    }
}