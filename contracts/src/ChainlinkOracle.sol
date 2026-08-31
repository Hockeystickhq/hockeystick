// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle, IAggregatorV3} from "./interfaces/IOracle.sol";

/// @title ChainlinkOracle
/// @notice Adapts a Chainlink aggregator to the protocol's 18-decimal IOracle,
///         rejecting prices that are stale or non-positive.
/// @dev Robinhood Chain feeds are 8 decimals with a 24h heartbeat. Equity feeds
///      only update during market hours (24/5), so `maxAge` for an equity market
///      must tolerate a weekend or settlement will revert on a Monday morning.
contract ChainlinkOracle is IOracle {
    error StalePrice(uint256 updatedAt, uint256 maxAge);
    error InvalidPrice(int256 answer);
    error IncompleteRound();

    IAggregatorV3 public immutable feed;
    uint256 public immutable maxAge;
    uint256 private immutable _scale;

    constructor(address feed_, uint256 maxAge_) {
        require(feed_ != address(0), "feed=0");
        require(maxAge_ > 0, "maxAge=0");
        feed = IAggregatorV3(feed_);
        maxAge = maxAge_;

        uint8 d = IAggregatorV3(feed_).decimals();
        require(d <= 18, "decimals>18");
        _scale = 10 ** (18 - d);
    }

    /// @inheritdoc IOracle
    function price() public view returns (uint256, uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (answer <= 0) revert InvalidPrice(answer);
        if (updatedAt == 0 || answeredInRound < roundId) revert IncompleteRound();
        if (block.timestamp > updatedAt + maxAge) revert StalePrice(updatedAt, maxAge);

        return (uint256(answer) * _scale, updatedAt);
    }

    /// @inheritdoc IOracle
    function description() external view returns (string memory) {
        return feed.description();
    }
}
