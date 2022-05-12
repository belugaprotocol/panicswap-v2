// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";
import {TokenMintable} from "./TokenMintable.sol";

contract BeetsProxyFarmer is Ownable {
    using SafeTransferLib for IERC20;

    /// @notice Packed storage slot. Saves gas on read.
    struct Slot0 {
        uint8 targetPoolId;     // Target pool ID to stake the dummy token into.
        uint8 targetBeetsPoolId;    // Target BeethovenX pool ID to stake into.
        uint32 tLastRewardUpdate;   // Time of the last PANIC reward update on the farm.
        uint64 panicRate;           // Amount of PANIC distributed per second.
        uint112 panicPerShare;      // Amount of PANIC rewards per share in the farm.
        // This totals at 28 bytes, allowing this to all be packed into one 32 byte storage slot. Significant gas savings.
    }

    /// @notice User info. Packed into one storage slot.
    struct UserSlot {
        uint112 stakedAmount;
        uint112 rewardDebt;
        // This also totals at 28 bytes, making this all readable in one 32 byte slot.
    }

    /// @notice Storage slot #0. Multiple values packed into one.
    Slot0 public slot0;

    /// @notice LP token to deposit into the contract.
    IERC20 public lpToken;

    /// @notice PANIC token contract.
    IERC20 public panic;

    /// @notice Internal tracking for deposited tokens.
    uint256 public nTokensDeposited;

    /// @notice Data for a specific user.
    mapping(address => UserSlot) public userSlot;

    /// @notice Emitted on a deposit on the farmer.
    event Deposit(address indexed depositor, uint256 amount);

    /// @notice Emitted on a withdrawal on the farmer.
    event Withdrawal(address indexed depositor, uint256 amount);

    /// @notice Deposits tokens into the farmer.
    /// @param _amount Amount of tokens to deposit.
    function deposit(uint256 _amount) public {
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[msg.sender];

        // Update reward variables.
        _slot0 = updateRewards(_slot0);

        // Claim any pending PANIC.
        uint112 newDebt;
        if(_userSlot.stakedAmount > 0) {
            newDebt = uint112((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12);
            panic.safeTransfer(msg.sender, newDebt - _userSlot.rewardDebt);
        }

        // Update amounts and overwrite slots.
        _userSlot.stakedAmount = uint112(_amount);
        _userSlot.rewardDebt += newDebt;
        slot0 = _slot0;
        userSlot[msg.sender] = _userSlot;
        nTokensDeposited += _amount;

        // Transfer tokens in.
        lpToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(msg.sender, _amount);
    }

    /// @notice Withdraws tokens from the farmer.
    /// @param _amount Amount of tokens to withdraw.
    function withdraw(uint256 _amount) public {
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[msg.sender];
        require(_userSlot.stakedAmount >= _amount, "Cannot withdraw over stake");

        // Update reward variables.
        _slot0 = updateRewards(_slot0);

        // Claim any pending PANIC.
        uint112 newDebt = uint112((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12);
        panic.safeTransfer(msg.sender, newDebt - _userSlot.rewardDebt);

        // Update amounts and overwrite slots.
        _userSlot.stakedAmount -= uint112(_amount);
        _userSlot.rewardDebt += newDebt;
        slot0 = _slot0;
        userSlot[msg.sender] = _userSlot;
        nTokensDeposited -= uint112(_amount);

        // Transfer tokens out.
        lpToken.safeTransfer(msg.sender, _amount);
        emit Withdrawal(msg.sender, _amount);
    }

    function updateRewards(Slot0 memory _slot0) private view returns (Slot0 memory) {
        uint256 _nTokensDeposited = nTokensDeposited;
        if(block.timestamp <= _slot0.tLastRewardUpdate) {
            return _slot0;
        }

        // Do not distribute if there are no deposits.
        if(_nTokensDeposited == 0) {
            _slot0.tLastRewardUpdate = uint32(block.timestamp);
            return _slot0;
        }

        // Distribute new rewards.
        _slot0.panicPerShare += uint112((((block.timestamp - _slot0.tLastRewardUpdate) * _slot0.panicRate) * 1e12) / _nTokensDeposited);
        _slot0.tLastRewardUpdate = uint32(block.timestamp);

        // Return new slot.
        return _slot0;
    }
}