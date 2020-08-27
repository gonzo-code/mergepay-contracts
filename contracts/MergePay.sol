// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";
import "./MergeCoin.sol";

contract MergePay is ChainlinkClient {
  struct Deposit {
    uint256 amount;
    string repo;
    string repoOwner;
    uint64 prId;
    address sender;
  }

  struct User {
    address account;
    string githubUser;
    bool confirmed;
    bytes32 chainlinkRequestId;
  }

  event DepositEvent(
    uint256 amount,
    string repo,
    string repoOwner,
    uint64 prId,
    address sender
  );
  event RegistrationConfirmedEvent(
    address account,
    string githubUser,
    bool confirmed,
    bytes32 chainlinkRequestId
  );

  Deposit[] private _deposits;
  User[] private _users;

  MergeCoin _mergeCoin;

  address private clOracle;
  bytes32 private clJobId;
  uint256 private clFee;

  constructor(address mergeCoinAddress) public {
    _mergeCoin = MergeCoin(mergeCoinAddress);
    setPublicChainlinkToken();
    clOracle = 0xc99B3D447826532722E41bc36e644ba3479E4365;
    clJobId = "3cff0a3524694ff8834bda9cf9c779a1";
    clFee = 0.1 * 10 ** 18; // 0.1 LINK
  }

  function deposit(string memory repo, string memory repoOwner, uint64 prId) external payable {
    require(msg.value > 0, "No ether sent.");

    // find existing deposit
    bool updatedExisting = false;
    for (uint256 i; i < _deposits.length; i++) {
      if (
        keccak256(abi.encodePacked(_deposits[i].repo)) == keccak256(abi.encodePacked(repo)) &&
        keccak256(abi.encodePacked(_deposits[i].repoOwner)) == keccak256(abi.encodePacked(repoOwner)) &&
        _deposits[i].prId == prId &&
        _deposits[i].sender == msg.sender
      ) {
        // add amount to existing deposit
        _deposits[i].amount += msg.value;
        updatedExisting = true;
        emit DepositEvent(
          _deposits[i].amount,
          _deposits[i].repo,
          _deposits[i].repoOwner,
          _deposits[i].prId,
          _deposits[i].sender
        );
        break;
      }
    }

    // add new deposit
    if (!updatedExisting) {
      Deposit memory newDeposit = Deposit(msg.value, repo, repoOwner, prId, msg.sender);
      _deposits.push(newDeposit);
      emit DepositEvent(msg.value, repo, repoOwner, prId, msg.sender);
    }
  }

  function register(string memory githubUser) external {
    Chainlink.Request memory request = buildChainlinkRequest(clJobId, address(this), this.registerConfirm.selector);
    request.add("username", githubUser);
    request.add("repo", msg.sender);
    bytes32 requestId = sendChainlinkRequestTo(clOracle, request, clFee);
    _users.push(User(msg.sender, githubUser, false, requestId));
  }

  function registerConfirm(bytes32 _requestId, bool confirmed) external {
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

  function withdraw(string memory githubUser, string memory repo, string memory repoOwner, uint64 prId) external {
    // checks:
    // provided githubUser has repo with name of msg.sender (proof of github account, can receive funds) [chainlink->repourl->id]
    // pr is merged and pr author is the provided githubUser [chainlink->pr->merged]
      // withdraw everything
    // githubUser is sender of a deposit
      // withdraw only own deposit
    // mint merge coin if withdrawer != deposit owner
  }
}
