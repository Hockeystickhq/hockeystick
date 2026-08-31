// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlackScholes as BS} from "../src/lib/BlackScholes.sol";

/// @dev External wrapper so `vm.expectRevert` can observe reverts from the
///      library's internal functions.
contract BSHarness {
    function callPremium(uint256 s, uint256 k, uint256 t, uint256 v, int256 r) external pure returns (uint256) {
        return BS.callPremium(BS.Inputs({spot: s, strike: k, timeToExpiry: t, volatility: v, rate: r}));
    }
}
