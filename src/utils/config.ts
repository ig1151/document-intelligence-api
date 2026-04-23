import 'dotenv/config';
function optional(key: string, fallback: string): string { return process.env[key] ?? fallback; }
export const config = {
  server: { port: parseInt(optional('PORT', '3000'), 10), nodeEnv: optional('NODE_ENV', 'development'), apiVersion: optional('API_VERSION', 'v1') },
  rateLimit: { windowMs: parseInt(optional('RATE_LIMIT_WINDOW_MS', '60000'), 10), maxFree: parseInt(optional('RATE_LIMIT_MAX_FREE', '10'), 10), maxPro: parseInt(optional('RATE_LIMIT_MAX_PRO', '500'), 10) },
  upload: { maxFileSizeMb: parseInt(optional('MAX_FILE_SIZE_MB', '10'), 10), allowedMimeTypes: ['application/pdf', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'text/plain'] },
  jobs: { ttlSeconds: parseInt(optional('JOB_TTL_SECONDS', '3600'), 10) },
  logging: { level: optional('LOG_LEVEL', 'info') },
} as const;
