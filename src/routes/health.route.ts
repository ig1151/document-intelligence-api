import { Router, Request, Response } from 'express';
export const healthRouter = Router();
const startTime = Date.now();
healthRouter.get('/', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok', version: '1.0.0', model: 'anthropic/claude-sonnet-4-5', uptime_seconds: Math.floor((Date.now() - startTime) / 1000), timestamp: new Date().toISOString() });
});
