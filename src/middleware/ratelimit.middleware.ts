import rateLimit from 'express-rate-limit';
import { config } from '../utils/config';
export const rateLimiter = rateLimit({
  windowMs: config.rateLimit.windowMs, max: config.rateLimit.maxFree,
  standardHeaders: 'draft-7', legacyHeaders: false,
  keyGenerator: (req) => req.headers['authorization']?.replace('Bearer ', '') ?? req.ip ?? 'unknown',
  handler: (_req, res) => { res.status(429).json({ error: { code: 'RATE_LIMIT_EXCEEDED', message: 'Too many requests.' } }); },
});
