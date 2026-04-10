import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger';
export function errorHandler(err: Error, req: Request, res: Response, _next: NextFunction): void {
  logger.error({ err, path: req.path }, 'Unhandled error');
  if (err.message?.includes('File too large')) { res.status(413).json({ error: { code: 'FILE_TOO_LARGE', message: err.message } }); return; }
  if (err.constructor.name === 'APIError') { res.status(502).json({ error: { code: 'UPSTREAM_ERROR', message: 'Error communicating with AI provider' } }); return; }
  res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' } });
}
export function notFound(req: Request, res: Response): void { res.status(404).json({ error: { code: 'NOT_FOUND', message: `Route ${req.method} ${req.path} not found` } }); }
