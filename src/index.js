'use strict';

require('dotenv').config();

const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');

const express = require('express');
const helmet = require('helmet');
const compression = require('compression');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');

const { collectSnapshot } = require('./system');
const { tokenAuth } = require('./auth');

const execFileAsync = promisify(execFile);

const PORT = Number.parseInt(process.env.PORT || '3002', 10);
const HOST = process.env.HOST || '0.0.0.0';
const AUTH_TOKEN = process.env.AUTH_TOKEN || '';
const ENABLE_POWER = process.env.ENABLE_POWER_ENDPOINTS === 'true';
const CACHE_TTL_MS = (Number.parseInt(process.env.CACHE_TTL_SECONDS || '5', 10)) * 1000;

if (!AUTH_TOKEN) {
  console.error('FATAL: AUTH_TOKEN environment variable is required');
  process.exit(1);
}

const app = express();
app.disable('x-powered-by');
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", 'data:'],
      connectSrc: ["'self'"],
    },
  },
}));
app.use(compression());
app.use(morgan('combined'));
app.use(express.json({ limit: '4kb' }));
app.use(express.static(path.join(__dirname, '..', 'public'), { maxAge: '1h' }));

const apiLimiter = rateLimit({
  windowMs: 60_000,
  max: 60,
  standardHeaders: true,
  legacyHeaders: false,
});

const powerLimiter = rateLimit({
  windowMs: 5 * 60_000,
  max: 5,
  standardHeaders: true,
  legacyHeaders: false,
});

const auth = tokenAuth(AUTH_TOKEN);

let snapshotCache = { data: null, expiresAt: 0, inFlight: null };

async function getCachedSnapshot() {
  const now = Date.now();
  if (snapshotCache.data && now < snapshotCache.expiresAt) {
    return snapshotCache.data;
  }
  if (snapshotCache.inFlight) {
    return snapshotCache.inFlight;
  }
  const promise = collectSnapshot()
    .then((data) => {
      snapshotCache = { data, expiresAt: Date.now() + CACHE_TTL_MS, inFlight: null };
      return data;
    })
    .catch((error) => {
      snapshotCache.inFlight = null;
      throw error;
    });
  snapshotCache.inFlight = promise;
  return promise;
}

app.get('/api', apiLimiter, auth, async (_req, res, next) => {
  try {
    const snapshot = await getCachedSnapshot();
    res.json(snapshot);
  } catch (error) {
    next(error);
  }
});

async function executePowerCommand(command) {
  const allowed = { reboot: '/sbin/reboot', shutdown: '/sbin/shutdown' };
  const binary = allowed[command];
  if (!binary) throw new Error(`Unknown command: ${command}`);
  const args = command === 'shutdown' ? ['-h', 'now'] : [];
  await execFileAsync('sudo', ['-n', binary, ...args], { timeout: 5000 });
}

if (ENABLE_POWER) {
  app.post('/reboot', powerLimiter, auth, async (_req, res, next) => {
    try {
      console.warn('[POWER] Reboot requested');
      await executePowerCommand('reboot');
      res.json({ ok: true });
    } catch (error) {
      next(error);
    }
  });

  app.post('/shutdown', powerLimiter, auth, async (_req, res, next) => {
    try {
      console.warn('[POWER] Shutdown requested');
      await executePowerCommand('shutdown');
      res.json({ ok: true });
    } catch (error) {
      next(error);
    }
  });
}

app.use((err, _req, res, _next) => {
  console.error('[ERROR]', err);
  res.status(500).json({ error: 'Internal error' });
});

const server = app.listen(PORT, HOST, () => {
  console.log(`rpi-monitor listening on http://${HOST}:${PORT}`);
  console.log(`Power endpoints: ${ENABLE_POWER ? 'enabled' : 'disabled'}`);
});

function shutdown(signal) {
  console.log(`\nReceived ${signal}, shutting down...`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
