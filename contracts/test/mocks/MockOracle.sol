// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "../../src/interfaces/IOracle.sol";

contract MockOracle is IOracle {
    uint256 private _price;
    uint256 private _updatedAt;
    string private _desc;

    uint80 public latestRound;
    mapping(uint80 => uint256) public priceOfRound;
    mapping(uint80 => uint256) public timeOfRound;

    constructor(uint256 p, string memory d) {
        _desc = d;
        _record(p);
    }

    function set(uint256 p) external {
        _record(p);
    }

    function _record(uint256 p) internal {
        _price = p;
        _updatedAt = block.timestamp;
        latestRound += 1;
        priceOfRound[latestRound] = p;
        timeOfRound[latestRound] = block.timestamp;
    }

    function maxAge() external pure returns (uint256) {
        return 26 hours;
    }

    function priceAt(uint80 roundId) external view returns (uint256, uint256) {
        return (priceOfRound[roundId], timeOfRound[roundId]);
    }

    function price() external view returns (uint256, uint256) { return (_price, _updatedAt); }
    function description() external view returns (string memory) { return _desc; }
}
