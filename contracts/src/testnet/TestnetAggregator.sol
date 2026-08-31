// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {IAggregatorV3} from "../interfaces/IOracle.sol";

/// @title TestnetAggregator
/// @notice A writable stand-in for a Chainlink aggregator, for networks where
///         Chainlink has not deployed feeds.
/// @dev Deliberately implements the real `AggregatorV3Interface` so the
///      production `ChainlinkOracle` adapter — including its staleness and
///      incomplete-round checks — is exercised unchanged on testnet. Only the
///      feed behind it is fake.
///
///      Never deploy this on mainnet. Anyone holding the owner key can set the
///      settlement price of every market that reads it.
contract TestnetAggregator is IAggregatorV3, Ownable {
    error StalePush();

    uint8 public constant override decimals = 8;
    string private _description;

    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    uint80 private _roundId;
    mapping(uint80 => Round) private _rounds;

    event AnswerUpdated(int256 indexed answer, uint80 indexed roundId, uint256 updatedAt);

    constructor(string memory description_, int256 initialAnswer, address owner_) {
        _description = description_;
        _initializeOwner(owner_);
        _push(initialAnswer);
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    /// @notice Publish a new price, in 8 decimals.
    function setAnswer(int256 answer) external onlyOwner {
        _push(answer);
    }

    /// @notice Refresh the timestamp without moving the price, so a market does
    ///         not go stale while idle.
    function heartbeat() external onlyOwner {
        _push(_rounds[_roundId].answer);
    }

    function _push(int256 answer) internal {
        require(answer > 0, "answer<=0");
        unchecked {
            _roundId += 1;
        }
        _rounds[_roundId] = Round({answer: answer, startedAt: block.timestamp, updatedAt: block.timestamp});
        emit AnswerUpdated(answer, _roundId, block.timestamp);
    }

    function latestRound() external view returns (uint80) {
        return _roundId;
    }

    function getRoundData(uint80 roundId)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = _rounds[roundId];
        return (roundId, r.answer, r.startedAt, r.updatedAt, roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        Round memory r = _rounds[_roundId];
        return (_roundId, r.answer, r.startedAt, r.updatedAt, _roundId);
    }
}
