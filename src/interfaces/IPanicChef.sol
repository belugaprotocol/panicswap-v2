// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPanicChef {
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool.
        uint256 lastRewardTime; // Last second that reward distribution occurs.
        uint256 accRewardPerShare; // Accumulated rewards per share, times 1e12. See below.
    }

    function deposit(uint256, uint256) external;
    function withdraw(uint256, uint256) external;
    function claim(uint256[] memory) external;
    function addPool(address, uint256, bool) external;
    function rewardsPerSecond() external view returns (uint256);
    function poolInfo(uint256) external view returns (PoolInfo memory);
    function totalAllocPoint() external view returns (uint256);
}