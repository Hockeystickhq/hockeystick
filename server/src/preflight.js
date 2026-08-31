/**
 * Connectivity and entitlement check. Run with `npm run check` before trading
 * to confirm keys work, the environment is the one you expect, and the account
 * is approved for the option levels the strategies need.
 */
import { config } from './config.js';
import * as alpaca from './alpaca.js';

const tick = (ok) => (ok ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m');

try {
  console.log(`\nEnvironment   ${config.env.toUpperCase()}  (${config.tradingBase})`);

  const account = await alpaca.getAccount();
  console.log(`${tick(true)} Credentials   account ${account.account_number}, status ${account.status}`);
  console.log(`${tick(true)} Equity        $${Number(account.equity).toLocaleString()}`);
  console.log(`${tick(true)} Buying power  $${Number(account.buying_power).toLocaleString()}`);

  const level = Number(account.options_trading_level ?? 0);
  console.log(`${tick(level >= 1)} Options level ${level}  ${level >= 3 ? '(multi-leg enabled)' : '(level 3 needed for straddles)'}`);

  const quote = await alpaca.getStockQuote('AAPL');
  console.log(`${tick(Boolean(quote))} Market data   AAPL bid ${quote?.bp} / ask ${quote?.ap}`);

  const contracts = await alpaca.listContracts({
    underlying: 'AAPL',
    expirationDateGte: new Date().toISOString().slice(0, 10),
  });
  console.log(`${tick(contracts.length > 0)} Option chain  ${contracts.length} live AAPL contracts`);

  console.log('\nReady to trade.\n');
} catch (err) {
  console.error(`\n${tick(false)} ${err.message}\n`);
  process.exit(1);
}
