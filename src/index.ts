import { app } from './app';
import { config } from './utils/config';
import { logger } from './utils/logger';
const server = app.listen(config.server.port, () => { logger.info({ port: config.server.port, env: config.server.nodeEnv }, '🚀 Document Intelligence API started'); });
const shutdown = (signal: string) => { logger.info({ signal }, 'Shutting down'); server.close(() => { logger.info('Closed'); process.exit(0); }); setTimeout(() => process.exit(1), 10_000); };
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (reason) => logger.error({ reason }, 'Unhandled rejection'));
process.on('uncaughtException', (err) => { logger.fatal({ err }, 'Uncaught exception'); process.exit(1); });
