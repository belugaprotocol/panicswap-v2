// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IPanicMinter {
    function stake(uint256, bool) external;
    function withdraw(uint256) external;
    function exit() external;
    function getReward() external;
}