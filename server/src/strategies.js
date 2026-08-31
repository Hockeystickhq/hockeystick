/**
 * The four shapes from the Hockeystick book, expressed as Alpaca orders.
 *
 * Every position here is defined-risk or covered. Naked short options are
 * deliberately not supported: they carry unbounded loss, which is exactly what
 * Hockeystick exists to avoid.
 */

const OCC = /^([A-Z]{1,6})(\d{2})(\d{2})(\d{2})([CP])(\d{8})$/;

/** Decode an OCC symbol, e.g. AAPL250117C00150000. */
export function parseOccSymbol(symbol) {
  const m = OCC.exec(String(symbol).toUpperCase().trim());
  if (!m) throw new Error(`Not a valid OCC option symbol: ${symbol}`);
  const [, underlying, yy, mm, dd, cp, strike] = m;
  return {
    symbol: symbol.toUpperCase().trim(),
    underlying,
    expiry: `20${yy}-${mm}-${dd}`,
    type: cp === 'C' ? 'call' : 'put',
    strike: Number(strike) / 1000,
  };
}

/** Encode an OCC symbol from its parts. */
export function buildOccSymbol({ underlying, expiry, type, strike }) {
  const [y, m, d] = expiry.split('-');
  const cp = type.toLowerCase().startsWith('c') ? 'C' : 'P';
  const strike8 = String(Math.round(Number(strike) * 1000)).padStart(8, '0');
  return `${underlying.toUpperCase()}${y.slice(2)}${m}${d}${cp}${strike8}`;
}

/**
 * Strategy definitions.
 *
 * legs()      -> the option legs, as { symbol, side, intent, ratio }
 * requires    -> preconditions the caller must satisfy before routing
 * payoff()    -> profit/loss at expiry for a given underlying price
 */
export const STRATEGIES = {
  long_call: {
    id: 'long_call',
    name: 'Long call',
    blurb: 'Uncapped upside, loss capped at the premium.',
    contracts: 1,
    legs: ([call]) => [
      { symbol: call, side: 'buy', intent: 'buy_to_open', ratio: 1 },
    ],
    // debit: you pay to open
    direction: 'debit',
    payoff: (spot, { strike, premium }) =>
      (Math.max(spot - strike, 0) - premium) * 100,
    maxLoss: ({ premium }) => premium * 100,
    maxGain: () => Infinity,
    breakEven: ({ strike, premium }) => strike + premium,
  },

  long_put: {
    id: 'long_put',
    name: 'Long put',
    blurb: 'Downside exposure or a hedge on spot you already hold.',
    contracts: 1,
    legs: ([put]) => [
      { symbol: put, side: 'buy', intent: 'buy_to_open', ratio: 1 },
    ],
    direction: 'debit',
    payoff: (spot, { strike, premium }) =>
      (Math.max(strike - spot, 0) - premium) * 100,
    maxLoss: ({ premium }) => premium * 100,
    maxGain: ({ strike, premium }) => (strike - premium) * 100,
    breakEven: ({ strike, premium }) => strike - premium,
  },

  covered_call: {
    id: 'covered_call',
    name: 'Covered call',
    blurb: 'Sell upside against inventory you own to earn premium.',
    contracts: 1,
    legs: ([call]) => [
      { symbol: call, side: 'sell', intent: 'sell_to_open', ratio: 1 },
    ],
    direction: 'credit',
    // Requires 100 shares of the underlying per contract. Enforced in routes.js
    // against live positions, so this can never become a naked short.
    requiresShares: 100,
    payoff: (spot, { strike, premium, costBasis = strike }) =>
      (Math.min(spot, strike) - costBasis + premium) * 100,
    maxLoss: ({ costBasis, premium, strike }) =>
      ((costBasis ?? strike) - premium) * 100,
    maxGain: ({ strike, premium, costBasis = strike }) =>
      (strike - costBasis + premium) * 100,
    breakEven: ({ costBasis, premium, strike }) => (costBasis ?? strike) - premium,
  },

  straddle: {
    id: 'straddle',
    name: 'Straddle',
    blurb: 'A position on volatility itself, indifferent to direction.',
    contracts: 2,
    legs: ([call, put]) => [
      { symbol: call, side: 'buy', intent: 'buy_to_open', ratio: 1 },
      { symbol: put, side: 'buy', intent: 'buy_to_open', ratio: 1 },
    ],
    direction: 'debit',
    payoff: (spot, { strike, premium }) =>
      (Math.max(spot - strike, 0) + Math.max(strike - spot, 0) - premium) * 100,
    maxLoss: ({ premium }) => premium * 100,
    maxGain: () => Infinity,
    breakEven: ({ strike, premium }) => [strike - premium, strike + premium],
  },
};

/**
 * Turn a strategy plus chosen contracts into an Alpaca order body.
 *
 * Single-leg positions route as a simple order. Anything with more than one leg
 * routes as order_class "mleg", which fills the legs together or not at all —
 * important for a straddle, where one filled leg is a naked directional bet
 * rather than the volatility position you asked for.
 */
export function buildOrder({ strategy, symbols, qty = 1, limitPrice, timeInForce = 'day' }) {
  const spec = STRATEGIES[strategy];
  if (!spec) throw new Error(`Unknown strategy: ${strategy}`);

  if (!Array.isArray(symbols) || symbols.length !== spec.contracts) {
    throw new Error(
      `${spec.name} needs exactly ${spec.contracts} contract symbol(s), got ${symbols?.length ?? 0}`
    );
  }
  symbols.forEach(parseOccSymbol); // reject malformed symbols before routing

  const quantity = Number(qty);
  if (!Number.isInteger(quantity) || quantity < 1) {
    throw new Error(`Quantity must be a positive whole number of contracts, got ${qty}`);
  }

  const legs = spec.legs(symbols);

  // A limit price is required. Options books are wide and thin; a market order
  // on a two-cent-wide quote can fill far from the mid.
  const price = Number(limitPrice);
  if (!Number.isFinite(price) || price <= 0) {
    throw new Error('A positive limit price is required.');
  }

  if (legs.length === 1) {
    const [leg] = legs;
    return {
      symbol: leg.symbol,
      qty: String(quantity),
      side: leg.side,
      type: 'limit',
      limit_price: price.toFixed(2),
      time_in_force: timeInForce,
      position_intent: leg.intent,
      order_class: 'simple',
    };
  }

  return {
    qty: String(quantity),
    type: 'limit',
    limit_price: price.toFixed(2),
    time_in_force: timeInForce,
    order_class: 'mleg',
    legs: legs.map((leg) => ({
      symbol: leg.symbol,
      side: leg.side,
      ratio_qty: String(leg.ratio),
      position_intent: leg.intent,
    })),
  };
}

/** Payoff curve at expiry, for plotting. */
export function payoffCurve({ strategy, strike, premium, costBasis, points = 120, span = 0.4 }) {
  const spec = STRATEGIES[strategy];
  if (!spec) throw new Error(`Unknown strategy: ${strategy}`);

  const lo = Math.max(strike * (1 - span), 0);
  const hi = strike * (1 + span);
  const step = (hi - lo) / (points - 1);

  return Array.from({ length: points }, (_, i) => {
    const spot = lo + step * i;
    return { spot, pnl: spec.payoff(spot, { strike, premium, costBasis }) };
  });
}
