// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Price source for a market, normalised to 18 decimals.
interface IOracle {
    /// @return price The asset price in USD, scaled to 1e18.
    /// @return updatedAt Unix timestamp of the round the price came from.
    function price() external view returns (uint256 price, uint256 updatedAt);

    /// @notice Price from a specific historical round, for settling at a past
    ///         instant rather than at whatever the price happens to be now.
    /// @return price The asset price in USD, scaled to 1e18. Zero if the round
    ///         does not exist.
    /// @return updatedAt Timestamp of that round, or zero if it does not exist.
    function priceAt(uint80 roundId) external view returns (uint256 price, uint256 updatedAt);

    /// @notice Longest age this oracle will accept before treating a price as stale.
    function maxAge() external view returns (uint256);

    /// @notice Human-readable feed description, e.g. "ETH / USD".
    function description() external view returns (string memory);
}

/// @notice The subset of Chainlink's AggregatorV3Interface that this protocol uses.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
