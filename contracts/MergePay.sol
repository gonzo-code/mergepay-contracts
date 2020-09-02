// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./MergeCoin.sol";

contract MergePay is ChainlinkClient, Ownable {
  struct Deposit {
    uint256 amount;
    uint8 issueOrPr; // 1 = issue, 2 = pr
    uint256 id;
    address sender;
    uint256 addedTimestamp;
    uint256 lockedUntilTimestamp;
  }

  struct Withdrawal {
    address recipient;
    uint256 prId;
    bytes32 chainlinkRequestId;
    bool executed;
  }

  struct User {
    address account;
    uint256 githubUser;
    bool confirmed;
    bytes32 chainlinkRequestId;
  }

  event DepositEvent(
    uint256 amount,
    uint8 issueOrPr,
    uint256 id,
    address sender
  );

  event RegistrationConfirmedEvent(
    address account,
    uint256 githubUser,
    bool confirmed,
    bytes32 chainlinkRequestId
  );

  Deposit[] private _deposits;
  Withdrawal[] private _pendingWithdrawals;
  User[] private _users;

  MergeCoin _mergeCoin;

  address private clOracle;
  bytes32 private clJobIdRegister;
  bytes32 private clJobIdWithdraw;
  uint256 private clFee;

  uint32 private maxLockDays = 180;
  uint256[] private _blacklistedGithubUsers; // Blacklisted users cannot withdraw from their merged pull requests.

  /// @dev Initiates MergeCoin and Chainlink.
  /// @param mergeCoinAddress The contract address of MergeCoin
  constructor(address mergeCoinAddress) public {
    _mergeCoin = MergeCoin(mergeCoinAddress);
    setPublicChainlinkToken();
    clOracle = 0xc99B3D447826532722E41bc36e644ba3479E4365;
    clJobIdRegister = "3cff0a3524694ff8834bda9cf9c779a1";
    clJobIdWithdraw = "3cff0a3524694ff8834bda9cf9c779a1";
    clFee = 0.1 * 10 ** 18; // 0.1 LINK
  }

  /// @dev Deposit ETH on any pull request or issue on GitHub.
  /// @dev TODO: lock up deposit
  /// @param issueOrPr Issues = 1, Pull Requests = 2
  /// @param id The node ID of the issue or pr
  function deposit(uint8 issueOrPr, uint256 id, uint64 lockDays) external payable {
    require(msg.value > 0, "No ether sent.");

    // cap lockDays to ~ half a year
    if (lockDays > maxLockDays) {
      lockDays = maxLockDays;
    }

    // find existing deposit
    bool updatedExisting = false;
    for (uint256 i; i < _deposits.length; i++) {
      if (
        _deposits[i].issueOrPr == issueOrPr &&
        _deposits[i].id == id &&
        _deposits[i].sender == msg.sender
      ) {
        // add amount to existing deposit
        _deposits[i].amount += msg.value;
        // override lock
        if (lockDays > 0 && _deposits[i].lockedUntilTimestamp < now + lockDays * 1 days) {
          _deposits[i].lockedUntilTimestamp += now + lockDays * 1 days;
          mintMergeCoin(msg.sender, msg.value, lockDays);
        }
        updatedExisting = true;
        emit DepositEvent(
          _deposits[i].amount,
          _deposits[i].issueOrPr,
          _deposits[i].id,
          _deposits[i].sender
        );
        break;
      }
    }

    // add new deposit
    if (!updatedExisting) {
      Deposit memory newDeposit = Deposit(msg.value, issueOrPr, id, msg.sender, now, now + lockDays * 1 days);
      _deposits.push(newDeposit);
      emit DepositEvent(msg.value, issueOrPr, id, msg.sender);

      if (lockDays > 0) {
        mintMergeCoin(msg.sender, msg.value, lockDays);
      }
    }
  }

  /// @dev Verify ownership over GitHub account by checking for a repositry of
  /// @dev githubUser named after msg.sender. Adds user as unconfirmed and sends
  /// @dev a chainlink request, that will be fullfilled in registerConfirm.
  /// @param githubUser The GitHub username to register
  function register(uint256 githubUser) external  {
    Chainlink.Request memory request = buildChainlinkRequest(clJobIdRegister, address(this), this.registerConfirm.selector);
    request.addInt("userId", int256(githubUser));
    request.add("repo", addressToString(msg.sender));
    bytes32 requestId = sendChainlinkRequestTo(clOracle, request, clFee);

    // check if user already exists
    int256 existingUserIndex = -1;
    for (uint256 i; i < _users.length; i++) {
      if (_users[i].githubUser == githubUser) {
        existingUserIndex = int256(i);
        break;
      }
    }

    // update request id or add new user
    if (existingUserIndex != -1) {
      _users[uint256(existingUserIndex)].chainlinkRequestId = requestId;
    } else {
      _users.push(User(msg.sender, githubUser, false, requestId));
    }
  }

  /// @dev Chainlink fullfill method. Sets unconfirmed user to confirmed if repo exists.
  /// @param _requestId The Chainlink request ID
  /// @param confirmed Whether a repo named after the address was found or not
  function registerConfirm(bytes32 _requestId, bool confirmed) external recordChainlinkFulfillment(_requestId) {
    require(confirmed, "Account ownership could not be validated.");
    for (uint256 i = 0; i < _users.length; i++) {
      if (_users[i].chainlinkRequestId == _requestId) {
        _users[i].confirmed = true;
        emit RegistrationConfirmedEvent(
          _users[i].account,
          _users[i].githubUser,
          _users[i].confirmed,
          _users[i].chainlinkRequestId
        );
        break;
      }
    }
  }

  /// @dev Send deposit back to sender.
  function refund(uint8 issueOrPr, uint256 id) external {
    // find index
    uint256 refundDepositIndex;
    bool refundDepositFound = false;
    for (uint256 i; i < _deposits.length; i++) {
      if (
        _deposits[i].issueOrPr == issueOrPr &&
        _deposits[i].id == id &&
        _deposits[i].sender == msg.sender &&
        _deposits[i].amount > 0
      ) {
        refundDepositIndex = i;
        refundDepositFound = true;
        break;
      }
    }

    require(refundDepositFound, "No deposit found.");
    require(_deposits[refundDepositIndex].lockedUntilTimestamp < now, "Deposit is locked.");
    payable(msg.sender).transfer(_deposits[refundDepositIndex].amount);
    _deposits[refundDepositIndex].amount = 0;
  }

  /// @dev Send deposit back to sender regardless of lock.
  function forceRefund(address recipient, uint8 issueOrPr, uint256 id) external onlyOwner {
    // find index
    uint256 refundDepositIndex;
    bool refundDepositFound = false;
    for (uint256 i; i < _deposits.length; i++) {
      if (
        _deposits[i].issueOrPr == issueOrPr &&
        _deposits[i].id == id &&
        _deposits[i].sender == recipient &&
        _deposits[i].amount > 0
      ) {
        refundDepositIndex = i;
        refundDepositFound = true;
        break;
      }
    }

    require(refundDepositFound, "No deposit found.");
    payable(recipient).transfer(_deposits[refundDepositIndex].amount);
    _deposits[refundDepositIndex].amount = 0;
  }

  /// @dev Send deposit back to sender.
  function refundAll() external {
    uint256 amount = 0;
    for (uint256 i; i < _deposits.length; i++) {
      if (
        _deposits[i].sender == msg.sender &&
        _deposits[i].amount > 0 &&
        _deposits[i].lockedUntilTimestamp < now
      ) {
        amount += _deposits[i].amount;
        _deposits[i].amount = 0;
      }
    }

    require(amount > 0, "No deposits found.");
    payable(msg.sender).transfer(amount);
  }

  function addUserToBlacklist(uint256 githubUser) external onlyOwner {
    _blacklistedGithubUsers.push(githubUser);
  }

  function removeUserFromBlacklist(uint256 githubUser) external onlyOwner {
    for (uint256 i = 0; i < _blacklistedGithubUsers.length; i++) {
      if (_blacklistedGithubUsers[i] == githubUser) {
        delete _blacklistedGithubUsers[i];
      }
    }
  }

  /// @dev Send deposit to contributor (anyone != deposit.sender).
  /// @param prId The node ID of the issue or pr
  function withdraw(uint256 prId) external {
    // checks:
    // provided githubUser has repo with name of msg.sender (proof of github account, can receive funds) [chainlink->repourl->id]
    // pr is merged and pr author is the provided githubUser [chainlink->pr->merged]
      // withdraw everything
    // githubUser is sender of a deposit
      // withdraw only own deposit
    // mint merge coin if withdrawer != deposit owner

    // get githubuUser for address
    User memory user;
    for (uint256 i = 0; i < _users.length; i++) {
      if (_users[i].account == msg.sender) {
        user = _users[i];
        break;
      }
    }
    require(user.confirmed, "Your account is not registered.");

    for (uint256 i = 0; i < _blacklistedGithubUsers.length; i++) {
      require(user.githubUser != _blacklistedGithubUsers[i], "This GitHub account is blacklisted.");
    }

    bool depositsFound = false;
    for (uint256 i; i < _deposits.length; i++) {
      if (_deposits[i].issueOrPr == 2 && _deposits[i].id == prId) {
        depositsFound = true;
      }
    }
    require(depositsFound, "There are no deposits for this pull request.");

    Chainlink.Request memory request = buildChainlinkRequest(clJobIdWithdraw, address(this), this.withdrawConfirm.selector);
    request.addInt("userId", int256(user.githubUser));
    request.addInt("prId", int256(prId));
    bytes32 requestId = sendChainlinkRequestTo(clOracle, request, clFee);
    _pendingWithdrawals.push(Withdrawal(msg.sender, prId, requestId, false));
  }

  /// @dev Chainlink fullfill method. Executes withdrawal.
  /// @param _requestId The Chainlink request ID
  /// @param confirmed Whether a repo named after the address was found or not
  function withdrawConfirm(bytes32 _requestId, bool confirmed) external recordChainlinkFulfillment(_requestId) {
    require(confirmed, "Eligibility for withdrawal could not be validated. Is the pull request merged? Are you connected to the right GitHub account?");
    // get pending withdrawal
    Withdrawal storage pendingWithdrawal;
    for (uint256 i = 0; i < _pendingWithdrawals.length; i++) {
      if (_pendingWithdrawals[i].chainlinkRequestId == _requestId && _pendingWithdrawals[i].executed == false) {
        pendingWithdrawal = _pendingWithdrawals[i];
        break;
      }
    }
    require(pendingWithdrawal.prId > 0, "No pending withdrawal found.");
    // execute
    uint256 amount = 0;
    for (uint256 i; i < _deposits.length; i++) {
      if (_deposits[i].issueOrPr == 2 && _deposits[i].id == pendingWithdrawal.prId) {
        amount += _deposits[i].amount;
        _deposits[i].amount = 0;
      }
    }

    require(amount > 0, "No deposited ETH to withdraw.");
    payable(pendingWithdrawal.recipient).transfer(amount);
    pendingWithdrawal.executed = true;
  }

  /// @dev Convert address type to string type.
  function addressToString(address _address) public pure returns (string memory _uintAsString) {
    uint _i = uint256(_address);
    if (_i == 0) {
      return "0";
    }
    uint j = _i;
    uint len;
    while (j != 0) {
      len++;
      j /= 10;
    }
    bytes memory bstr = new bytes(len);
    uint k = len - 1;
    while (_i != 0) {
      bstr[k--] = byte(uint8(48 + _i % 10));
      _i /= 10;
    }
    return string(bstr);
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
