// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface IBeetsChef {
    function deposit(uint256, uint256, address) external;
    function withdrawAndHarvest(uint256, uint256, address) external;
    function emergencyWithdraw(uint256, address) external;
    function harvest(uint256, address) external;
}