// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {BlackScholes as BS} from "../src/lib/BlackScholes.sol";
import {BSHarness} from "./BSHarness.sol";

contract BlackScholesTest is Test {
    int256 constant WAD = 1e18;

    function _in(uint256 s, uint256 k, uint256 t, uint256 v, int256 r)
        internal
        pure
        returns (BS.Inputs memory)
    {
        return BS.Inputs({spot: s, strike: k, timeToExpiry: t, volatility: v, rate: r});
    }

    /* --------------------------------- normCdf -------------------------------- */

    function test_normCdf_symmetryAtZero() public pure {
        // The A&S coefficients sum to 0.999999999 rather than exactly 1, so N(0)
        // carries a ~5e-10 residual. That is far inside the approximation's
        // documented 1.5e-7 error and worth nothing at any realistic notional.
        assertApproxEqAbs(BS.normCdf(0), 0.5e18, 1e9, "N(0) ~= 0.5");
    }

    function test_normCdf_knownValues() public pure {
        // Reference values from the standard normal table, 1e-6 tolerance.
        assertApproxEqAbs(BS.normCdf(1e18), 0.841344746e18, 1e12, "N(1)");
        assertApproxEqAbs(BS.normCdf(-1e18), 0.158655254e18, 1e12, "N(-1)");
        assertApproxEqAbs(BS.normCdf(1.96e18), 0.975002105e18, 1e12, "N(1.96)");
        assertApproxEqAbs(BS.normCdf(-1.96e18), 0.024997895e18, 1e12, "N(-1.96)");
        assertApproxEqAbs(BS.normCdf(2.5e18), 0.993790335e18, 1e12, "N(2.5)");
    }

    function test_normCdf_isMonotonicAndBounded() public pure {
        int256 prev = 0;
        for (int256 x = -5e18; x <= 5e18; x += 5e17) {
            int256 c = BS.normCdf(x);
            assertGe(c, 0, "cdf below 0");
            assertLe(c, WAD, "cdf above 1");
            assertGe(c, prev, "cdf must be non-decreasing");
            prev = c;
        }
    }

    function testFuzz_normCdf_complementarity(int256 x) public pure {
        x = bound(x, -6e18, 6e18);
        // N(x) + N(-x) must equal 1.
        assertApproxEqAbs(BS.normCdf(x) + BS.normCdf(-x), WAD, 1e10, "N(x)+N(-x) != 1");
    }

    /* -------------------------------- premiums -------------------------------- */

    function test_atTheMoney_matchesReference() public pure {
        // S=100 K=100 T=1y sigma=20% r=5%  ->  call 10.4506, put 5.5735
        BS.Inputs memory p = _in(100e18, 100e18, 1e18, 0.2e18, 0.05e18);
        assertApproxEqRel(BS.callPremium(p), 10.450583572185565e18, 1e14, "call");
        assertApproxEqRel(BS.putPremium(p), 5.573526022256971e18, 1e14, "put");
    }

    function test_zeroRate_callEqualsPutAtTheMoney() public pure {
        // With r=0 and S=K, put-call parity forces call == put.
        BS.Inputs memory p = _in(100e18, 100e18, 1e18, 0.2e18, 0);
        assertApproxEqRel(BS.callPremium(p), BS.putPremium(p), 1e12, "atm parity");
        assertApproxEqRel(BS.callPremium(p), 7.965567455405804e18, 1e14, "value");
    }

    function test_putCallParity() public pure {
        // C - P = S - K*exp(-rT)
        BS.Inputs memory p = _in(120e18, 100e18, 0.5e18, 0.6e18, 0.03e18);
        uint256 c = BS.callPremium(p);
        uint256 put = BS.putPremium(p);

        // K*exp(-rT) with r=3%, T=0.5 -> 100 * exp(-0.015)
        uint256 pvK = 98.51119396030626e18;
        int256 lhs = int256(c) - int256(put);
        int256 rhs = int256(p.spot) - int256(pvK);
        assertApproxEqAbs(lhs, rhs, 1e14, "put-call parity violated");
    }

    function test_deepInTheMoneyCall_approachesIntrinsic() public pure {
        BS.Inputs memory p = _in(1000e18, 100e18, 0.08e18, 0.5e18, 0);
        // Intrinsic is 900; a deep ITM short-dated call is worth essentially that.
        assertApproxEqRel(BS.callPremium(p), 900e18, 1e15, "deep ITM call");
    }

    function test_deepOutOfTheMoney_isNearlyWorthless() public pure {
        BS.Inputs memory p = _in(100e18, 1000e18, 0.02e18, 0.4e18, 0);
        assertLt(BS.callPremium(p), 1e12, "far OTM call should be dust");
    }

    function test_premiumRisesWithVolatility() public pure {
        uint256 prev;
        for (uint256 v = 0.1e18; v <= 2e18; v += 0.1e18) {
            uint256 c = BS.callPremium(_in(100e18, 100e18, 0.25e18, v, 0));
            assertGt(c, prev, "vega must be positive");
            prev = c;
        }
    }

    function test_premiumRisesWithTime() public pure {
        uint256 prev;
        for (uint256 t = 0.01e18; t <= 2e18; t += 0.1e18) {
            uint256 c = BS.callPremium(_in(100e18, 100e18, t, 0.5e18, 0));
            assertGt(c, prev, "longer dated must cost more");
            prev = c;
        }
    }

    /* ---------------------------------- bounds -------------------------------- */

    function testFuzz_callWithinNoArbitrageBounds(uint256 spot, uint256 strike, uint256 vol) public pure {
        spot = bound(spot, 1e18, 1_000_000e18);
        strike = bound(strike, 1e18, 1_000_000e18);
        vol = bound(vol, 0.01e18, 5e18);

        BS.Inputs memory p = _in(spot, strike, 0.25e18, vol, 0);
        uint256 c = BS.callPremium(p);

        // max(S-K, 0) <= C <= S  for a zero-rate European call.
        uint256 intrinsic = spot > strike ? spot - strike : 0;
        assertGe(c + 1e12, intrinsic, "call below intrinsic");
        assertLe(c, spot + 1e12, "call above spot");
    }

    function testFuzz_putWithinNoArbitrageBounds(uint256 spot, uint256 strike, uint256 vol) public pure {
        spot = bound(spot, 1e18, 1_000_000e18);
        strike = bound(strike, 1e18, 1_000_000e18);
        vol = bound(vol, 0.01e18, 5e18);

        BS.Inputs memory p = _in(spot, strike, 0.25e18, vol, 0);
        uint256 v = BS.putPremium(p);

        uint256 intrinsic = strike > spot ? strike - spot : 0;
        assertGe(v + 1e12, intrinsic, "put below intrinsic");
        assertLe(v, strike + 1e12, "put above strike");
    }

    /* ----------------------------------- delta -------------------------------- */

    function test_deltaSignAndRange() public pure {
        BS.Inputs memory p = _in(100e18, 100e18, 0.5e18, 0.4e18, 0);
        int256 dc = BS.delta(p, true);
        int256 dp = BS.delta(p, false);

        assertGt(dc, 0, "call delta positive");
        assertLt(dc, WAD, "call delta below 1");
        assertLt(dp, 0, "put delta negative");
        assertGt(dp, -WAD, "put delta above -1");
        assertApproxEqAbs(dc - dp, WAD, 1e10, "delta_call - delta_put == 1");
    }

    function test_rejectsDegenerateInputs() public {
        BSHarness h = new BSHarness();

        vm.expectRevert(BS.BadInput.selector);
        h.callPremium(0, 100e18, 1e18, 0.2e18, 0);

        vm.expectRevert(BS.BadInput.selector);
        h.callPremium(100e18, 100e18, 0, 0.2e18, 0);

        vm.expectRevert(BS.BadInput.selector);
        h.callPremium(100e18, 100e18, 1e18, 0, 0);
    }
}
