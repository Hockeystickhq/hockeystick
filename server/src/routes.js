import { Router } from 'express';
import { config } from './config.js';
import * as alpaca from './alpaca.js';
import { AlpacaError } from './alpaca.js';
import {
  STRATEGIES,
  buildOrder,
  parseOccSymbol,
  payoffCurve,
} from './strategies.js';

export const router = Router();

/** Wrap an async handler so rejections reach the error middleware. */
const route = (fn) => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

/* ---------------------------------- meta ---------------------------------- */

router.get('/health', (_req, res) => {
  res.json({
    ok: true,
    env: config.env,
    live: config.live,
    credentialsPresent: Boolean(config.keyId && config.secretKey),
  });
});

router.get('/strategies', (_req, res) => {
  res.json(
    Object.values(STRATEGIES).map((s) => ({
      id: s.id,
      name: s.name,
      blurb: s.blurb,
      contracts: s.contracts,
      direction: s.direction,
      requiresShares: s.requiresShares ?? 0,
    }))
  );
});

/* --------------------------------- account -------------------------------- */

router.get('/account', route(async (_req, res) => {
  const a = await alpaca.getAccount();
  res.json({
    env: config.env,
    accountNumber: a.account_number,
    status: a.status,
    equity: Number(a.equity),
    cash: Number(a.cash),
    buyingPower: Number(a.buying_power),
    optionsApprovedLevel: a.options_approved_level,
    optionsTradingLevel: a.options_trading_level,
  });
}));

router.get('/positions', route(async (_req, res) => {
  const positions = await alpaca.getPositions();
  res.json(positions.map((p) => ({
    symbol: p.symbol,
    assetClass: p.asset_class,
    qty: Number(p.qty),
    avgEntryPrice: Number(p.avg_entry_price),
    marketValue: Number(p.market_value),
    unrealizedPl: Number(p.unrealized_pl),
    unrealizedPlpc: Number(p.unrealized_plpc),
  })));
}));

/* -------------------------------- market data ------------------------------ */

router.get('/underlying/:symbol', route(async (req, res) => {
  const symbol = req.params.symbol.toUpperCase();
  const [quote, trade] = await Promise.all([
    alpaca.getStockQuote(symbol).catch(() => null),
    alpaca.getStockTrade(symbol).catch(() => null),
  ]);

  const bid = quote?.bp ?? null;
  const ask = quote?.ap ?? null;
  const last = trade?.p ?? null;
  const mid = bid && ask ? (bid + ask) / 2 : last;

  if (mid == null) {
    return res.status(404).json({ error: `No market data for ${symbol}.` });
  }
  res.json({ symbol, bid, ask, last, mid, asOf: trade?.t || quote?.t || null });
}));

/** Distinct expiries available for an underlying. */
router.get('/expirations/:symbol', route(async (req, res) => {
  const symbol = req.params.symbol.toUpperCase();
  const today = new Date().toISOString().slice(0, 10);
  const contracts = await alpaca.listContracts({
    underlying: symbol,
    expirationDateGte: today,
  });
  const expiries = [...new Set(contracts.map((c) => c.expiration_date))].sort();
  res.json({ symbol, expirations: expiries });
}));

/**
 * Option chain for one expiry, joined with live quotes and greeks and folded
 * into strike rows so the UI can render a conventional chain table.
 */
router.get('/chain/:symbol', route(async (req, res) => {
  const symbol = req.params.symbol.toUpperCase();
  const expiry = req.query.expiry;
  if (!expiry) return res.status(400).json({ error: 'An expiry (YYYY-MM-DD) is required.' });

  const snapshots = await alpaca.getChainSnapshots(symbol, { expiry });

  const rows = new Map();
  for (const [occ, snap] of Object.entries(snapshots)) {
    let parsed;
    try { parsed = parseOccSymbol(occ); } catch { continue; }
    if (parsed.expiry !== expiry) continue;

    const q = snap.latestQuote || {};
    const bid = q.bp ?? null;
    const ask = q.ap ?? null;

    const side = {
      symbol: occ,
      bid,
      ask,
      mid: bid != null && ask != null ? Number(((bid + ask) / 2).toFixed(4)) : null,
      last: snap.latestTrade?.p ?? null,
      impliedVolatility: snap.impliedVolatility ?? null,
      delta: snap.greeks?.delta ?? null,
      gamma: snap.greeks?.gamma ?? null,
      theta: snap.greeks?.theta ?? null,
      vega: snap.greeks?.vega ?? null,
    };

    if (!rows.has(parsed.strike)) rows.set(parsed.strike, { strike: parsed.strike });
    rows.get(parsed.strike)[parsed.type] = side;
  }

  res.json({
    symbol,
    expiry,
    strikes: [...rows.values()].sort((a, b) => a.strike - b.strike),
  });
}));

