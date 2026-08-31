// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {HockeystickVault} from "../src/HockeystickVault.sol";
import {ChainlinkOracle} from "../src/ChainlinkOracle.sol";
import {TestnetAggregator} from "../src/testnet/TestnetAggregator.sol";
import {TestUSDC} from "../src/testnet/TestUSDC.sol";

/// @notice End-to-end walkthrough of one option's life, printed as it happens.
/// @dev Simulation only — run without --broadcast. Uses vm.warp to move through
///      expiry, which no live chain will honour.
///
///   forge script script/Lifecycle.s.sol -v
contract Lifecycle is Script {
    address constant LP = address(0xA11CE);
    address constant TRADER = address(0xBEEF);

    function run() external {

        TestUSDC usdc = new TestUSDC();
        HockeystickVault vault = new HockeystickVault(address(usdc), LP);

        TestnetAggregator agg = new TestnetAggregator("ETH / USD", 2442_00000000, LP);
        ChainlinkOracle oracle = new ChainlinkOracle(address(agg), 26 hours);
        vm.prank(LP);
        uint32 mkt = vault.listMarket(address(oracle), 0.75e18, 30_000, 500_000e6);

        usdc.mint(LP, 2_000_000e6);
        vm.startPrank(LP);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(2_000_000e6, LP);
        vm.stopPrank();
        console.log("pool seeded            $", vault.totalAssets() / 1e6);

        uint256 strike = 2442e18;
        uint40 expiry = uint40(block.timestamp + 30 days);
        uint256 size = 10e18; // 10 contracts

        (uint256 premium, uint256 fee) = vault.quote(mkt, strike, expiry, false, size);
        console.log("ETH spot               $ 2442");
        console.log("10x 30d $2442 put");
        console.log("  premium              $", premium / 1e6);
        console.log("  fee                  $", fee / 1e6);

        usdc.mint(TRADER, 100_000e6);
        vm.startPrank(TRADER);
        usdc.approve(address(vault), type(uint256).max);
        uint256 before = usdc.balanceOf(TRADER);
        (bytes32 id,) = vault.buy(mkt, strike, expiry, false, size, type(uint256).max);
        uint256 paid = before - usdc.balanceOf(TRADER);
        vm.stopPrank();

        console.log("  paid                 $", paid / 1e6);
        console.log("  pool locked          $", vault.lockedCollateral() / 1e6, "(= strike x 10, the exact max payout)");

        // A live feed prints continuously; the round just before expiry is the
        // one settlement binds to.
        vm.warp(expiry - 1 hours);
        vm.prank(LP);
        agg.setAnswer(2000_00000000);
        console.log("ETH falls to           $ 2000");

        vm.warp(expiry + 1);
        vault.settle(id, agg.latestRound());
        console.log("settled at             $", vault.series(id).settlementPrice / 1e18);
        console.log("  still locked         $", vault.lockedCollateral() / 1e6, "(surplus returned to LPs)");

        vm.warp(block.timestamp + vault.disputeWindow() + 1);
        vm.prank(TRADER);
        uint256 payout = vault.exercise(id);

        console.log("  payout               $", payout / 1e6, "(10 x $442 intrinsic)");
        console.log("TRADER net             $", (int256(payout) - int256(paid)) / 1e6);
        console.log("pool assets            $", vault.totalAssets() / 1e6);
        console.log("pool locked            $", vault.lockedCollateral());
        require(vault.totalAssets() >= vault.lockedCollateral(), "INSOLVENT");
        console.log("solvency invariant     OK");
    }
}
