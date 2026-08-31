// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as F} from "solady/utils/FixedPointMathLib.sol";

import {IOracle} from "./interfaces/IOracle.sol";
import {BlackScholes as BS} from "./lib/BlackScholes.sol";

/// @title HockeystickVault
/// @notice Fully-collateralised, cash-settled European options.
///
/// @dev The single invariant this contract exists to keep: every option ever
///      sold is backed, at the moment of sale, by collateral already sitting in
///      this contract equal to its maximum possible payout. The pool cannot
///      become insolvent because it never writes exposure it has not funded.
///
///      A cash-settled call has unbounded payoff, so it cannot be fully
///      collateralised as written. Every market therefore carries a payout cap,
///      expressed as a multiple of strike: a call pays `min(spot, cap) - strike`
///      rather than `spot - strike`. Economically each call is a call spread.
///      That is a deliberate, disclosed limitation — the alternative is partial
///      collateral, which reintroduces the liquidation risk this protocol is
///      built to remove.
///
///      Puts need no cap: their payoff is bounded below by a zero underlying,
///      so `strike` per contract is an exact bound.
contract HockeystickVault is ERC20, Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /* ---------------------------------- types --------------------------------- */

    struct Market {
        IOracle oracle;
        uint64 volatility; // annualised sigma, WAD
        uint64 payoutCapBps; // call payout ceiling as bps of strike, e.g. 20000 = 2x
        uint128 maxNotionalPerSeries; // exposure cap per series, in collateral units
        bool listed;
    }

    struct Series {
        uint32 marketId;
        uint40 expiry;
        bool isCall;
        uint256 strike; // WAD
        uint256 openInterest; // contracts, WAD
        uint256 lockedCollateral; // collateral units reserved for max payout
        uint256 settlementPrice; // WAD, set at settlement
        uint40 settledAt;
        bool settled;
    }

    /* --------------------------------- storage -------------------------------- */

    address public immutable collateral;
    uint256 private immutable _collateralScale; // 1e18 / 10**decimals

    /// @notice Collateral committed to outstanding options. Never withdrawable by LPs.
    uint256 public lockedCollateral;

    /// @notice Fee on premium, in basis points, accrued to the pool.
    uint16 public feeBps = 100;

    /// @notice Risk-free rate used for pricing, signed WAD.
    int64 public riskFreeRate = 0.04e18;

    /// @notice Delay after expiry before exercise opens, so a bad oracle print
    ///         can be challenged rather than silently paid out.
    uint32 public disputeWindow = 1 hours;

    /// @notice Longest tenor the pool will write.
    uint32 public maxTenor = 90 days;

    Market[] private _markets;
    mapping(bytes32 => Series) private _series;
    mapping(bytes32 => mapping(address => uint256)) public positionOf;

    /* --------------------------------- events --------------------------------- */

    event MarketListed(uint32 indexed marketId, address oracle, string description);
    event MarketUpdated(uint32 indexed marketId, uint64 volatility, uint64 payoutCapBps, uint128 maxNotional);
    event SeriesOpened(bytes32 indexed seriesId, uint32 indexed marketId, uint256 strike, uint40 expiry, bool isCall);
    event Bought(bytes32 indexed seriesId, address indexed buyer, uint256 size, uint256 premium, uint256 fee);
    event Settled(bytes32 indexed seriesId, uint256 settlementPrice, uint256 payoutPerContract, uint256 released);
    event Exercised(bytes32 indexed seriesId, address indexed holder, uint256 size, uint256 payout);
    event Deposited(address indexed lp, uint256 assets, uint256 shares);
    event Withdrawn(address indexed lp, uint256 shares, uint256 assets);
    event ParamsUpdated(uint16 feeBps, int64 rate, uint32 disputeWindow, uint32 maxTenor);

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
    error InsufficientFreeCollateral(uint256 needed, uint256 available);
    error ExposureCapReached(uint256 wouldBe, uint256 cap);
    error PremiumExceedsMax(uint256 premium, uint256 maxPremium);
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

    function name() public pure override returns (string memory) {
        return "Hockeystick LP";
    }

    function symbol() public pure override returns (string memory) {
        return "HSLP";
    }

    /* ------------------------------- conversions ------------------------------- */

    /// @dev Collateral units -> WAD.
    function _toWad(uint256 amount) internal view returns (uint256) {
        return amount * _collateralScale;
    }

    /// @dev WAD -> collateral units, rounding down.
    function _fromWad(uint256 wad) internal view returns (uint256) {
        return wad / _collateralScale;
    }

    /// @dev WAD -> collateral units, rounding up. Used wherever rounding must
    ///      favour the pool rather than the trader.
    function _fromWadUp(uint256 wad) internal view returns (uint256) {
        return (wad + _collateralScale - 1) / _collateralScale;
    }

    /* ----------------------------------- pool ---------------------------------- */

    /// @notice Total collateral owned by the pool, locked and free alike.
    function totalAssets() public view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    /// @notice Collateral available to back new options or fund withdrawals.
    function freeCollateral() public view returns (uint256) {
        uint256 total = totalAssets();
        return total > lockedCollateral ? total - lockedCollateral : 0;
    }

    /// @notice Deposit collateral and mint LP shares.
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();

        uint256 supply = totalSupply();
        // Shares are priced against assets held *before* this deposit lands.
        uint256 before = totalAssets();
        shares = supply == 0 ? assets : F.fullMulDiv(assets, supply, before);
        if (shares == 0) revert ZeroAmount();

        collateral.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposited(receiver, assets, shares);
    }

    /// @notice Burn LP shares and withdraw collateral.
    /// @dev Only free collateral can leave. Locked collateral belongs to option
    ///      holders until their series settles, so a withdrawal that would dip
    ///      into it reverts rather than silently undercollateralising the book.
    function withdraw(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();

        assets = F.fullMulDiv(shares, totalAssets(), totalSupply());
        if (assets == 0) revert ZeroAmount();

        uint256 free = freeCollateral();
        if (assets > free) revert InsufficientFreeCollateral(assets, free);

        _burn(msg.sender, shares);
        collateral.safeTransfer(receiver, assets);

        emit Withdrawn(msg.sender, shares, assets);
    }

    /* --------------------------------- markets --------------------------------- */

    function listMarket(address oracle, uint64 volatility, uint64 payoutCapBps, uint128 maxNotionalPerSeries)
        external
        onlyOwner
        returns (uint32 marketId)
    {
        if (oracle == address(0)) revert BadParam();
        if (volatility == 0 || volatility > 10e18) revert BadParam();
        if (payoutCapBps <= 10_000) revert BadParam(); // cap must exceed the strike

        _markets.push(
            Market({
                oracle: IOracle(oracle),
                volatility: volatility,
                payoutCapBps: payoutCapBps,
                maxNotionalPerSeries: maxNotionalPerSeries,
                listed: true
            })
        );
        marketId = uint32(_markets.length - 1);

        emit MarketListed(marketId, oracle, IOracle(oracle).description());
    }

    function setMarketParams(uint32 marketId, uint64 volatility, uint64 payoutCapBps, uint128 maxNotional)
        external
        onlyOwner
    {
        Market storage m = _markets[marketId];
        if (!m.listed) revert MarketNotListed();
        if (volatility == 0 || volatility > 10e18) revert BadParam();
        if (payoutCapBps <= 10_000) revert BadParam();

        m.volatility = volatility;
        m.payoutCapBps = payoutCapBps;
        m.maxNotionalPerSeries = maxNotional;

        emit MarketUpdated(marketId, volatility, payoutCapBps, maxNotional);
    }

    function setParams(uint16 feeBps_, int64 rate_, uint32 disputeWindow_, uint32 maxTenor_) external onlyOwner {
        if (feeBps_ > 1_000) revert BadParam(); // hard ceiling of 10%
        if (disputeWindow_ > 7 days) revert BadParam();
        if (maxTenor_ == 0 || maxTenor_ > 365 days) revert BadParam();

        feeBps = feeBps_;
        riskFreeRate = rate_;
        disputeWindow = disputeWindow_;
        maxTenor = maxTenor_;

        emit ParamsUpdated(feeBps_, rate_, disputeWindow_, maxTenor_);
    }

    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    function market(uint32 marketId) external view returns (Market memory) {
        return _markets[marketId];
    }

    /* ---------------------------------- series --------------------------------- */

    function seriesId(uint32 marketId, uint256 strike, uint40 expiry, bool isCall) public pure returns (bytes32) {
        return keccak256(abi.encode(marketId, strike, expiry, isCall));
    }

    function series(bytes32 id) external view returns (Series memory) {
        return _series[id];
    }

    /// @dev Maximum payout of one contract, in WAD. This is exactly what the
    ///      pool must lock, and the number that makes insolvency impossible.
    function _maxPayoutPerContract(Market storage m, uint256 strike, bool isCall)
        internal
        view
        returns (uint256)
    {
        if (!isCall) return strike; // put bottoms out at a zero underlying
        // call is capped at (cap - strike)
        return F.mulWad(strike, uint256(m.payoutCapBps) * 1e18 / 10_000) - strike;
    }

    /* ---------------------------------- pricing -------------------------------- */

    /// @notice Premium for `size` contracts of a series, before fee, in collateral units.
    function quote(uint32 marketId, uint256 strike, uint40 expiry, bool isCall, uint256 size)
        public
        view
        returns (uint256 premium, uint256 fee)
    {
        Market storage m = _markets[marketId];
        if (!m.listed) revert MarketNotListed();
        if (expiry <= block.timestamp) revert SeriesExpired();
        if (expiry - block.timestamp > maxTenor) revert TenorTooLong();

        (uint256 spot,) = m.oracle.price();

        uint256 tte = F.divWad(expiry - block.timestamp, 365 days);
        BS.Inputs memory p = BS.Inputs({
            spot: spot,
            strike: strike,
            timeToExpiry: tte,
            volatility: m.volatility,
            rate: riskFreeRate
        });

        uint256 unit = BS.premium(p, isCall);

        // A capped call is worth the vanilla call minus the call struck at the
        // cap. Charging the vanilla price for a capped payoff would overcharge
        // the buyer for upside the pool never sells.
        if (isCall) {
            uint256 cap = F.mulWad(strike, uint256(m.payoutCapBps) * 1e18 / 10_000);
            p.strike = cap;
            uint256 capLeg = BS.callPremium(p);
            unit = unit > capLeg ? unit - capLeg : 0;
        }

        uint256 gross = F.mulWad(unit, size);
        premium = _fromWadUp(gross); // round in the pool's favour
        fee = (premium * feeBps) / 10_000;
    }

    /* ----------------------------------- buy ----------------------------------- */

    /// @notice Buy `size` contracts. Loss is capped at the premium paid, here.
    /// @param maxPremium Slippage bound including fee; the call reverts above it.
    function buy(uint32 marketId, uint256 strike, uint40 expiry, bool isCall, uint256 size, uint256 maxPremium)
        external
        nonReentrant
        returns (bytes32 id, uint256 paid)
    {
        if (size == 0 || strike == 0) revert ZeroAmount();

        Market storage m = _markets[marketId];
        if (!m.listed) revert MarketNotListed();

        (uint256 premium, uint256 fee) = quote(marketId, strike, expiry, isCall, size);
        paid = premium + fee;
        if (paid == 0) revert ZeroAmount();
        if (paid > maxPremium) revert PremiumExceedsMax(paid, maxPremium);

        // Reserve the worst case before taking any money.
        uint256 lockNeeded = _fromWadUp(F.mulWad(_maxPayoutPerContract(m, strike, isCall), size));

        id = seriesId(marketId, strike, expiry, isCall);
        Series storage s = _series[id];

        if (s.expiry == 0) {
            s.marketId = marketId;
            s.expiry = expiry;
            s.isCall = isCall;
            s.strike = strike;
            emit SeriesOpened(id, marketId, strike, expiry, isCall);
        } else if (s.settled) {
            revert AlreadySettled();
        }

        if (m.maxNotionalPerSeries != 0) {
            uint256 wouldBe = s.lockedCollateral + lockNeeded;
            if (wouldBe > m.maxNotionalPerSeries) {
                revert ExposureCapReached(wouldBe, m.maxNotionalPerSeries);
            }
        }

        // The premium arrives before the lock is taken, so it counts toward
        // backing the very option it pays for.
        collateral.safeTransferFrom(msg.sender, address(this), paid);

        uint256 free = freeCollateral();
        if (lockNeeded > free) revert InsufficientFreeCollateral(lockNeeded, free);

        lockedCollateral += lockNeeded;
        s.lockedCollateral += lockNeeded;
        s.openInterest += size;
        positionOf[id][msg.sender] += size;

        emit Bought(id, msg.sender, size, premium, fee);
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
    ///      European option into a free American one at the pool's expense. The
    ///      round must therefore straddle expiry, which pins settlement to the
    ///      price that actually prevailed at that instant.
    function settle(bytes32 id, uint80 roundId) external nonReentrant {
        Series storage s = _series[id];
        if (s.expiry == 0) revert SeriesUnknown();
        if (s.settled) revert AlreadySettled();
        if (block.timestamp < s.expiry) revert SeriesNotExpired();

        Market storage m = _markets[s.marketId];

        (uint256 spot, uint256 updatedAt) = m.oracle.priceAt(roundId);
        if (spot == 0 || updatedAt == 0) revert RoundNotFound(roundId);
        if (updatedAt > s.expiry) revert RoundAfterExpiry(updatedAt, s.expiry);

        // The next round must fall after expiry, or an earlier round was passed
        // in to cherry-pick a more favourable price.
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

        s.settlementPrice = spot;
        s.settled = true;
        s.settledAt = uint40(block.timestamp);

        uint256 perContract = _payoutPerContract(s, m, spot);
        uint256 owed = _fromWad(F.mulWad(perContract, s.openInterest));
        if (owed > s.lockedCollateral) owed = s.lockedCollateral; // cannot exceed the reserve

        // Everything reserved beyond what holders are owed returns to the pool.
        uint256 released = s.lockedCollateral - owed;
        lockedCollateral -= released;
        s.lockedCollateral = owed;

        emit Settled(id, spot, perContract, released);
    }

    function _payoutPerContract(Series storage s, Market storage m, uint256 spot)
        internal
        view
        returns (uint256)
    {
        if (s.isCall) {
            if (spot <= s.strike) return 0;
            uint256 cap = F.mulWad(s.strike, uint256(m.payoutCapBps) * 1e18 / 10_000);
            uint256 effective = spot > cap ? cap : spot;
            return effective - s.strike;
        }
        if (spot >= s.strike) return 0;
        return s.strike - spot;
    }

    /// @notice Claim the payout on a settled series.
    function exercise(bytes32 id) external nonReentrant returns (uint256 payout) {
        Series storage s = _series[id];
        if (s.expiry == 0) revert SeriesUnknown();
        if (!s.settled) revert NotSettled();
        if (block.timestamp < uint256(s.settledAt) + disputeWindow) revert DisputeWindowOpen();

        uint256 size = positionOf[id][msg.sender];
        if (size == 0) revert NoPosition();

        Market storage m = _markets[s.marketId];
        uint256 perContract = _payoutPerContract(s, m, s.settlementPrice);

        positionOf[id][msg.sender] = 0;
        uint256 oi = s.openInterest;
        s.openInterest = oi - size;

        payout = _fromWad(F.mulWad(perContract, size));
        if (payout > s.lockedCollateral) payout = s.lockedCollateral;

        if (payout != 0) {
            s.lockedCollateral -= payout;
            lockedCollateral -= payout;
            collateral.safeTransfer(msg.sender, payout);
        }

        emit Exercised(id, msg.sender, size, payout);
    }

    /// @notice Release any dust left reserved once every holder has exercised.
    function sweep(bytes32 id) external {
        Series storage s = _series[id];
        if (!s.settled) revert NotSettled();
        if (s.openInterest != 0) revert NoPosition();

        uint256 dust = s.lockedCollateral;
        if (dust != 0) {
            s.lockedCollateral = 0;
            lockedCollateral -= dust;
        }
    }
}
