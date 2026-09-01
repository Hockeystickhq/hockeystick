// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {HockeystickBook} from "../src/HockeystickBook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract HockeystickBookTest is Test {
    HockeystickBook book;
    MockERC20 usdc;
    MockOracle oracle;

    address owner = address(0xA11CE);
    address writer = address(0xB0B);
    address buyer = address(0xCAFE);
    address other = address(0xD00D);

    uint256 constant USDC_ONE = 1e6; // 6-decimal collateral, as on most chains
    uint32 marketId;

    uint256 constant STRIKE = 3000e18;
    uint40 expiry;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracle(3000e18, "ETH / USD");

        vm.prank(owner);
        book = new HockeystickBook(address(usdc), owner);

        vm.prank(owner);
        marketId = book.listMarket(address(oracle), 20_000); // calls capped at 2x strike

        expiry = uint40(block.timestamp + 7 days);

        usdc.mint(writer, 10_000_000 * USDC_ONE);
        usdc.mint(buyer, 10_000_000 * USDC_ONE);
        usdc.mint(other, 10_000_000 * USDC_ONE);

        vm.prank(writer);
        usdc.approve(address(book), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(book), type(uint256).max);
        vm.prank(other);
        usdc.approve(address(book), type(uint256).max);
    }

    /// @dev The invariant the whole design exists to hold: the contract always
    ///      physically holds at least what it owes to writers and holders.
    function _assertSolvent() internal view {
        assertGe(
            usdc.balanceOf(address(book)),
            book.lockedCollateral() + book.accruedFees(),
            "INSOLVENT: balance < locked + fees"
        );
    }

    function _id(bool isCall) internal view returns (bytes32) {
        return book.seriesId(marketId, STRIKE, expiry, isCall);
    }

    /// @dev Write one put offer: `size` contracts at `ask` per contract.
    function _offerPut(uint256 size, uint256 ask) internal returns (uint256 offerId) {
        vm.prank(writer);
        (offerId,) = book.writeAndOffer(marketId, STRIKE, expiry, false, size, ask);
    }

    /// @dev Settle at `spot`, jumping past expiry and the dispute window.
    function _settleAt(bytes32 id, uint256 spot) internal {
        vm.warp(expiry - 1);
        oracle.set(spot); // this becomes the boundary round
        uint80 boundary = oracle.latestRound();

        vm.warp(expiry + 1);
        oracle.set(spot); // a later round, after expiry

        book.settle(id, boundary);
        vm.warp(block.timestamp + book.disputeWindow() + 1);
    }

    /* ---------------------------------- writing -------------------------------- */

    function test_writeLocksMaxPayout() public {
        uint256 before = usdc.balanceOf(writer);

        // 1 put at 3000 strike must lock exactly the strike: 3000 USDC.
        _offerPut(1e18, 50 * USDC_ONE);

        assertEq(before - usdc.balanceOf(writer), 3000 * USDC_ONE, "put locks strike");
        assertEq(book.lockedCollateral(), 3000 * USDC_ONE, "tracked as locked");
        _assertSolvent();
    }

    function test_writeCallLocksCappedPayout() public {
        // A call capped at 2x strike can pay at most (2*3000 - 3000) = 3000.
        vm.prank(writer);
        book.writeAndOffer(marketId, STRIKE, expiry, true, 1e18, 100 * USDC_ONE);
        assertEq(book.lockedCollateral(), 3000 * USDC_ONE, "call locks cap minus strike");
        _assertSolvent();
    }

    function test_cancelReturnsCollateral() public {
        uint256 before = usdc.balanceOf(writer);
        uint256 offerId = _offerPut(2e18, 50 * USDC_ONE);

        vm.prank(writer);
        uint256 returned = book.cancelOffer(offerId);

        assertEq(returned, 6000 * USDC_ONE, "full lock back");
        assertEq(usdc.balanceOf(writer), before, "writer made whole");
        assertEq(book.lockedCollateral(), 0, "nothing left locked");
    }

    function test_onlyWriterCanCancel() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        vm.expectRevert(HockeystickBook.NotWriter.selector);
        book.cancelOffer(offerId);
    }

    /* ---------------------------------- filling -------------------------------- */

    function test_fillMovesPremiumToWriterAndFeeToProtocol() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);

        uint256 writerBefore = usdc.balanceOf(writer);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        uint256 paid = book.fill(offerId, 1e18, type(uint256).max);

        uint256 premium = 50 * USDC_ONE;
        uint256 fee = premium / 100; // 100 bps

        assertEq(paid, premium + fee, "buyer pays premium plus fee");
        assertEq(buyerBefore - usdc.balanceOf(buyer), premium + fee, "buyer debited");
        assertEq(usdc.balanceOf(writer) - writerBefore, premium, "writer receives premium, not fee");
        assertEq(book.accruedFees(), fee, "protocol keeps the fee");

        bytes32 id = _id(false);
        assertEq(book.longOf(id, buyer), 1e18, "buyer is long");
        assertEq(book.shortOf(id, writer), 1e18, "writer is short");
        _assertSolvent();
    }

    function test_partialFillsSplitCollateralExactly() public {
        uint256 offerId = _offerPut(4e18, 50 * USDC_ONE);
        bytes32 id = _id(false);

        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);
        vm.prank(other);
        book.fill(offerId, 3e18, type(uint256).max);

        HockeystickBook.Offer memory o = book.offer(offerId);
        assertEq(o.size, 0, "offer fully consumed");
        assertEq(o.lockedRemaining, 0, "no collateral stranded in the offer");

        HockeystickBook.Series memory s = book.series(id);
        assertEq(s.lockedCollateral, 12_000 * USDC_ONE, "all four contracts backed");
        assertEq(s.openInterest, 4e18, "open interest tracks fills");
        _assertSolvent();
    }

    function test_cannotFillMoreThanOffered() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(HockeystickBook.InsufficientOfferSize.selector, 2e18, 1e18)
        );
        book.fill(offerId, 2e18, type(uint256).max);
    }

    function test_cannotFillOwnOffer() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(writer);
        vm.expectRevert(HockeystickBook.SelfFill.selector);
        book.fill(offerId, 1e18, type(uint256).max);
    }

    function test_maxPremiumBoundsSlippage() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                HockeystickBook.PremiumExceedsMax.selector, 50 * USDC_ONE + 5 * USDC_ONE / 10, 1
            )
        );
        book.fill(offerId, 1e18, 1);
    }

    function test_cannotFillAfterExpiry() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.warp(expiry + 1);
        vm.prank(buyer);
        vm.expectRevert(HockeystickBook.SeriesExpired.selector);
        book.fill(offerId, 1e18, type(uint256).max);
    }

    /* -------------------------------- settlement ------------------------------- */

    function test_putInTheMoneyPaysHolderAndRefundsRest() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        bytes32 id = _id(false);
        _settleAt(id, 2500e18); // 500 in the money

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 writerBefore = usdc.balanceOf(writer);

        vm.prank(buyer);
        uint256 payout = book.exercise(id);
        vm.prank(writer);
        uint256 returned = book.reclaim(id);

        assertEq(payout, 500 * USDC_ONE, "holder paid the intrinsic value");
        assertEq(returned, 2500 * USDC_ONE, "writer keeps the unused lock");
        assertEq(payout + returned, 3000 * USDC_ONE, "the lock is fully distributed");
        assertEq(usdc.balanceOf(buyer) - buyerBefore, 500 * USDC_ONE, "buyer received it");
        assertEq(usdc.balanceOf(writer) - writerBefore, 2500 * USDC_ONE, "writer received it");
        assertEq(book.lockedCollateral(), 0, "series fully unwound");
        _assertSolvent();
    }

    function test_putOutOfTheMoneyReturnsEverythingToWriter() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        bytes32 id = _id(false);
        _settleAt(id, 3500e18); // put expires worthless

        vm.prank(buyer);
        uint256 payout = book.exercise(id);
        vm.prank(writer);
        uint256 returned = book.reclaim(id);

        assertEq(payout, 0, "nothing owed");
        assertEq(returned, 3000 * USDC_ONE, "writer gets the whole lock back");
        _assertSolvent();
    }

    function test_callPayoutIsCapped() public {
        vm.prank(writer);
        (uint256 offerId,) = book.writeAndOffer(marketId, STRIKE, expiry, true, 1e18, 100 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        bytes32 id = _id(true);
        _settleAt(id, 12_000e18); // far above the 2x cap

        vm.prank(buyer);
        uint256 payout = book.exercise(id);

        // Capped at 2x strike: pays (6000 - 3000), not (12000 - 3000).
        assertEq(payout, 3000 * USDC_ONE, "payout clamped at the cap");
        _assertSolvent();
    }

    function test_settlementSplitsAcrossManyHolders() public {
        uint256 offerId = _offerPut(3e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);
        vm.prank(other);
        book.fill(offerId, 2e18, type(uint256).max);

        bytes32 id = _id(false);
        _settleAt(id, 2700e18); // 300 in the money

        vm.prank(buyer);
        uint256 a = book.exercise(id);
        vm.prank(other);
        uint256 b = book.exercise(id);
        vm.prank(writer);
        uint256 back = book.reclaim(id);

        assertEq(a, 300 * USDC_ONE, "one contract");
        assertEq(b, 600 * USDC_ONE, "two contracts");
        assertEq(a + b + back, 9000 * USDC_ONE, "the whole lock is accounted for");
        assertEq(book.lockedCollateral(), 0, "nothing left over");
        _assertSolvent();
    }

    function test_twoWritersEachReclaimTheirOwnShare() public {
        uint256 o1 = _offerPut(1e18, 50 * USDC_ONE);

        vm.prank(other);
        (uint256 o2,) = book.writeAndOffer(marketId, STRIKE, expiry, false, 2e18, 60 * USDC_ONE);

        vm.prank(buyer);
        book.fill(o1, 1e18, type(uint256).max);
        vm.prank(buyer);
        book.fill(o2, 2e18, type(uint256).max);

        bytes32 id = _id(false);
        _settleAt(id, 2800e18); // 200 in the money

        vm.prank(writer);
        uint256 r1 = book.reclaim(id);
        vm.prank(other);
        uint256 r2 = book.reclaim(id);
        vm.prank(buyer);
        uint256 payout = book.exercise(id);

        assertEq(r1, 2800 * USDC_ONE, "writer one: 3000 - 200");
        assertEq(r2, 5600 * USDC_ONE, "writer two: twice that");
        assertEq(payout, 600 * USDC_ONE, "holder: 200 x 3");
        assertEq(r1 + r2 + payout, 9000 * USDC_ONE, "conserved");
        _assertSolvent();
    }

    /* ---------------------------------- guards --------------------------------- */

    function test_cannotSettleBeforeExpiry() public {
        _offerPut(1e18, 50 * USDC_ONE);
        bytes32 id = _id(false); // resolve before expectRevert, it is a call too
        vm.expectRevert(HockeystickBook.SeriesNotExpired.selector);
        book.settle(id, 1);
    }

    function test_cannotSettleTwice() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        bytes32 id = _id(false);
        _settleAt(id, 2500e18);

        vm.expectRevert(HockeystickBook.AlreadySettled.selector);
        book.settle(id, 1);
    }

    function test_cannotCherryPickAnEarlierRound() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        // An early, favourable print, then a later one still before expiry.
        vm.warp(expiry - 3 hours);
        oracle.set(1000e18);
        uint80 early = oracle.latestRound();

        vm.warp(expiry - 1);
        oracle.set(2900e18);
        uint256 boundaryTime = block.timestamp;

        vm.warp(expiry + 1);
        oracle.set(2900e18);

        bytes32 id = _id(false);
        vm.expectRevert(
            abi.encodeWithSelector(HockeystickBook.NotBoundaryRound.selector, early, boundaryTime)
        );
        book.settle(id, early);
    }

    function test_exerciseBlockedDuringDisputeWindow() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        bytes32 id = _id(false);
        vm.warp(expiry - 1);
        oracle.set(2500e18);
        uint80 boundary = oracle.latestRound();
        vm.warp(expiry + 1);
        oracle.set(2500e18);
        book.settle(id, boundary);

        vm.prank(buyer);
        vm.expectRevert(HockeystickBook.DisputeWindowOpen.selector);
        book.exercise(id);
    }

    function test_cannotExerciseTwice() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        bytes32 id = _id(false);
        _settleAt(id, 2500e18);

        vm.prank(buyer);
        book.exercise(id);
        vm.prank(buyer);
        vm.expectRevert(HockeystickBook.NoPosition.selector);
        book.exercise(id);
    }

    function test_cannotWriteBeyondMaxTenor() public {
        uint40 far = uint40(block.timestamp + 200 days);
        vm.prank(writer);
        vm.expectRevert(HockeystickBook.TenorTooLong.selector);
        book.writeAndOffer(marketId, STRIKE, far, false, 1e18, 50 * USDC_ONE);
    }

    function test_ownerCollectsOnlyFees() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        uint256 fee = book.accruedFees();
        assertGt(fee, 0, "fee accrued");

        vm.prank(owner);
        uint256 got = book.collectFees(owner);

        assertEq(got, fee, "owner takes the fee");
        assertEq(book.accruedFees(), 0, "and no more");
        // The writer's collateral is untouched by the fee sweep.
        assertEq(book.lockedCollateral(), 3000 * USDC_ONE, "locks intact");
        _assertSolvent();
    }

    function test_ownerCannotTouchLockedCollateral() public {
        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        vm.prank(owner);
        book.collectFees(owner);

        // Everything still owed is still here.
        assertGe(usdc.balanceOf(address(book)), book.lockedCollateral(), "locks survive");
    }

    /* ----------------------------------- views --------------------------------- */

    function test_bestAskSkipsCancelledAndEmpty() public {
        uint256 cheap = _offerPut(1e18, 40 * USDC_ONE);
        _offerPut(1e18, 60 * USDC_ONE);

        bytes32 id = _id(false);
        (uint256 offerId, uint256 ask) = book.bestAsk(id);
        assertEq(offerId, cheap, "cheapest wins");
        assertEq(ask, 40 * USDC_ONE);

        vm.prank(writer);
        book.cancelOffer(cheap);

        (offerId, ask) = book.bestAsk(id);
        assertEq(ask, 60 * USDC_ONE, "falls through to the next");
    }

    function test_lockRequiredMatchesWhatWriteTakes() public {
        uint256 quoted = book.lockRequired(marketId, STRIKE, expiry, false, 3e18);
        uint256 before = usdc.balanceOf(writer);
        _offerPut(3e18, 50 * USDC_ONE);
        assertEq(before - usdc.balanceOf(writer), quoted, "quote matches the charge");
    }

    /* ----------------------------------- fuzz ---------------------------------- */

    /// @dev However the price lands, holder and writer between them can never
    ///      draw more than was locked.
    function testFuzz_payoutNeverExceedsLock(uint256 spot) public {
        spot = bound(spot, 1e18, 100_000e18);

        uint256 offerId = _offerPut(1e18, 50 * USDC_ONE);
        vm.prank(buyer);
        book.fill(offerId, 1e18, type(uint256).max);

        bytes32 id = _id(false);
        _settleAt(id, spot);

        vm.prank(buyer);
        uint256 payout = book.exercise(id);
        vm.prank(writer);
        uint256 returned = book.reclaim(id);

        assertLe(payout + returned, 3000 * USDC_ONE, "never over-draws the lock");
        _assertSolvent();
    }

    /// @dev Any split of fills across two buyers leaves the offer empty and the
    ///      series exactly backed.
    function testFuzz_partialFillsConserveCollateral(uint256 first) public {
        uint256 size = 5e18;
        first = bound(first, 1, size - 1);

        uint256 offerId = _offerPut(size, 50 * USDC_ONE);

        vm.prank(buyer);
        book.fill(offerId, first, type(uint256).max);
        vm.prank(other);
        book.fill(offerId, size - first, type(uint256).max);

        HockeystickBook.Offer memory o = book.offer(offerId);
        assertEq(o.lockedRemaining, 0, "no dust stranded");

        HockeystickBook.Series memory s = book.series(_id(false));
        assertEq(s.lockedCollateral, 15_000 * USDC_ONE, "series holds the whole lock");
        _assertSolvent();
    }
}
