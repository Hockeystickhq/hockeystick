import { config, assertCredentials } from './config.js';

/**
 * Thin Alpaca REST client.
 *
 * Credentials live only in this process. The browser never sees them — it talks
 * to our own routes, and we sign the upstream request here.
 */

function headers() {
  assertCredentials();
  return {
    'APCA-API-KEY-ID': config.keyId,
    'APCA-API-SECRET-KEY': config.secretKey,
    'Content-Type': 'application/json',
    accept: 'application/json',
  };
}

export class AlpacaError extends Error {
  constructor(message, status, body) {
    super(message);
    this.name = 'AlpacaError';
    this.status = status;
    this.body = body;
  }
}

async function request(base, path, { method = 'GET', query, body } = {}) {
  const url = new URL(path, base);
  for (const [k, v] of Object.entries(query || {})) {
    if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, String(v));
  }

  const res = await fetch(url, {
    method,
    headers: headers(),
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await res.text();
  let parsed = null;
  try { parsed = text ? JSON.parse(text) : null; } catch { parsed = { raw: text }; }

  if (!res.ok) {
    // Alpaca returns { message, code } on failure. Surface the message so the UI
    // can show something better than "500".
    const detail = parsed?.message || parsed?.raw || res.statusText;
    throw new AlpacaError(detail, res.status, parsed);
  }
  return parsed;
}

const trading = (path, opts) => request(config.tradingBase, path, opts);
const data = (path, opts) => request(config.dataBase, path, opts);

/* ---------------------------------- account --------------------------------- */

export const getAccount = () => trading('/v2/account');
export const getPositions = () => trading('/v2/positions');

/* --------------------------------- reference -------------------------------- */

/**
 * Tradable option contracts for an underlying. Alpaca paginates via page_token;
 * we follow it so a full expiry is returned in one call.
 */
export async function listContracts({
  underlying,
  expirationDate,
  expirationDateGte,
  expirationDateLte,
  type,
  strikeGte,
  strikeLte,
  limit = 10000,
} = {}) {
  const out = [];
  let pageToken;

  do {
    const page = await trading('/v2/options/contracts', {
      query: {
        underlying_symbols: underlying,
        expiration_date: expirationDate,
        expiration_date_gte: expirationDateGte,
        expiration_date_lte: expirationDateLte,
        type,
        strike_price_gte: strikeGte,
        strike_price_lte: strikeLte,
        status: 'active',
        limit: 1000,
        page_token: pageToken,
      },
    });
    out.push(...(page?.option_contracts || []));
    pageToken = page?.next_page_token || undefined;
  } while (pageToken && out.length < limit);

  return out;
}

/* ----------------------------------- data ----------------------------------- */

/** Latest NBBO quote for the underlying equity. */
export async function getStockQuote(symbol) {
  const res = await data(`/v2/stocks/${encodeURIComponent(symbol)}/quotes/latest`, {
    query: { feed: 'iex' },
  });
  return res?.quote || null;
}

/** Most recent trade price for the underlying equity. */
export async function getStockTrade(symbol) {
  const res = await data(`/v2/stocks/${encodeURIComponent(symbol)}/trades/latest`, {
    query: { feed: 'iex' },
  });
  return res?.trade || null;
}

/**
 * Option chain snapshots: quote, latest trade, greeks and implied vol per
 * contract. Paginated the same way as contracts.
 */
export async function getChainSnapshots(underlying, { expiry, type } = {}) {
  const snapshots = {};
  let pageToken;

  do {
    const page = await data(`/v1beta1/options/snapshots/${encodeURIComponent(underlying)}`, {
      query: {
        feed: 'indicative',
        limit: 1000,
        expiration_date: expiry,
        type,
        page_token: pageToken,
      },
    });
    Object.assign(snapshots, page?.snapshots || {});
    pageToken = page?.next_page_token || undefined;
  } while (pageToken);

  return snapshots;
}

/* ---------------------------------- orders ---------------------------------- */

export const submitOrder = (order) => trading('/v2/orders', { method: 'POST', body: order });
export const listOrders = (status = 'all', limit = 50) =>
  trading('/v2/orders', { query: { status, limit, nested: true, direction: 'desc' } });
export const cancelOrder = (id) =>
  trading(`/v2/orders/${encodeURIComponent(id)}`, { method: 'DELETE' });
