// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOracle} from "../../src/interfaces/IOracle.sol";

contract MockOracle is IOracle {
    uint256 private _price;
    uint256 private _updatedAt;
    string private _desc;

    constructor(uint256 p, string memory d) {
        _price = p;
        _updatedAt = block.timestamp;
        _desc = d;
    }

    function set(uint256 p) external {
        _price = p;
        _updatedAt = block.timestamp;
    }

    function price() external view returns (uint256, uint256) { return (_price, _updatedAt); }
    function description() external view returns (string memory) { return _desc; }
}
