// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HockeystickVault} from "../src/HockeystickVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract HockeystickVaultTest is Test {
    HockeystickVault vault;
    MockERC20 usdc;
    MockOracle oracle;

    address owner = address(0xA11CE);
    address lp = address(0xB0B);
    address trader = address(0xCAFE);

    uint256 constant USDC_ONE = 1e6; // 6-decimal collateral, as on most chains
    uint32 marketId;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle(3000e18, "ETH / USD");

        vm.prank(owner);
        vault = new HockeystickVault(address(usdc), owner);

        vm.prank(owner);
        // 80% vol, calls capped at 2x strike, $5M cap per series
        marketId = vault.listMarket(address(oracle), 0.8e18, 20_000, uint128(5_000_000 * USDC_ONE));

        usdc.mint(lp, 10_000_000 * USDC_ONE);
        usdc.mint(trader, 1_000_000 * USDC_ONE);

        vm.prank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(trader);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(lp);
        vault.deposit(1_000_000 * USDC_ONE, lp);
    }

    /// @dev The invariant the whole design exists to hold.
    function _assertSolvent() internal view {
        assertGe(vault.totalAssets(), vault.lockedCollateral(), "INSOLVENT: assets < locked");
    }

    /* ----------------------------------- pool ---------------------------------- */

    function test_depositMintsProportionalShares() public {
        assertEq(vault.balanceOf(lp), 1_000_000 * USDC_ONE, "first deposit is 1:1");

        usdc.mint(address(this), 500_000 * USDC_ONE);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(500_000 * USDC_ONE, address(this));
        assertEq(shares, 500_000 * USDC_ONE, "second deposit at par");
    }

    function test_withdrawReturnsCollateral() public {
        vm.prank(lp);
        uint256 assets = vault.withdraw(400_000 * USDC_ONE, lp);
        assertEq(assets, 400_000 * USDC_ONE);
        _assertSolvent();
    }

    function test_cannotWithdrawCollateralBackingLiveOptions() public {
        // Buy puts, locking a large reserve.
        vm.prank(trader);
        vault.buy(marketId, 3000e18, uint40(block.timestamp + 30 days), false, 200e18, type(uint256).max);

        assertGt(vault.lockedCollateral(), 0, "should have locked collateral");

        // Hoist every read before arming expectRevert: an external call in the
        // argument list would otherwise be the "next call" it matches against.
        uint256 allShares = vault.balanceOf(lp);
        uint256 wouldNeed = vault.totalAssets(); // all shares asks for everything
        uint256 free = vault.freeCollateral();
        assertLt(free, wouldNeed, "test needs locked collateral to bind");

        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(
                HockeystickVault.InsufficientFreeCollateral.selector, wouldNeed, free
            )
        );
        vault.withdraw(allShares, lp);

        _assertSolvent();
    }

    /* ---------------------------------- pricing -------------------------------- */

    function test_quoteIsPositiveAndFeeCharged() public view {
        (uint256 premium, uint256 fee) =
            vault.quote(marketId, 3000e18, uint40(block.timestamp + 30 days), true, 1e18);
        assertGt(premium, 0, "ATM call must cost something");
        assertEq(fee, premium / 100, "1% fee");
    }

    function test_cappedCallCostsLessThanVanilla() public {
        // A call capped at 2x strike must be cheaper than one capped at 10x,
        // because the pool is selling strictly less upside.
        (uint256 tight,) = vault.quote(marketId, 3000e18, uint40(block.timestamp + 30 days), true, 1e18);

        vm.prank(owner);
        vault.setMarketParams(marketId, 0.8e18, 100_000, uint128(5_000_000 * USDC_ONE));
        (uint256 wide,) = vault.quote(marketId, 3000e18, uint40(block.timestamp + 30 days), true, 1e18);

        assertLt(tight, wide, "tighter cap must be cheaper");
    }

    function test_rejectsTenorBeyondLimit() public {
        vm.expectRevert(HockeystickVault.TenorTooLong.selector);
        vault.quote(marketId, 3000e18, uint40(block.timestamp + 200 days), true, 1e18);
    }

    /* ------------------------------------ buy ---------------------------------- */

    function test_buyLocksExactMaxPayout() public {
        uint40 expiry = uint40(block.timestamp + 30 days);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 10e18, type(uint256).max);

        // A put's max payout is the strike: 10 contracts x $3000 = $30,000.
        assertEq(vault.lockedCollateral(), 30_000 * USDC_ONE, "put reserve = strike x size");
        _assertSolvent();
    }

    function test_buyRespectsSlippageBound() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        (uint256 premium, uint256 fee) = vault.quote(marketId, 3000e18, expiry, true, 1e18);

        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(HockeystickVault.PremiumExceedsMax.selector, premium + fee, premium)
        );
        vault.buy(marketId, 3000e18, expiry, true, 1e18, premium);
    }

    function test_exposureCapBlocksOversizedSeries() public {
        vm.prank(owner);
        vault.setMarketParams(marketId, 0.8e18, 20_000, uint128(10_000 * USDC_ONE));

        vm.prank(trader);
        vm.expectRevert(); // ExposureCapReached
        vault.buy(marketId, 3000e18, uint40(block.timestamp + 30 days), false, 10e18, type(uint256).max);
    }

    /* -------------------------------- settlement ------------------------------- */

    function test_putInTheMoneyPaysIntrinsic() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 10e18, type(uint256).max);

        vm.warp(expiry - 1 hours);
        oracle.set(2500e18); // $500 in the money
        vm.warp(expiry + 1);
        vault.settle(id, oracle.latestRound());
        _assertSolvent();

        vm.warp(block.timestamp + vault.disputeWindow() + 1);
        uint256 before = usdc.balanceOf(trader);
        vm.prank(trader);
        uint256 payout = vault.exercise(id);

        assertEq(payout, 5_000 * USDC_ONE, "10 x $500");
        assertEq(usdc.balanceOf(trader) - before, payout);
        _assertSolvent();
    }

    function test_outOfTheMoneyExpiresWorthlessAndPoolKeepsPremium() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        uint256 poolBefore = vault.totalAssets();

        vm.prank(trader);
        (, uint256 paid) = vault.buy(marketId, 3000e18, expiry, false, 10e18, type(uint256).max);

        vm.warp(expiry - 1 hours);
        oracle.set(3500e18); // put finishes out of the money
        vm.warp(expiry + 1);
        vault.settle(id, oracle.latestRound());

        assertEq(vault.lockedCollateral(), 0, "nothing owed, all collateral released");
        assertEq(vault.totalAssets(), poolBefore + paid, "pool keeps the entire premium");

        vm.warp(block.timestamp + vault.disputeWindow() + 1);
        vm.prank(trader);
        assertEq(vault.exercise(id), 0, "worthless option pays nothing");
        _assertSolvent();
    }

    function test_callPayoutIsCappedAtTheDisclosedCeiling() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, true);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, true, 1e18, type(uint256).max);

        vm.warp(expiry - 1 hours);
        oracle.set(100_000e18); // far beyond the 2x cap
        vm.warp(expiry + 1);
        vault.settle(id, oracle.latestRound());

        vm.warp(block.timestamp + vault.disputeWindow() + 1);
        vm.prank(trader);
        uint256 payout = vault.exercise(id);

        // Cap is 2x strike = $6000, so payout tops out at $6000 - $3000.
        assertEq(payout, 3_000 * USDC_ONE, "call payout capped at cap - strike");
        _assertSolvent();
    }

    function test_buyerLossNeverExceedsPremium() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, true);

        uint256 before = usdc.balanceOf(trader);
        vm.prank(trader);
        (, uint256 paid) = vault.buy(marketId, 3000e18, expiry, true, 1e18, type(uint256).max);

        vm.warp(expiry - 1 hours);
        oracle.set(1e18); // catastrophic move against the buyer
        vm.warp(expiry + 1);
        vault.settle(id, oracle.latestRound());
        vm.warp(block.timestamp + vault.disputeWindow() + 1);
        vm.prank(trader);
        vault.exercise(id);

        uint256 lost = before - usdc.balanceOf(trader);
        assertEq(lost, paid, "loss is exactly the premium, never more");
    }

    function test_cannotExerciseDuringDisputeWindow() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 1e18, type(uint256).max);

        vm.warp(expiry - 1 hours);
        oracle.set(2000e18);
        vm.warp(expiry + 1);
        vault.settle(id, oracle.latestRound());

        vm.prank(trader);
        vm.expectRevert(HockeystickVault.DisputeWindowOpen.selector);
        vault.exercise(id);
    }

    function test_cannotSettleBeforeExpiryOrTwice() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 1e18, type(uint256).max);

        // Hoist the round read: an external call in the argument list would be
        // the "next call" expectRevert matches against.
        uint80 early = oracle.latestRound();
        vm.expectRevert(HockeystickVault.SeriesNotExpired.selector);
        vault.settle(id, early);

        vm.warp(expiry - 1 hours);
        oracle.set(3000e18);
        uint80 round = oracle.latestRound();
        vm.warp(expiry + 1);
        vault.settle(id, round);

        vm.expectRevert(HockeystickVault.AlreadySettled.selector);
        vault.settle(id, round);
    }

    function test_cannotBuyIntoASettledSeries() public {
        uint40 expiry = uint40(block.timestamp + 1 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 1e18, type(uint256).max);
        vm.warp(expiry + 1);
        vault.settle(id, oracle.latestRound());

        vm.prank(trader);
        vm.expectRevert(); // expired, so quoting fails first
        vault.buy(marketId, 3000e18, expiry, false, 1e18, type(uint256).max);
    }

    /* ----------------------------- settlement round ---------------------------- */

    function test_cannotSettleWithARoundPublishedAfterExpiry() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 1e18, type(uint256).max);

        vm.warp(expiry - 1 hours);
        oracle.set(2500e18); // round 2, just before expiry — the legitimate one
        uint80 atExpiry = oracle.latestRound();

        vm.warp(expiry + 1 days);
        oracle.set(1000e18); // round 3, well after expiry and far more valuable
        uint80 afterExpiry = oracle.latestRound();

        // Settling on the post-expiry round would hand the holder a price that
        // never prevailed while the option was alive.
        vm.expectRevert(
            abi.encodeWithSelector(
                HockeystickVault.RoundAfterExpiry.selector, block.timestamp, expiry
            )
        );
        vault.settle(id, afterExpiry);

        vault.settle(id, atExpiry);
        assertEq(vault.series(id).settlementPrice, 2500e18, "must settle at the expiry price");
    }

    function test_cannotCherryPickAnEarlierRound() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 1e18, type(uint256).max);

        vm.warp(block.timestamp + 10 days);
        oracle.set(1500e18); // round 2 — deep in the money, but not the expiry price
        uint80 stale = oracle.latestRound();

        vm.warp(block.timestamp + 10 days);
        vm.warp(expiry - 1 hours);
        oracle.set(2900e18); // round 3 — also before expiry, and the real one

        vm.warp(expiry + 1);

        // Round 2 is not the boundary round: round 3 still precedes expiry.
        vm.expectRevert();
        vault.settle(id, stale);

        vault.settle(id, oracle.latestRound());
        assertEq(vault.series(id).settlementPrice, 2900e18, "settles at the last pre-expiry price");
    }

    function test_cannotSettleWithAMissingRound() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 1e18, type(uint256).max);
        vm.warp(expiry + 1);

        vm.expectRevert(abi.encodeWithSelector(HockeystickVault.RoundNotFound.selector, uint80(999)));
        vault.settle(id, 999);
    }

    function test_rejectsSettlementOnADeadFeed() public {
        uint40 expiry = uint40(block.timestamp + 30 days);
        bytes32 id = vault.seriesId(marketId, 3000e18, expiry, false);

        vm.prank(trader);
        vault.buy(marketId, 3000e18, expiry, false, 1e18, type(uint256).max);

        // Feed publishes once, then goes silent for the whole tenor.
        oracle.set(2500e18);
        uint80 lastRound = oracle.latestRound();
        uint256 lastUpdate = block.timestamp;

        vm.warp(expiry + 1);

        vm.expectRevert(
            abi.encodeWithSelector(HockeystickVault.StaleSettlementRound.selector, lastUpdate, expiry)
        );
        vault.settle(id, lastRound);
    }

    /* --------------------------------- invariant ------------------------------- */

    function testFuzz_poolStaysSolventAcrossRandomFlow(
        uint256 size,
        uint256 strikePct,
        uint256 settlePct,
        bool isCall
    ) public {
        size = bound(size, 0.01e18, 50e18);
        strikePct = bound(strikePct, 50, 200); // strike from 50% to 200% of spot
        settlePct = bound(settlePct, 1, 1000); // settle from 1% to 1000% of spot

        uint256 strike = (3000e18 * strikePct) / 100;
        uint40 expiry = uint40(block.timestamp + 30 days);

        vm.prank(trader);
        try vault.buy(marketId, strike, expiry, isCall, size, type(uint256).max) {} catch {
            return; // cap or funding limits are legitimate refusals
        }
        _assertSolvent();

        // A live feed prints continuously; publish the settlement price just
        // before expiry, which is the round settlement will bind to.
        vm.warp(expiry - 1 hours);
        oracle.set((3000e18 * settlePct) / 100);
        vm.warp(expiry + 1);

        bytes32 id = vault.seriesId(marketId, strike, expiry, isCall);
        vault.settle(id, oracle.latestRound());
        _assertSolvent();

        vm.warp(block.timestamp + vault.disputeWindow() + 1);
        vm.prank(trader);
        vault.exercise(id);
        _assertSolvent();
    }
}