/* --------------------------------- pricer --------------------------------- */

router.post('/payoff', route(async (req, res) => {
  const { strategy, strike, premium, costBasis } = req.body || {};
  if (!STRATEGIES[strategy]) return res.status(400).json({ error: `Unknown strategy: ${strategy}` });

  const k = Number(strike);
  const p = Number(premium);
  if (!Number.isFinite(k) || k <= 0) return res.status(400).json({ error: 'A positive strike is required.' });
  if (!Number.isFinite(p) || p <= 0) return res.status(400).json({ error: 'A positive premium is required.' });

  const spec = STRATEGIES[strategy];
  const args = { strike: k, premium: p, costBasis: costBasis == null ? undefined : Number(costBasis) };

  res.json({
    strategy,
    curve: payoffCurve({ strategy, ...args }),
    maxLoss: spec.maxLoss(args),
    maxGain: spec.maxGain(args),
    breakEven: spec.breakEven(args),
  });
}));

/* --------------------------------- orders --------------------------------- */

router.get('/orders', route(async (req, res) => {
  const orders = await alpaca.listOrders(req.query.status || 'all', Number(req.query.limit) || 50);
  res.json(orders.map((o) => ({
    id: o.id,
    createdAt: o.created_at,
    symbol: o.symbol,
    orderClass: o.order_class,
    side: o.side,
    qty: Number(o.qty),
    filledQty: Number(o.filled_qty || 0),
    type: o.type,
    limitPrice: o.limit_price == null ? null : Number(o.limit_price),
    filledAvgPrice: o.filled_avg_price == null ? null : Number(o.filled_avg_price),
    status: o.status,
    legs: (o.legs || []).map((l) => ({
      symbol: l.symbol,
      side: l.side,
      qty: Number(l.qty),
      status: l.status,
      filledAvgPrice: l.filled_avg_price == null ? null : Number(l.filled_avg_price),
    })),
  })));
}));

router.post('/orders', route(async (req, res) => {
  const { strategy, symbols, qty, limitPrice, timeInForce, confirmLive } = req.body || {};

  // A live order spends real money. Require the client to say so explicitly, so
  // a misconfigured ALPACA_ENV can never quietly route real capital.
  if (config.live && confirmLive !== true) {
    return res.status(412).json({
      error: 'Server is in LIVE mode. Resend with confirmLive: true to place a real-money order.',
      env: 'live',
    });
  }

  const spec = STRATEGIES[strategy];
  if (!spec) return res.status(400).json({ error: `Unknown strategy: ${strategy}` });

  // A covered call is only covered if the shares are actually there. Check the
  // live position rather than trusting the client.
  if (spec.requiresShares) {
    const needed = spec.requiresShares * Number(qty || 1);
    const underlying = parseOccSymbol(symbols[0]).underlying;
    const positions = await alpaca.getPositions();
    const held = positions.find((p) => p.symbol === underlying && p.asset_class === 'us_equity');
    const heldQty = held ? Number(held.qty) : 0;

    if (heldQty < needed) {
      return res.status(422).json({
        error:
          `Covered call needs ${needed} shares of ${underlying}; you hold ${heldQty}. ` +
          'Selling this call uncovered would carry unlimited loss, so it was not routed.',
        held: heldQty,
        needed,
      });
    }
  }

  const order = buildOrder({ strategy, symbols, qty, limitPrice, timeInForce });
  const placed = await alpaca.submitOrder(order);

  res.status(201).json({
    id: placed.id,
    status: placed.status,
    orderClass: placed.order_class,
    submittedAt: placed.submitted_at,
    env: config.env,
    request: order,
  });
}));

router.delete('/orders/:id', route(async (req, res) => {
  await alpaca.cancelOrder(req.params.id);
  res.status(204).end();
}));

/* ------------------------------ error handling ----------------------------- */

router.use((err, _req, res, _next) => {
  if (err instanceof AlpacaError) {
    return res.status(err.status >= 400 && err.status < 600 ? err.status : 502).json({
      error: err.message,
      upstream: true,
    });
  }
  const clientFault = /required|must be|Unknown strategy|valid OCC|needs exactly/i.test(err.message);
  res.status(clientFault ? 400 : 500).json({ error: err.message });
});
