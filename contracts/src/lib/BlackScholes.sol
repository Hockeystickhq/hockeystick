// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as F} from "solady/utils/FixedPointMathLib.sol";

/// @title BlackScholes
/// @notice On-chain European option pricing in 18-decimal fixed point.
/// @dev Every input and output is WAD (1e18). Time is expressed in years, so
///      30 days is 0.0821e18. The risk-free rate is a signed WAD to allow a
///      negative carry.
library BlackScholes {
    int256 internal constant WAD = 1e18;

    /// @dev 1/sqrt(2), for the erf change of variable z = x/sqrt(2).
    int256 private constant INV_SQRT_2 = 707_106_781_186_547_524;

    /// @dev Abramowitz & Stegun 7.1.26 coefficients for erf.
    int256 private constant A1 = 254_829_592_000_000_000;
    int256 private constant A2 = -284_496_736_000_000_000;
    int256 private constant A3 = 1_421_413_741_000_000_000;
    int256 private constant A4 = -1_453_152_027_000_000_000;
    int256 private constant A5 = 1_061_405_429_000_000_000;
    int256 private constant P = 327_591_100_000_000_000;

    error BadInput();

    struct Inputs {
        uint256 spot; // underlying price, WAD
        uint256 strike; // strike price, WAD
        uint256 timeToExpiry; // years, WAD
        uint256 volatility; // annualised sigma, WAD (0.8e18 = 80%)
        int256 rate; // risk-free rate, signed WAD
    }

    /// @notice Standard normal CDF, accurate to about 1.5e-7 absolute.
    /// @dev Uses N(x) = 0.5 * (1 + erf(x / sqrt(2))) with the Abramowitz &
    ///      Stegun 7.1.26 rational approximation of erf, which is defined for
    ///      non-negative arguments; the negative half comes from erf's oddness.
    function normCdf(int256 x) internal pure returns (int256) {
        bool negative = x < 0;

        // z = |x| / sqrt(2)
        uint256 z = (F.abs(x) * uint256(INV_SQRT_2)) / uint256(WAD);

        // t = 1 / (1 + p*z)
        int256 t = (WAD * WAD) / (WAD + (int256(P) * int256(z)) / WAD);

        // poly = t*(a1 + t*(a2 + t*(a3 + t*(a4 + t*a5))))
        int256 poly = A5;
        poly = A4 + (t * poly) / WAD;
        poly = A3 + (t * poly) / WAD;
        poly = A2 + (t * poly) / WAD;
        poly = A1 + (t * poly) / WAD;
        poly = (t * poly) / WAD;

        // exp(-z^2); beyond ~9 sigma this underflows to zero and erf saturates.
        int256 zsq = (int256(z) * int256(z)) / WAD;
        int256 e = zsq > 41e18 ? int256(0) : F.expWad(-zsq);

        int256 erf = WAD - (poly * e) / WAD;
        if (erf < 0) erf = 0;
        if (erf > WAD) erf = WAD;

        int256 cdf = (WAD + erf) / 2;
        return negative ? WAD - cdf : cdf;
    }

    /// @notice d1 and d2 of the Black-Scholes formula.
    function d1d2(Inputs memory p) internal pure returns (int256 d1, int256 d2) {
        if (p.spot == 0 || p.strike == 0 || p.timeToExpiry == 0 || p.volatility == 0) revert BadInput();

        int256 sqrtT = int256(F.sqrtWad(p.timeToExpiry));
        int256 sigSqrtT = (int256(p.volatility) * sqrtT) / WAD;
        if (sigSqrtT == 0) revert BadInput();

        int256 lnSK = F.lnWad((int256(p.spot) * WAD) / int256(p.strike));
        int256 halfVar = (int256(p.volatility) * int256(p.volatility)) / (2 * WAD);
        int256 drift = ((p.rate + halfVar) * int256(p.timeToExpiry)) / WAD;

        d1 = ((lnSK + drift) * WAD) / sigSqrtT;
        d2 = d1 - sigSqrtT;
    }

    /// @notice Premium of a European call, in the same units as spot.
    function callPremium(Inputs memory p) internal pure returns (uint256) {
        (int256 d1, int256 d2) = d1d2(p);
        int256 discount = F.expWad(-(p.rate * int256(p.timeToExpiry)) / WAD);

        int256 term1 = (int256(p.spot) * normCdf(d1)) / WAD;
        int256 pvK = (int256(p.strike) * discount) / WAD;
        int256 term2 = (pvK * normCdf(d2)) / WAD;

        int256 c = term1 - term2;
        return c <= 0 ? 0 : uint256(c);
    }

    /// @notice Premium of a European put, via put-call parity.
    function putPremium(Inputs memory p) internal pure returns (uint256) {
        (int256 d1, int256 d2) = d1d2(p);
        int256 discount = F.expWad(-(p.rate * int256(p.timeToExpiry)) / WAD);

        int256 pvK = (int256(p.strike) * discount) / WAD;
        int256 term1 = (pvK * normCdf(-d2)) / WAD;
        int256 term2 = (int256(p.spot) * normCdf(-d1)) / WAD;

        int256 v = term1 - term2;
        return v <= 0 ? 0 : uint256(v);
    }

    /// @notice Premium for either side.
    function premium(Inputs memory p, bool isCall) internal pure returns (uint256) {
        return isCall ? callPremium(p) : putPremium(p);
    }

    /// @notice Delta of the option, signed WAD. Calls are positive, puts negative.
    function delta(Inputs memory p, bool isCall) internal pure returns (int256) {
        (int256 d1,) = d1d2(p);
        int256 nd1 = normCdf(d1);
        return isCall ? nd1 : nd1 - WAD;
    }
}
