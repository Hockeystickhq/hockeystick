import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildOrder,
  buildOccSymbol,
  parseOccSymbol,
  STRATEGIES,
} from '../src/strategies.js';

const CALL = 'AAPL260117C00150000';
const PUT = 'AAPL260117P00150000';

test('OCC symbols round-trip', () => {
  const parsed = parseOccSymbol(CALL);
  assert.deepEqual(parsed, {
    symbol: CALL,
    underlying: 'AAPL',
    expiry: '2026-01-17',
    type: 'call',
    strike: 150,
  });
  assert.equal(buildOccSymbol(parsed), CALL);
});

test('fractional strikes survive encoding', () => {
  const sym = buildOccSymbol({ underlying: 'SPY', expiry: '2026-03-20', type: 'put', strike: 512.5 });
  assert.equal(sym, 'SPY260320P00512500');
  assert.equal(parseOccSymbol(sym).strike, 512.5);
});

test('malformed symbols are rejected before routing', () => {
  assert.throws(() => parseOccSymbol('NOTASYMBOL'), /valid OCC/);
  assert.throws(() => parseOccSymbol('AAPL260117X00150000'), /valid OCC/);
});

test('long call routes as a simple buy_to_open limit order', () => {
  const order = buildOrder({ strategy: 'long_call', symbols: [CALL], qty: 2, limitPrice: 3.25 });
  assert.equal(order.order_class, 'simple');
  assert.equal(order.symbol, CALL);
  assert.equal(order.side, 'buy');
  assert.equal(order.position_intent, 'buy_to_open');
  assert.equal(order.qty, '2');
  assert.equal(order.limit_price, '3.25');
  assert.equal(order.type, 'limit');
});

test('covered call routes as sell_to_open', () => {
  const order = buildOrder({ strategy: 'covered_call', symbols: [CALL], limitPrice: 1.1 });
  assert.equal(order.side, 'sell');
  assert.equal(order.position_intent, 'sell_to_open');
});

test('straddle routes as an all-or-nothing multi-leg order', () => {
  const order = buildOrder({ strategy: 'straddle', symbols: [CALL, PUT], qty: 1, limitPrice: 7.4 });
  assert.equal(order.order_class, 'mleg');
  assert.equal(order.legs.length, 2);
  assert.deepEqual(order.legs.map((l) => l.symbol), [CALL, PUT]);
  assert.ok(order.legs.every((l) => l.side === 'buy' && l.position_intent === 'buy_to_open'));
  assert.ok(order.legs.every((l) => l.ratio_qty === '1'));
  assert.equal(order.symbol, undefined, 'multi-leg orders carry legs, not a top-level symbol');
});

test('leg count must match the strategy', () => {
  assert.throws(() => buildOrder({ strategy: 'straddle', symbols: [CALL], limitPrice: 1 }),
    /needs exactly 2/);
  assert.throws(() => buildOrder({ strategy: 'long_call', symbols: [CALL, PUT], limitPrice: 1 }),
    /needs exactly 1/);
});

test('market orders are refused — a limit price is mandatory', () => {
  assert.throws(() => buildOrder({ strategy: 'long_call', symbols: [CALL] }), /limit price/);
  assert.throws(() => buildOrder({ strategy: 'long_call', symbols: [CALL], limitPrice: 0 }), /limit price/);
  assert.throws(() => buildOrder({ strategy: 'long_call', symbols: [CALL], limitPrice: -2 }), /limit price/);
});

test('fractional and zero quantities are refused', () => {
  for (const qty of [0, -1, 1.5, 'two']) {
    assert.throws(
      () => buildOrder({ strategy: 'long_call', symbols: [CALL], qty, limitPrice: 1 }),
      /whole number/,
      `qty ${qty} should be rejected`
    );
  }
});

test('long call risk is capped at the premium', () => {
  const spec = STRATEGIES.long_call;
  const args = { strike: 150, premium: 4 };
  assert.equal(spec.maxLoss(args), 400);
  assert.equal(spec.breakEven(args), 154);
  assert.equal(spec.payoff(0, args), -400, 'worst case is the premium, even at zero');
  assert.equal(spec.payoff(150, args), -400, 'at the money at expiry loses the premium');
  assert.equal(spec.payoff(154, args), 0, 'break-even nets zero');
  assert.equal(spec.payoff(200, args), 4600);
});

test('long put payoff is bounded by a zero underlying', () => {
  const spec = STRATEGIES.long_put;
  const args = { strike: 150, premium: 4 };
  assert.equal(spec.maxLoss(args), 400);
  assert.equal(spec.maxGain(args), 14600);
  assert.equal(spec.payoff(0, args), 14600);
  assert.equal(spec.payoff(200, args), -400);
});

test('straddle profits from either tail and has two break-evens', () => {
  const spec = STRATEGIES.straddle;
  const args = { strike: 100, premium: 8 };
  assert.deepEqual(spec.breakEven(args), [92, 108]);
  assert.equal(spec.payoff(100, args), -800, 'pinned at the strike is the worst case');
  assert.equal(spec.payoff(120, args), 1200);
  assert.equal(spec.payoff(80, args), 1200);
});

test('covered call caps gain at the strike', () => {
  const spec = STRATEGIES.covered_call;
  const args = { strike: 110, premium: 2, costBasis: 100 };
  assert.equal(spec.maxGain(args), 1200, 'appreciation to the strike plus premium');
  assert.equal(spec.payoff(200, args), 1200, 'upside beyond the strike is sold away');
  assert.equal(spec.payoff(100, args), 200, 'flat spot keeps the premium');
  assert.equal(spec.breakEven(args), 98);
});
