import express from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { config } from './config.js';
import { router } from './routes.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, '..', '..');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

app.use('/api', router);

// Serve the marketing page and the trading client from the same origin, so the
// browser calls /api directly and no CORS or credential exposure is involved.
app.use(express.static(projectRoot, { extensions: ['html'] }));

app.listen(config.port, () => {
  const banner = config.live
    ? '\x1b[41m\x1b[97m LIVE — orders spend real money \x1b[0m'
    : '\x1b[42m\x1b[30m PAPER — no real money at risk \x1b[0m';

  console.log(`\nHockeystick  ${banner}`);
  console.log(`  local   http://127.0.0.1:${config.port}`);
  console.log(`  app     http://127.0.0.1:${config.port}/app`);
  console.log(`  api     http://127.0.0.1:${config.port}/api/health`);
  console.log(`  upstream ${config.tradingBase}`);
  if (!config.keyId || !config.secretKey) {
    console.log('\n  \x1b[33mNo API keys found.\x1b[0m Copy server/.env.example to server/.env and add keys.');
  }
  console.log('');
});
