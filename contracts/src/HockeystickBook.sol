// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as F} from "solady/utils/FixedPointMathLib.sol";

import {IOracle} from "./interfaces/IOracle.sol";

/// @title HockeystickBook
/// @notice Peer-to-peer, fully-collateralised, cash-settled European options.
///
/// @dev This is the vault's model with the counterparty swapped out. In
///      `HockeystickVault` the pool writes every option and therefore carries
///      every loss. Here a *user* writes the option, posts the collateral, and
///      keeps the premium — the protocol is never a counterparty and holds no
///      directional risk. What survives unchanged is the invariant that makes
///      the design worth having: every option is backed, at the moment it is
///      written, by collateral equal to its maximum possible payout. Nothing
///      can be liquidated because nothing is ever under-collateralised.
///
///      Calls carry a payout ceiling for the same reason they do in the vault:
///      an uncapped call has unbounded payoff and cannot be fully collateralised.
///      A call pays `min(spot, cap) - strike`, so economically each one is a
///      call spread. Puts need no cap — a zero underlying bounds them at strike.
///
///      Settlement is deliberately identical to the vault's, including the
///      boundary-round check, so the two contracts settle the same way against
///      the same feeds.
contract HockeystickBook is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /* ---------------------------------- types --------------------------------- */

    struct Market {
        IOracle oracle;
        uint64 payoutCapBps; // call payout ceiling as bps of strike, e.g. 20000 = 2x
        bool listed;
    }

    struct Series {
        uint32 marketId;
        uint40 expiry;
        bool isCall;
        uint256 strike; // WAD
        uint256 openInterest; // contracts written and filled, WAD
        uint256 lockPerContract; // collateral units locked per whole contract
        uint256 lockedCollateral; // collateral backing filled contracts
        uint256 settlementPrice; // WAD, set at settlement
        uint256 payoutPerContract; // collateral units, set at settlement
        uint40 settledAt;
        bool settled;
    }

    struct Offer {
        address writer;
        bytes32 series;
        uint256 size; // contracts still on offer, WAD
        uint256 askPerContract; // collateral units asked per whole contract
        uint256 lockedRemaining; // collateral still tied to the unfilled size
        bool cancelled;
    }

    /* --------------------------------- storage -------------------------------- */

    address public immutable collateral;
    uint256 private immutable _collateralScale; // 1e18 / 10**decimals

    /// @notice Collateral committed to written options and resting offers alike.
    ///         Never claimable by anyone but the writer or the holder it backs.
    uint256 public lockedCollateral;

    /// @notice Protocol fee on premium, in basis points, paid by the buyer.
    uint16 public feeBps = 100;

    /// @notice Fees taken so far and not yet collected by the owner.
    uint256 public accruedFees;

    /// @notice Delay after expiry before exercise opens, so a bad oracle print
    ///         can be challenged rather than silently paid out.
    uint32 public disputeWindow = 1 hours;

    /// @notice Longest tenor anyone may write.
    uint32 public maxTenor = 90 days;

    Market[] private _markets;
    mapping(bytes32 => Series) private _series;
    Offer[] private _offers;

    /// @notice Contracts held long, per series, per holder.
    mapping(bytes32 => mapping(address => uint256)) public longOf;

    /// @notice Contracts written short, per series, per writer.
    mapping(bytes32 => mapping(address => uint256)) public shortOf;

    /// @notice Offer ids resting against a series, for the front end to read.
    mapping(bytes32 => uint256[]) private _seriesOffers;

    /* --------------------------------- events --------------------------------- */

    event MarketListed(uint32 indexed marketId, address oracle, string description);
    event MarketUpdated(uint32 indexed marketId, uint64 payoutCapBps);
    event SeriesOpened(bytes32 indexed seriesId, uint32 indexed marketId, uint256 strike, uint40 expiry, bool isCall);
    event Offered(uint256 indexed offerId, bytes32 indexed seriesId, address indexed writer, uint256 size, uint256 ask);
    event Filled(uint256 indexed offerId, bytes32 indexed seriesId, address indexed buyer, uint256 size, uint256 premium, uint256 fee);
    event OfferCancelled(uint256 indexed offerId, uint256 sizeReturned, uint256 collateralReturned);
    event Settled(bytes32 indexed seriesId, uint256 settlementPrice, uint256 payoutPerContract);
    event Exercised(bytes32 indexed seriesId, address indexed holder, uint256 size, uint256 payout);
    event Reclaimed(bytes32 indexed seriesId, address indexed writer, uint256 size, uint256 returned);
    event ParamsUpdated(uint16 feeBps, uint32 disputeWindow, uint32 maxTenor);
    event FeesCollected(address indexed to, uint256 amount);

    /* --------------------------------- errors --------------------------------- */

    error MarketNotListed();
    error SeriesUnknown();
    error SeriesExpired();
    error SeriesNotExpired();
    error AlreadySettled();
    error NotSettled();
    error DisputeWindowOpen();
    error TenorTooLong();
    error ZeroAmount();
    error OfferUnknown();
    error OfferClosed();
    error NotWriter();
    error InsufficientOfferSize(uint256 wanted, uint256 available);
    error PremiumExceedsMax(uint256 premium, uint256 maxPremium);
    error SelfFill();
    error NoPosition();
    error BadParam();
    error RoundNotFound(uint80 roundId);
    error RoundAfterExpiry(uint256 updatedAt, uint40 expiry);
    error NotBoundaryRound(uint80 roundId, uint256 nextUpdatedAt);
    error StaleSettlementRound(uint256 updatedAt, uint40 expiry);

    /* ------------------------------- construction ------------------------------ */

    constructor(address collateral_, address owner_) {
        require(collateral_ != address(0) && owner_ != address(0), "zero addr");
        collateral = collateral_;

        uint8 d = ERC20(collateral_).decimals();
        require(d <= 18, "collateral decimals > 18");
        _collateralScale = 10 ** (18 - d);

        _initializeOwner(owner_);
    }

    /* ------------------------------- conversions ------------------------------- */

    /// @dev WAD -> collateral units, rounding down.
    function _fromWad(uint256 wad) internal view returns (uint256) {
        return wad / _collateralScale;
    }

    /// @dev WAD -> collateral units, rounding up. Used wherever rounding must
    ///      favour the collateral reserve rather than the party drawing on it.
    function _fromWadUp(uint256 wad) internal view returns (uint256) {
        return (wad + _collateralScale - 1) / _collateralScale;
    }

    /* ----------------------------------- admin --------------------------------- */

    function listMarket(address oracle, uint64 payoutCapBps) external onlyOwner returns (uint32 id) {
        if (oracle == address(0)) revert BadParam();
        // A cap at or below par would make every call worthless; require real upside.
        if (payoutCapBps <= 10_000) revert BadParam();

        // Refuse a feed that cannot price today, rather than listing a market
        // that can never settle.
        (uint256 p,) = IOracle(oracle).price();
        if (p == 0) revert BadParam();

        id = uint32(_markets.length);
        _markets.push(Market({oracle: IOracle(oracle), payoutCapBps: payoutCapBps, listed: true}));

        emit MarketListed(id, oracle, IOracle(oracle).description());
    }

    function setMarketParams(uint32 marketId, uint64 payoutCapBps) external onlyOwner {
        Market storage m = _markets[marketId];
        if (!m.listed) revert MarketNotListed();
        if (payoutCapBps <= 10_000) revert BadParam();

        // Series lock their cap at creation, so this only affects series opened
        // from here on. Existing books keep the terms they were written under.
        m.payoutCapBps = payoutCapBps;
        emit MarketUpdated(marketId, payoutCapBps);
    }

    function setParams(uint16 feeBps_, uint32 disputeWindow_, uint32 maxTenor_) external onlyOwner {
        if (feeBps_ > 500) revert BadParam(); // 5% ceiling, so fees can never be confiscatory
        if (maxTenor_ == 0) revert BadParam();

        feeBps = feeBps_;
        disputeWindow = disputeWindow_;
        maxTenor = maxTenor_;

        emit ParamsUpdated(feeBps_, disputeWindow_, maxTenor_);
    }

    function collectFees(address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert BadParam();
        amount = accruedFees;
        if (amount == 0) revert ZeroAmount();
        accruedFees = 0;
        collateral.safeTransfer(to, amount);
        emit FeesCollected(to, amount);
    }

    /* ---------------------------------- views ---------------------------------- */

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    function market(uint32 marketId) external view returns (Market memory) {
        return _markets[marketId];
    }

    function offerCount() external view returns (uint256) {
        return _offers.length;
    }

    function offer(uint256 offerId) external view returns (Offer memory) {
        return _offers[offerId];
    }

    function series(bytes32 id) external view returns (Series memory) {
        return _series[id];
    }

    function seriesId(uint32 marketId, uint256 strike, uint40 expiry, bool isCall) public pure returns (bytes32) {
        return keccak256(abi.encode(marketId, strike, expiry, isCall));
    }

    /// @notice Offer ids resting against a series, newest last. Includes filled
    ///         and cancelled ones — read `offer(id)` to filter.
    function seriesOffers(bytes32 id) external view returns (uint256[] memory) {
        return _seriesOffers[id];
    }

    /// @notice Cheapest live offer on a series, for a front end that wants one number.
    /// @return offerId The best offer, or type(uint256).max if the book is empty.
    /// @return ask Its price per whole contract, in collateral units.
    function bestAsk(bytes32 id) external view returns (uint256 offerId, uint256 ask) {
        uint256[] storage ids = _seriesOffers[id];
        offerId = type(uint256).max;
        for (uint256 i; i < ids.length; ++i) {
            Offer storage o = _offers[ids[i]];
            if (o.cancelled || o.size == 0) continue;
            if (offerId == type(uint256).max || o.askPerContract < ask) {
                offerId = ids[i];
                ask = o.askPerContract;
            }
        }
        if (offerId == type(uint256).max) ask = 0;
    }

    /// @notice Collateral a writer must post to offer `size` contracts.
    function lockRequired(uint32 marketId, uint256 strike, uint40 expiry, bool isCall, uint256 size)
        public
        view
        returns (uint256)
    {
        Market storage m = _markets[marketId];
        if (!m.listed) revert MarketNotListed();

        bytes32 id = seriesId(marketId, strike, expiry, isCall);
        uint256 per = _series[id].lockPerContract;
        if (per == 0) per = _fromWadUp(_maxPayoutPerContract(m.payoutCapBps, strike, isCall));

        return F.fullMulDivUp(per, size, 1e18);
    }

    /// @notice Premium and fee a buyer pays to take `size` from an offer.
    function fillCost(uint256 offerId, uint256 size) public view returns (uint256 premium, uint256 fee) {
        Offer storage o = _offers[offerId];
        premium = F.fullMulDivUp(o.askPerContract, size, 1e18);
        fee = (premium * feeBps) / 10_000;
    }

    /* --------------------------------- internals ------------------------------- */

    /// @dev Maximum payout of one whole contract, WAD. Exactly what a writer
    ///      must lock, and the number that makes insolvency impossible.
    function _maxPayoutPerContract(uint64 payoutCapBps, uint256 strike, bool isCall)
        internal
        pure
        returns (uint256)
    {
        if (!isCall) return strike; // a put bottoms out at a zero underlying
        return F.mulWad(strike, uint256(payoutCapBps) * 1e18 / 10_000) - strike;
    }

    function _payoutPerContractWad(Series storage s, uint64 payoutCapBps, uint256 spot)
        internal
        view
        returns (uint256)
    {
        if (s.isCall) {
            if (spot <= s.strike) return 0;
            uint256 cap = F.mulWad(s.strike, uint256(payoutCapBps) * 1e18 / 10_000);
            uint256 effective = spot > cap ? cap : spot;
            return effective - s.strike;
        }
        if (spot >= s.strike) return 0;
        return s.strike - spot;
    }

    /* ----------------------------------- write --------------------------------- */

    /// @notice Write `size` contracts and rest them on the book at `askPerContract`.
    ///
    /// @dev The writer posts the full maximum payout up front. That collateral
    ///      is theirs until someone fills the offer; from the moment of a fill
    ///      it belongs to the holder until settlement decides who gets it.
    ///
    /// @param askPerContract Premium demanded per whole contract, collateral units.
    function writeAndOffer(
        uint32 marketId,
        uint256 strike,
        uint40 expiry,
        bool isCall,
        uint256 size,
        uint256 askPerContract
    ) external nonReentrant returns (uint256 offerId, bytes32 id) {
        if (size == 0 || strike == 0 || askPerContract == 0) revert ZeroAmount();

        Market storage m = _markets[marketId];
        if (!m.listed) revert MarketNotListed();
        if (expiry <= block.timestamp) revert SeriesExpired();
        if (expiry - block.timestamp > maxTenor) revert TenorTooLong();

        id = seriesId(marketId, strike, expiry, isCall);
        Series storage s = _series[id];

        if (s.expiry == 0) {
            s.marketId = marketId;
            s.expiry = expiry;
            s.isCall = isCall;
            s.strike = strike;
            // Frozen at creation so every writer in this series locks the same
            // amount per contract. Settlement depends on that uniformity: it
            // returns `lockPerContract - payoutPerContract` to each short.
            s.lockPerContract = _fromWadUp(_maxPayoutPerContract(m.payoutCapBps, strike, isCall));
            emit SeriesOpened(id, marketId, strike, expiry, isCall);
        } else if (s.settled) {
            revert AlreadySettled();
        }

        uint256 lock = F.fullMulDivUp(s.lockPerContract, size, 1e18);
        if (lock == 0) revert ZeroAmount();

        collateral.safeTransferFrom(msg.sender, address(this), lock);
        lockedCollateral += lock;

        offerId = _offers.length;
        _offers.push(
            Offer({
                writer: msg.sender,
                series: id,
                size: size,
                askPerContract: askPerContract,
                lockedRemaining: lock,
                cancelled: false
            })
        );
        _seriesOffers[id].push(offerId);

        emit Offered(offerId, id, msg.sender, size, askPerContract);
    }

    /// @notice Withdraw an offer's unfilled remainder and reclaim its collateral.
    function cancelOffer(uint256 offerId) external nonReentrant returns (uint256 returned) {
        if (offerId >= _offers.length) revert OfferUnknown();
        Offer storage o = _offers[offerId];
        if (o.writer != msg.sender) revert NotWriter();
        if (o.cancelled || o.size == 0) revert OfferClosed();

        uint256 sizeReturned = o.size;
        returned = o.lockedRemaining;

        o.size = 0;
        o.lockedRemaining = 0;
        o.cancelled = true;

        lockedCollateral -= returned;
        collateral.safeTransfer(msg.sender, returned);

        emit OfferCancelled(offerId, sizeReturned, returned);
    }

    /* ------------------------------------ fill --------------------------------- */

    /// @notice Buy `size` contracts from a resting offer. Loss is capped at the
    ///         premium paid, here, as with the vault.
    /// @param maxPremium Slippage bound including fee; the call reverts above it.
    function fill(uint256 offerId, uint256 size, uint256 maxPremium)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (offerId >= _offers.length) revert OfferUnknown();
        if (size == 0) revert ZeroAmount();

        Offer storage o = _offers[offerId];
        if (o.cancelled || o.size == 0) revert OfferClosed();
        if (o.writer == msg.sender) revert SelfFill();
        if (size > o.size) revert InsufficientOfferSize(size, o.size);

        bytes32 id = o.series;
        Series storage s = _series[id];
        if (s.settled) revert AlreadySettled();
        if (block.timestamp >= s.expiry) revert SeriesExpired();

        (uint256 premium, uint256 fee) = fillCost(offerId, size);
        paid = premium + fee;
        if (paid == 0) revert ZeroAmount();
        if (paid > maxPremium) revert PremiumExceedsMax(paid, maxPremium);

        // Move exactly this fill's share of the writer's collateral out of the
        // offer and into the series, where it now backs a live obligation.
        // The final fill takes whatever remains, so rounding can never strand
        // dust or over-draw the offer.
        uint256 moved = size == o.size
            ? o.lockedRemaining
            : F.fullMulDiv(o.lockedRemaining, size, o.size);

        o.size -= size;
        o.lockedRemaining -= moved;

        s.lockedCollateral += moved;
        s.openInterest += size;
        longOf[id][msg.sender] += size;
        shortOf[id][o.writer] += size;

        accruedFees += fee;

        // Premium goes buyer -> writer directly; the protocol only keeps the fee.
        collateral.safeTransferFrom(msg.sender, address(this), paid);
        collateral.safeTransfer(o.writer, premium);

        emit Filled(offerId, id, msg.sender, size, premium, fee);
    }

    /* --------------------------------- settlement ------------------------------ */

    /// @notice Settle a series at its expiry price. Permissionless.
    ///
    /// @param roundId The oracle round that was current at expiry: the last
    ///        round published at or before `expiry`. The contract verifies this
    ///        by checking that the following round lands after expiry.
    ///
    /// @dev Settling against the *latest* price instead would let a holder wait
    ///      for spot to drift in their favour before settling, turning a
    ///      European option into a free American one at the writer's expense.
    function settle(bytes32 id, uint80 roundId) external nonReentrant {
        Series storage s = _series[id];
        if (s.expiry == 0) revert SeriesUnknown();
        if (s.settled) revert AlreadySettled();
        if (block.timestamp < s.expiry) revert SeriesNotExpired();

        Market storage m = _markets[s.marketId];

        (uint256 spot, uint256 updatedAt) = m.oracle.priceAt(roundId);
        if (spot == 0 || updatedAt == 0) revert RoundNotFound(roundId);
        if (updatedAt > s.expiry) revert RoundAfterExpiry(updatedAt, s.expiry);

        (, uint256 nextUpdatedAt) = m.oracle.priceAt(roundId + 1);
        if (nextUpdatedAt != 0 && nextUpdatedAt <= s.expiry) {
            revert NotBoundaryRound(roundId, nextUpdatedAt);
        }

        // A healthy feed publishes at least once per heartbeat, so the boundary
        // round sits close to expiry. If the feed died long before, settling on
        // its last print would use a price the market never saw at expiry.
        if (uint256(s.expiry) - updatedAt > m.oracle.maxAge()) {
            revert StaleSettlementRound(updatedAt, s.expiry);
        }

        uint256 perWad = _payoutPerContractWad(s, m.payoutCapBps, spot);
        uint256 per = _fromWad(perWad); // round down: never pay more than was locked

        // The lock is the ceiling by construction, but clamp rather than trust it.
        if (per > s.lockPerContract) per = s.lockPerContract;

        s.settlementPrice = spot;
        s.payoutPerContract = per;
        s.settled = true;
        s.settledAt = uint40(block.timestamp);

        emit Settled(id, spot, per);
    }

    /* --------------------------------- claiming -------------------------------- */

    /// @notice Claim the payout on a settled series, as a holder.
    function exercise(bytes32 id) external nonReentrant returns (uint256 payout) {
        Series storage s = _series[id];
        if (s.expiry == 0) revert SeriesUnknown();
        if (!s.settled) revert NotSettled();
        if (block.timestamp < uint256(s.settledAt) + disputeWindow) revert DisputeWindowOpen();

        uint256 size = longOf[id][msg.sender];
        if (size == 0) revert NoPosition();

        longOf[id][msg.sender] = 0;

        payout = F.fullMulDiv(s.payoutPerContract, size, 1e18);
        if (payout > s.lockedCollateral) payout = s.lockedCollateral;

        if (payout != 0) {
            s.lockedCollateral -= payout;
            lockedCollateral -= payout;
            collateral.safeTransfer(msg.sender, payout);
        }

        emit Exercised(id, msg.sender, size, payout);
    }

    /// @notice Reclaim collateral left over after settlement, as a writer.
    ///
    /// @dev A writer gets back what the holder was not owed. Since every writer
    ///      in a series locked the same amount per contract, that is exactly
    ///      `(lockPerContract - payoutPerContract) * size`.
    function reclaim(bytes32 id) external nonReentrant returns (uint256 returned) {
        Series storage s = _series[id];
        if (s.expiry == 0) revert SeriesUnknown();
        if (!s.settled) revert NotSettled();
        if (block.timestamp < uint256(s.settledAt) + disputeWindow) revert DisputeWindowOpen();

        uint256 size = shortOf[id][msg.sender];
        if (size == 0) revert NoPosition();

        shortOf[id][msg.sender] = 0;

        uint256 perContract = s.lockPerContract - s.payoutPerContract;
        returned = F.fullMulDiv(perContract, size, 1e18);
        if (returned > s.lockedCollateral) returned = s.lockedCollateral;

        if (returned != 0) {
            s.lockedCollateral -= returned;
            lockedCollateral -= returned;
            collateral.safeTransfer(msg.sender, returned);
        }

        emit Reclaimed(id, msg.sender, size, returned);
    }
}
