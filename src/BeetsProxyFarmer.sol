// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPanicChef} from "./interfaces/IPanicChef.sol";
import {IPanicMinter} from "./interfaces/IPanicMinter.sol";
import {IBeetsChef} from "./interfaces/IBeetsChef.sol";
import {SafeTransferLib} from "./lib/SafeTransferLib.sol";
import {TokenMintable} from "./TokenMintable.sol";

/// @title BeethovenX Proxy Farmer
/// @author Chainvisions
/// @notice Panicswap proxy farmer that farms BEETS for the protocol.

contract BeetsProxyFarmer is Ownable {
    using SafeTransferLib for IERC20;

    constructor() {
        DUMMY_TOKEN = new TokenMintable();

        // We can safely max approve BeethovenX's MasterChef as it has been
        // audited and battle-tested. We will also never reach this max amount.
        LP_TOKEN.safeApprove(address(BEETS_CHEF), type(uint256).max);
    }

    /// @notice Packed storage slot. Saves gas on read.
    struct Slot0 {
        bool rewardsActive;     // Whether or not rewards are active on the farmer.
        uint8 targetPoolId;     // Target pool ID to stake the dummy token into.
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

    /// @notice Internal balances for tracking LP tokens.
    struct InternalBalance {
        uint112 internalBalanceOf;  // LP token `balanceOf`, tracked internally to save gas.
        uint112 internalStake;      // Beets MasterChef stake, tracked internally to save gas.
    }

    /// @notice Dummy token used for farming PANIC.
    TokenMintable public immutable DUMMY_TOKEN;

    /// @notice LP token to deposit into the contract.
    IERC20 public constant LP_TOKEN = IERC20(0x1E2576344D49779BdBb71b1B76193d27e6F996b7);

    /// @notice PANIC token contract.
    IERC20 public constant PANIC = IERC20(0xA882CeAC81B22FC2bEF8E1A82e823e3E9603310B);

    /// @notice BEETS token contract.
    IERC20 public constant BEETS = IERC20(0xF24Bcf4d1e507740041C9cFd2DddB29585aDCe1e);

    /// @notice Panicswap MasterChef contract.
    IPanicChef public constant PANIC_CHEF = IPanicChef(0xC02563f20Ba3e91E459299C3AC1f70724272D618);

    /// @notice Panicswap PANIC minter contract.
    IPanicMinter public constant PANIC_MINTER = IPanicMinter(0x536b88CC4Aa42450aaB021738bf22D63DDC7303e);

    /// @notice BeethovenX MasterChef contract.
    IBeetsChef public constant BEETS_CHEF = IBeetsChef(0x8166994d9ebBe5829EC86Bd81258149B87faCfd3);

    /// @notice BeethovenX MasterChef pool ID for staking LP tokens.
    uint256 public constant BEETS_POOL_ID = 71;

    /// @notice Storage slot #0. Multiple values packed into one.
    Slot0 public slot0;

    /// @notice Storage slot for tracking farm info.
    InternalBalance public internalBalance;

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
    function deposit(uint256 _amount) external {
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[msg.sender];

        // Update reward variables.
        _slot0 = _updatePanic(_slot0);

        // Claim any pending PANIC.
        uint112 newDebt;
        if(_userSlot.stakedAmount > 0) {
            panicHarvest(); // To save gas for the user, we only do this if they *potentially* have rewards.
            newDebt = uint112((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12);
            PANIC.safeTransfer(msg.sender, newDebt - _userSlot.rewardDebt);
        }

        // Update amounts and overwrite slots.
        _userSlot.stakedAmount = uint112(_amount);
        _userSlot.rewardDebt = newDebt;

        delete slot0;

        slot0 = _slot0;
        userSlot[msg.sender] = _userSlot;
        nTokensDeposited += _amount;

        // Transfer tokens in and stake into BeethovenX.
        LP_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);
        BEETS_CHEF.deposit(BEETS_POOL_ID, _amount, address(this));
        internalBalance.internalStake += uint112(_amount);
        emit Deposit(msg.sender, _amount);
    }

    /// @notice Withdraws tokens from the farmer.
    /// @param _amount Amount of tokens to withdraw.
    function withdraw(uint256 _amount) external {
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[msg.sender];
        require(_userSlot.stakedAmount >= _amount, "Cannot withdraw over stake");

        // Update reward variables.
        _slot0 = _updatePanic(_slot0);

        // Claim any pending PANIC.
        panicHarvest();
        uint112 newDebt = uint112((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12);
        PANIC.safeTransfer(msg.sender, newDebt - _userSlot.rewardDebt);

        // Update amounts and overwrite slots.
        _userSlot.stakedAmount -= uint112(_amount);
        _userSlot.rewardDebt = newDebt;

        delete slot0;

        slot0 = _slot0;
        userSlot[msg.sender] = _userSlot;
        nTokensDeposited -= uint112(_amount);

        // Transfer tokens out.
        InternalBalance memory _internalBalance = internalBalance;
        if(_amount > _internalBalance.internalBalanceOf) {
            try BEETS_CHEF.withdrawAndHarvest(BEETS_POOL_ID, _amount, address(this)) {
                LP_TOKEN.safeTransfer(msg.sender, _amount);
                _internalBalance.internalStake -= uint112(_amount);
                internalBalance = _internalBalance;
            } catch {
                BEETS_CHEF.emergencyWithdraw(BEETS_POOL_ID, address(this));
                LP_TOKEN.safeTransfer(msg.sender, _amount);
                _internalBalance.internalBalanceOf = uint112(_internalBalance.internalStake - _amount);
                _internalBalance.internalStake = 0;
                internalBalance = _internalBalance;
            }
        } else {
            LP_TOKEN.safeTransfer(msg.sender, _amount);
        }
        emit Withdrawal(msg.sender, _amount);
    }

    /// @notice Performs an emergency withdrawal from the farm.
    function emergencyWithdraw() external {
        // Update state.
        uint256 stake = userSlot[msg.sender].stakedAmount;
        delete userSlot[msg.sender];

        // Send tokens
        InternalBalance memory _internalBalance = internalBalance;
        if(stake > _internalBalance.internalBalanceOf) {
            try BEETS_CHEF.withdrawAndHarvest(BEETS_POOL_ID, stake, address(this)) {
                LP_TOKEN.safeTransfer(msg.sender, stake);
                _internalBalance.internalStake -= uint112(stake);
                internalBalance = _internalBalance;
            } catch {
                BEETS_CHEF.emergencyWithdraw(BEETS_POOL_ID, address(this));
                LP_TOKEN.safeTransfer(msg.sender, stake);
                _internalBalance.internalBalanceOf = uint112(_internalBalance.internalStake - stake);
                _internalBalance.internalStake = 0;
                internalBalance = _internalBalance;
            }
        } else {
            LP_TOKEN.safeTransfer(msg.sender, stake);
        }
    }

    /// @notice Claims PANIC tokens from the farm.
    function claim() external {
        panicHarvest();
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[msg.sender];

        // Update reward variables.
        _slot0 = _updatePanic(_slot0);

        // A user wouldn't have claimable rewards if they exited.
        uint112 newDebt;
        if(_userSlot.stakedAmount > 0) {
            newDebt = uint112((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12);
            PANIC.safeTransfer(msg.sender, newDebt - _userSlot.rewardDebt);
        }

        // Update stored values.
        _userSlot.rewardDebt = newDebt;  

        delete slot0;

        slot0 = _slot0;
        userSlot[msg.sender] = _userSlot;
    }

    /// @notice Harvests BEETS tokens from BeethovenX.
    function harvestBeets() external {
        BEETS_CHEF.harvest(BEETS_POOL_ID, address(this));
        BEETS.safeTransfer(owner(), BEETS.balanceOf(address(this)));
    }

    /// @notice Calculates the amount of pending PANIC a user has.
    /// @param _user User to calculate the pending rewards of.
    /// @return Pending PANIC tokens claimable for `_user`.
    function pendingPanic(address _user) external view returns (uint256) {
        Slot0 memory _slot0 = slot0;
        UserSlot memory _userSlot = userSlot[_user];

        // Use the latest panicPerShare.
        _slot0 = _updatePanic(_slot0);

        // Calculate pending rewards.
        return ((_userSlot.stakedAmount * _slot0.panicPerShare) / 1e12) - _userSlot.rewardDebt;
    }

    /// @notice Returns the amount of PANIC distributed per second.
    /// @return The amount of PANIC distributed per second by the farm.
    function panicRate() external view returns (uint256) {
        return slot0.panicRate;
    }

    /// @notice Returns the dummy token of the proxy farmer.
    /// @return Proxy farmer dummy token.
    function dummyToken() external view returns (IERC20) {
        return DUMMY_TOKEN;
    }

    /// @notice Harvests PANIC tokens from Panicswap's MasterChef.
    function panicHarvest() public {
        uint256[] memory _pids = new uint256[](1);
        _pids[0] = slot0.targetPoolId;
        PANIC_CHEF.claim(_pids);
        PANIC_MINTER.exit();
    }

    /// @notice Updates the PANIC reward rate.
    function updatePanicRate() public {
        slot0 = _updatePanic(slot0);
    }

    /// @notice Sets the farming pool IDs and begins emissions.
    /// @param _panicId Panicswap pool ID to deposit into.
    function setPoolIDsAndEmit(
        uint8 _panicId
    ) public onlyOwner {
        Slot0 memory _slot0 = slot0;
        require(_slot0.targetPoolId == 0, "ID already set");
        
        // Create all writes in memory.
        _slot0.rewardsActive = true;
        _slot0.targetPoolId = _panicId;
        _slot0.tLastRewardUpdate = uint32(block.timestamp);
        IPanicChef.PoolInfo memory _info = PANIC_CHEF.poolInfo(_panicId);
        _slot0.panicRate = uint64(((PANIC_CHEF.rewardsPerSecond() * (_info.allocPoint)) / PANIC_CHEF.totalAllocPoint()) / 2);

        // Push memory version of Slot0 to storage.
        slot0 = _slot0;

        // Deposit dummy token into Panicswap's MasterChef.
        DUMMY_TOKEN.approve(address(PANIC_CHEF), 1e18);
        PANIC_CHEF.deposit(_panicId, 1e18);
    }

    /// @notice Performs an emergency exit from BeethovenX.
    function emergencyExitFromBeets() public onlyOwner {
        InternalBalance memory _internalBalance = internalBalance;

        // Withdraw from the chef.
        BEETS_CHEF.emergencyWithdraw(BEETS_POOL_ID, address(this));

        // Update internal balances.
        _internalBalance.internalBalanceOf = _internalBalance.internalStake;
        _internalBalance.internalStake = 0;

        // Update storage.
        internalBalance = _internalBalance;
    }

    /// @notice Claims stuck tokens in the contract.
    /// @param _token Token to transfer out. Cannot be LPs or PANIC.
    /// @param _amount Amount of tokens to transfer to the owner.
    function claimStuckTokens(IERC20 _token, uint256 _amount) public onlyOwner {
        require(_token != LP_TOKEN && _token != PANIC, "Cannot be PANIC or LP");
        _token.safeTransfer(owner(), _amount);
    }

    function _updateRewards(Slot0 memory _slot0) private view returns (Slot0 memory) {
        uint256 _nTokensDeposited = nTokensDeposited;
        if(block.timestamp <= _slot0.tLastRewardUpdate || _slot0.rewardsActive == false) {
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

    function _updatePanic(Slot0 memory _slot0) private view returns (Slot0 memory) {
        // Update rewards.
        _slot0 = _updateRewards(_slot0);

        // Recalculate the rate.
        IPanicChef.PoolInfo memory _info = PANIC_CHEF.poolInfo(_slot0.targetPoolId);
        if(_info.allocPoint == 0) {
            _slot0.rewardsActive = false;
            _slot0.panicRate = 0;
        } else {
            _slot0.panicRate = uint64(((PANIC_CHEF.rewardsPerSecond() * (_info.allocPoint)) / PANIC_CHEF.totalAllocPoint()) / 2);
        }

        // Return new slot0.
        return _slot0;
    }
}