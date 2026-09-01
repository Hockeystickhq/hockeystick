// Vercel serverless entry for the trading API.
//
// The same Express router that server/src/server.js mounts locally is mounted
// here, so there is one implementation of the routes and no drift between
// `npm start` and production. Credentials come from Vercel environment
// variables rather than server/.env; nothing else changes.

import express from 'express';
import { router } from '../server/src/routes.js';

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));
app.use('/api', router);

export default app;
