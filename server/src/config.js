import 'dotenv/config';

const ENV = (process.env.ALPACA_ENV || 'paper').toLowerCase();

if (ENV !== 'paper' && ENV !== 'live') {
  throw new Error(`ALPACA_ENV must be "paper" or "live", got "${ENV}"`);
}

export const config = {
  env: ENV,
  live: ENV === 'live',
  keyId: process.env.ALPACA_KEY_ID || '',
  secretKey: process.env.ALPACA_SECRET_KEY || '',
  port: Number(process.env.PORT || 8787),

  // Trading API. Paper and live are entirely separate accounts and key pairs.
  tradingBase: ENV === 'live'
    ? 'https://api.alpaca.markets'
    : 'https://paper-api.alpaca.markets',

  // Market data is served from one host regardless of trading environment.
  dataBase: 'https://data.alpaca.markets',
};

export function assertCredentials() {
  if (!config.keyId || !config.secretKey) {
    throw new Error('Market data is temporarily unavailable.');
  }
}
