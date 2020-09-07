// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./MergeCoin.sol";

contract MergePay is Ownable {
  struct Deposit {
    address account;
    uint256 amount;
    uint8 issueOrPr; // 1 = issue, 2 = pr
    string id;
    uint256 addedTimestamp;
    uint256 lockedUntilTimestamp;
  }

  struct Withdrawal {
    address account;
    uint256 depositId;
    uint8 confirmations;
  }

  struct User {
    address account;
    uint8 confirmations;
  }

  event DepositEvent(address account, uint256 amount, uint8 issueOrPr, string id);
  event RegistrationRequestEvent(address account, string githubUser);
  event RegistrationConfirmedEvent(address account, string githubUser, uint8 confirmations);
  event WithdrawalRequestEvent(address account, uint256 depositId);
  event WithdrawalConfirmedEvent(uint256 id);

  mapping(address => bool) private _oracles;
  mapping(uint256 => Deposit) public _deposits;
  uint256 private _nextDepositId = 1;
  mapping(uint256 => Withdrawal) public _withdrawals;
  uint256 private _nextWithdrawalId = 1;
  mapping(string => User) public _users;
  mapping(address => string) public _usersByAddress;
  mapping(string => bool) private _blacklistedGithubUsers; // Blacklisted users cannot withdraw

  MergeCoin _mergeCoin;

  uint32 private maxLockDays = 180;
  uint8 private _minRegistrationConfirmations = 2;
  uint8 private _minWithdrawalConfirmations = 2;

  modifier onlyOracles {
    require(_oracles[msg.sender], "Only oracles can confirm operations.");
    _;
  }

  /// @dev Initiates MergeCoin and set owner as oracle.
  /// @param mergeCoinAddress The contract address of MergeCoin
  constructor(address mergeCoinAddress) public {
    _mergeCoin = MergeCoin(mergeCoinAddress);
    _oracles[owner()] = true;
  }

  /// @param oracle The oracle address to add
  function enableOracle(address oracle) external onlyOwner {
    require(!_oracles[oracle], "Oracle already exists.");
    _oracles[oracle] = true;
  }

  /// @param oracle The oracle address to remove (cannot be owner)
  function disableOracle(address oracle) external onlyOwner {
    require(_oracles[oracle], "Oracle does not exists.");
    require(oracle != owner(), "Owner oracle can not be removed.");
    _oracles[oracle] = false;
  }

  /// @dev Deposit ETH on any pull request or issue on GitHub.
  /// @param issueOrPr Issues = 1, Pull Requests = 2
  /// @param id The node ID of the issue or pr
  /// @param lockDays The number of day the deposit will be locked
  function deposit(uint8 issueOrPr, string calldata id, uint64 lockDays) external payable {
    require(msg.value > 0, "No ether sent.");

    // cap lockDays
    if (lockDays > maxLockDays) {
      lockDays = maxLockDays;
    }

    _deposits[_nextDepositId] = Deposit(msg.sender, msg.value, issueOrPr, id, now, now + lockDays * 1 days);
    _nextDepositId++;

    emit DepositEvent(msg.sender, msg.value, issueOrPr, id);

    if (lockDays > 0) {
      mintMergeCoin(msg.sender, msg.value, lockDays);
    }
  }

  /// @dev Verify ownership over GitHub account by checking for a repositry of
  /// @dev githubUser named after msg.sender. Adds user as unconfirmed and sends
  /// @dev an oracle request, that will be fullfilled in registerConfirm.
  /// @param githubUser The GitHub username to register
  function register(string calldata githubUser) external {
    if (_users[githubUser].account != address(0)) {
      delete _usersByAddress[_users[githubUser].account];
    }
    _users[githubUser] = User(msg.sender, 0);
    _usersByAddress[msg.sender] = githubUser;

    emit RegistrationRequestEvent(msg.sender, githubUser);
  }

  /// @dev Oracle fullfill method. Sets unconfirmed user to confirmed if repo exists.
  /// @param githubUser The githubUser to confirm
  /// @param account The Eth account to confirm
  function registerConfirm(string calldata githubUser, address account) external onlyOracles {
    require(
      _users[githubUser].account != address(0) && _users[githubUser].account == account,
      "This account confirmation was never requested."
    );
    _users[githubUser].confirmations++;
    emit RegistrationConfirmedEvent(
      account,
      githubUser,
      _users[githubUser].confirmations
    );
  }

  /// @dev Send deposit back to sender.
  function refund(uint256 depositId) external {
    require(_deposits[depositId].amount > 0, "No deposit found.");
    require(_deposits[depositId].lockedUntilTimestamp < now, "Deposit is locked.");
    payable(msg.sender).transfer(_deposits[depositId].amount);
    delete _deposits[depositId];
  }

  /// @dev Send deposit back to sender regardless of lock.
  function forceRefund(uint256 depositId) external onlyOwner {
    require(_deposits[depositId].amount > 0, "No deposit found.");
    payable(_deposits[depositId].account).transfer(_deposits[depositId].amount);
    delete _deposits[depositId];
  }

  /// @dev Send all specified deposits back to sender.
  function refundAll(uint256[] calldata depositIds) external {
    uint256 amount = 0;
    for (uint256 i; i < depositIds.length; i++) {
      if (
        _deposits[depositIds[i]].amount > 0 &&
        _deposits[depositIds[i]].account == msg.sender &&
        _deposits[depositIds[i]].lockedUntilTimestamp < now
      ) {
        amount += _deposits[depositIds[i]].amount;
        delete _deposits[depositIds[i]];
      }
    }
    require(amount > 0, "The specified deposits do not exist or are not yours.");
    payable(msg.sender).transfer(amount);
  }

  function addUserToBlacklist(string calldata githubUser) external onlyOracles {
    _blacklistedGithubUsers[githubUser] = true;
  }

  function removeUserFromBlacklist(string calldata githubUser) external onlyOracles {
    _blacklistedGithubUsers[githubUser] = false;
  }

  /// @dev Send deposit to contributor if deposit's conditions are met.
  function withdraw(uint256 depositId) external {
    // requre deposit exists
    require(_deposits[depositId].amount > 0, "Deposit does not exist.");
    // require a registered githubUser for sender's eth account
    require(
      bytes(_usersByAddress[msg.sender]).length != 0 &&
      _users[_usersByAddress[msg.sender]].confirmations >= _minRegistrationConfirmations,
      "Your account is not registered."
    );
    require(
      !_blacklistedGithubUsers[_usersByAddress[msg.sender]],
      "This GitHub account is blacklisted."
    );

    _withdrawals[_nextWithdrawalId] = Withdrawal(msg.sender, depositId, 0);
    _nextWithdrawalId++;

    emit WithdrawalRequestEvent(msg.sender, depositId);
  }

  /// @dev Oracle fullfill method. Executes withdrawal.
  /// @param withdrawalId The id of the Withdrawal
  function withdrawConfirm(uint256 withdrawalId) external onlyOracles {
    require(_withdrawals[withdrawalId].account != address(0), "Withdrawal request does not exist.");
    require(_deposits[_withdrawals[withdrawalId].depositId].amount > 0, "This deposit has already been withdrawn or refunded.");
    // execute transfer, set execute flag, delete deposit and emit event
    _withdrawals[withdrawalId].confirmations++;
    if (_withdrawals[withdrawalId].confirmations >= _minWithdrawalConfirmations) {
      payable(_withdrawals[withdrawalId].account).transfer(_deposits[_withdrawals[withdrawalId].depositId].amount);
      delete _deposits[_withdrawals[withdrawalId].depositId];
      emit WithdrawalConfirmedEvent(withdrawalId);
    }
  }

  /// @dev Mints MergeCoin based on the lock period. The minted amount equals a percentage of the value of the deposit.
  /// @dev The percentage is based on how many days the deposit will be locked out of the maximum number of days to lock
  /// @dev (actually half of it, to make rewards a bit higher, 180 / 2 = 90)
  /// @param recipient The account receiving the minted MergeCoin
  /// @param value The value of the deposit
  /// @param lockDays The number of days the deposit will be locked
  function mintMergeCoin(address recipient, uint256 value, uint64 lockDays) internal {
    if (lockDays > 0 && value > 0) {
      _mergeCoin.mint(recipient, value * (lockDays / (maxLockDays / 2)));
    }
  }
}
