#!/bin/bash
set -e

echo "🚀 Building Document Intelligence API..."

cat > src/types/index.ts << 'HEREDOC'
export type DocumentType = 'invoice' | 'contract' | 'resume' | 'receipt' | 'report' | 'form' | 'auto';
export type OutputFormat = 'structured' | 'markdown' | 'raw';
export type JobStatus = 'pending' | 'processing' | 'success' | 'error';

export interface ExtractRequest {
  document: string;
  document_type?: DocumentType;
  output_format?: OutputFormat;
  fields?: string[];
  language?: string;
  async?: boolean;
  webhook_url?: string;
}

export interface FieldResult {
  value: string | number | boolean | string[];
  confidence: number;
  page?: number;
}

export interface InvoiceData {
  invoice_number?: FieldResult;
  date?: FieldResult;
  due_date?: FieldResult;
  vendor_name?: FieldResult;
  vendor_address?: FieldResult;
  client_name?: FieldResult;
  client_address?: FieldResult;
  line_items?: { description: string; quantity: number; unit_price: number; total: number }[];
  subtotal?: FieldResult;
  tax?: FieldResult;
  total?: FieldResult;
  currency?: FieldResult;
  payment_terms?: FieldResult;
}

export interface ResumeData {
  full_name?: FieldResult;
  email?: FieldResult;
  phone?: FieldResult;
  location?: FieldResult;
  summary?: FieldResult;
  skills?: FieldResult;
  experience?: { company: string; title: string; start_date: string; end_date: string; description: string }[];
  education?: { institution: string; degree: string; field: string; graduation_date: string }[];
  certifications?: FieldResult;
  languages?: FieldResult;
}

export interface ContractData {
  parties?: FieldResult;
  effective_date?: FieldResult;
  expiration_date?: FieldResult;
  governing_law?: FieldResult;
  payment_terms?: FieldResult;
  termination_clause?: FieldResult;
  key_obligations?: FieldResult;
  penalties?: FieldResult;
}

export interface ReceiptData {
  merchant_name?: FieldResult;
  merchant_address?: FieldResult;
  date?: FieldResult;
  items?: { description: string; quantity: number; price: number }[];
  subtotal?: FieldResult;
  tax?: FieldResult;
  tip?: FieldResult;
  total?: FieldResult;
  payment_method?: FieldResult;
}

export interface ExtractResponse {
  id: string;
  status: JobStatus;
  model: string;
  document_type: DocumentType;
  page_count?: number;
  word_count?: number;
  data: InvoiceData | ResumeData | ContractData | ReceiptData | Record<string, FieldResult>;
  summary?: string;
  raw_text?: string;
  latency_ms: number;
  usage: { input_tokens: number; output_tokens: number };
  created_at: string;
}

export interface Job {
  job_id: string;
  status: JobStatus;
  created_at: string;
  completed_at?: string;
  result?: ExtractResponse;
  error?: string;
}

export interface BatchRequest {
  documents: ExtractRequest[];
}

export interface BatchResponse {
  batch_id: string;
  total: number;
  succeeded: number;
  failed: number;
  results: (ExtractResponse | { error: string })[];
  latency_ms: number;
}
HEREDOC

cat > src/utils/config.ts << 'HEREDOC'
import 'dotenv/config';
function required(key: string): string { const val = process.env[key]; if (!val) throw new Error(`Missing required env var: ${key}`); return val; }
function optional(key: string, fallback: string): string { return process.env[key] ?? fallback; }
export const config = {
  anthropic: { apiKey: required('ANTHROPIC_API_KEY'), model: optional('ANTHROPIC_MODEL', 'claude-sonnet-4-20250514') },
  server: { port: parseInt(optional('PORT', '3000'), 10), nodeEnv: optional('NODE_ENV', 'development'), apiVersion: optional('API_VERSION', 'v1') },
  rateLimit: { windowMs: parseInt(optional('RATE_LIMIT_WINDOW_MS', '60000'), 10), maxFree: parseInt(optional('RATE_LIMIT_MAX_FREE', '10'), 10), maxPro: parseInt(optional('RATE_LIMIT_MAX_PRO', '500'), 10) },
  upload: { maxFileSizeMb: parseInt(optional('MAX_FILE_SIZE_MB', '25'), 10), allowedMimeTypes: optional('ALLOWED_MIME_TYPES', 'application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document,text/plain').split(',') },
  jobs: { ttlSeconds: parseInt(optional('JOB_TTL_SECONDS', '3600'), 10) },
  logging: { level: optional('LOG_LEVEL', 'info') },
} as const;
HEREDOC

cat > src/utils/logger.ts << 'HEREDOC'
import pino from 'pino';
import { config } from './config';
export const logger = pino({
  level: config.logging.level,
  transport: config.server.nodeEnv === 'development' ? { target: 'pino-pretty', options: { colorize: true } } : undefined,
  base: { service: 'document-intelligence-api' },
  timestamp: pino.stdTimeFunctions.isoTime,
  redact: { paths: ['req.headers.authorization'], censor: '[REDACTED]' },
});
HEREDOC

cat > src/utils/validation.ts << 'HEREDOC'
import Joi from 'joi';
const DOC_TYPES = ['invoice', 'contract', 'resume', 'receipt', 'report', 'form', 'auto'] as const;
const OUTPUT_FORMATS = ['structured', 'markdown', 'raw'] as const;
export const extractSchema = Joi.object({
  document: Joi.string().required().messages({ 'any.required': 'document is required — provide base64 encoded content or HTTPS URL' }),
  document_type: Joi.string().valid(...DOC_TYPES).default('auto'),
  output_format: Joi.string().valid(...OUTPUT_FORMATS).default('structured'),
  fields: Joi.array().items(Joi.string()).optional(),
  language: Joi.string().min(2).max(10).default('en'),
  async: Joi.boolean().default(false),
  webhook_url: Joi.string().uri({ scheme: ['https'] }).optional().when('async', { is: false, then: Joi.forbidden() }),
});
export const batchSchema = Joi.object({
  documents: Joi.array().items(extractSchema).min(1).max(10).required().messages({ 'array.max': 'Batch endpoint accepts a maximum of 10 documents per request' }),
});
HEREDOC

cat > src/utils/parser.ts << 'HEREDOC'
import pdfParse from 'pdf-parse';
import mammoth from 'mammoth';
import { logger } from './logger';

export async function extractText(base64: string, mimeType: string): Promise<{ text: string; pageCount?: number; wordCount: number }> {
  const buffer = Buffer.from(base64, 'base64');

  if (mimeType === 'application/pdf') {
    const data = await pdfParse(buffer);
    const wordCount = data.text.split(/\s+/).filter(Boolean).length;
    return { text: data.text, pageCount: data.numpages, wordCount };
  }

  if (mimeType === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
    const result = await mammoth.extractRawText({ buffer });
    const wordCount = result.value.split(/\s+/).filter(Boolean).length;
    return { text: result.value, wordCount };
  }

  if (mimeType === 'text/plain') {
    const text = buffer.toString('utf-8');
    const wordCount = text.split(/\s+/).filter(Boolean).length;
    return { text, wordCount };
  }

  logger.warn({ mimeType }, 'Unknown mime type — attempting raw text extraction');
  const text = buffer.toString('utf-8');
  return { text, wordCount: text.split(/\s+/).filter(Boolean).length };
}
HEREDOC

cat > src/services/extraction.service.ts << 'HEREDOC'
import Anthropic from '@anthropic-ai/sdk';
import { v4 as uuidv4 } from 'uuid';
import { config } from '../utils/config';
import { logger } from '../utils/logger';
import { extractText } from '../utils/parser';
import type { ExtractRequest, ExtractResponse, DocumentType } from '../types/index';

const client = new Anthropic({ apiKey: config.anthropic.apiKey });

function buildPrompt(documentType: DocumentType, fields?: string[], language?: string): string {
  const langNote = language && language !== 'en' ? `Output all human-readable strings in language: ${language}.\n` : '';
  const fieldNote = fields?.length ? `Extract specifically these fields: ${fields.join(', ')}.\n` : '';

  const schemaMap: Record<string, string> = {
    invoice: `{
  "invoice_number": { "value": "<string>", "confidence": <0.0-1.0> },
  "date": { "value": "<YYYY-MM-DD>", "confidence": <0.0-1.0> },
  "due_date": { "value": "<YYYY-MM-DD>", "confidence": <0.0-1.0> },
  "vendor_name": { "value": "<string>", "confidence": <0.0-1.0> },
  "vendor_address": { "value": "<string>", "confidence": <0.0-1.0> },
  "client_name": { "value": "<string>", "confidence": <0.0-1.0> },
  "client_address": { "value": "<string>", "confidence": <0.0-1.0> },
  "line_items": [{ "description": "<string>", "quantity": <number>, "unit_price": <number>, "total": <number> }],
  "subtotal": { "value": <number>, "confidence": <0.0-1.0> },
  "tax": { "value": <number>, "confidence": <0.0-1.0> },
  "total": { "value": <number>, "confidence": <0.0-1.0> },
  "currency": { "value": "<string>", "confidence": <0.0-1.0> },
  "payment_terms": { "value": "<string>", "confidence": <0.0-1.0> }
}`,
    resume: `{
  "full_name": { "value": "<string>", "confidence": <0.0-1.0> },
  "email": { "value": "<string>", "confidence": <0.0-1.0> },
  "phone": { "value": "<string>", "confidence": <0.0-1.0> },
  "location": { "value": "<string>", "confidence": <0.0-1.0> },
  "summary": { "value": "<string>", "confidence": <0.0-1.0> },
  "skills": { "value": ["<skill1>", "<skill2>"], "confidence": <0.0-1.0> },
  "experience": [{ "company": "<string>", "title": "<string>", "start_date": "<string>", "end_date": "<string>", "description": "<string>" }],
  "education": [{ "institution": "<string>", "degree": "<string>", "field": "<string>", "graduation_date": "<string>" }],
  "certifications": { "value": ["<cert1>"], "confidence": <0.0-1.0> },
  "languages": { "value": ["<lang1>"], "confidence": <0.0-1.0> }
}`,
    contract: `{
  "parties": { "value": ["<party1>", "<party2>"], "confidence": <0.0-1.0> },
  "effective_date": { "value": "<YYYY-MM-DD>", "confidence": <0.0-1.0> },
  "expiration_date": { "value": "<YYYY-MM-DD>", "confidence": <0.0-1.0> },
  "governing_law": { "value": "<string>", "confidence": <0.0-1.0> },
  "payment_terms": { "value": "<string>", "confidence": <0.0-1.0> },
  "termination_clause": { "value": "<string>", "confidence": <0.0-1.0> },
  "key_obligations": { "value": ["<obligation1>", "<obligation2>"], "confidence": <0.0-1.0> },
  "penalties": { "value": "<string>", "confidence": <0.0-1.0> }
}`,
    receipt: `{
  "merchant_name": { "value": "<string>", "confidence": <0.0-1.0> },
  "merchant_address": { "value": "<string>", "confidence": <0.0-1.0> },
  "date": { "value": "<YYYY-MM-DD>", "confidence": <0.0-1.0> },
  "items": [{ "description": "<string>", "quantity": <number>, "price": <number> }],
  "subtotal": { "value": <number>, "confidence": <0.0-1.0> },
  "tax": { "value": <number>, "confidence": <0.0-1.0> },
  "tip": { "value": <number>, "confidence": <0.0-1.0> },
  "total": { "value": <number>, "confidence": <0.0-1.0> },
  "payment_method": { "value": "<string>", "confidence": <0.0-1.0> }
}`,
  };

  const schema = schemaMap[documentType] ?? `{
  "<field_name>": { "value": "<extracted value>", "confidence": <0.0-1.0> }
}`;

  return `You are a document extraction expert. Extract structured data from the document text below.
${langNote}${fieldNote}
Return ONLY a valid JSON object in this exact format — no markdown, no explanation:

{
  "document_type": "${documentType}",
  "summary": "<2-3 sentence summary of the document>",
  "data": ${schema}
}`;
}

function detectMimeType(base64Header: string): string {
  if (base64Header.includes('data:application/pdf')) return 'application/pdf';
  if (base64Header.includes('data:application/vnd')) return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
  if (base64Header.includes('data:text/plain')) return 'text/plain';
  return 'application/pdf';
}

export async function extractDocument(req: ExtractRequest): Promise<ExtractResponse> {
  const id = `req_${uuidv4().replace(/-/g, '').slice(0, 12)}`;
  const t0 = Date.now();
  const docType = req.document_type ?? 'auto';
  const language = req.language ?? 'en';

  logger.info({ id, docType }, 'Starting document extraction');

  let textContent: string;
  let pageCount: number | undefined;
  let wordCount = 0;

  if (req.document.startsWith('https://')) {
    const response = await fetch(req.document);
    const arrayBuffer = await response.arrayBuffer();
    const base64 = Buffer.from(arrayBuffer).toString('base64');
    const mimeType = response.headers.get('content-type') ?? 'application/pdf';
    const parsed = await extractText(base64, mimeType);
    textContent = parsed.text;
    pageCount = parsed.pageCount;
    wordCount = parsed.wordCount;
  } else {
    const raw = req.document.includes(',') ? req.document.split(',')[1] : req.document;
    const mimeType = detectMimeType(req.document);
    const parsed = await extractText(raw, mimeType);
    textContent = parsed.text;
    pageCount = parsed.pageCount;
    wordCount = parsed.wordCount;
  }

  const detectedType: DocumentType = docType === 'auto'
    ? detectDocumentType(textContent)
    : docType;

  const prompt = buildPrompt(detectedType, req.fields, language);
  const fullPrompt = `${prompt}\n\n--- DOCUMENT TEXT ---\n${textContent.slice(0, 12000)}`;

  const response = await client.messages.create({
    model: config.anthropic.model,
    max_tokens: 2048,
    messages: [{ role: 'user', content: fullPrompt }],
  });

  const raw = response.content.find((b) => b.type === 'text')?.text ?? '{}';
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(raw.replace(/```json|```/g, '').trim());
  } catch (err) {
    logger.error({ id, raw, err }, 'Failed to parse JSON');
    throw new Error('Model returned malformed JSON');
  }

  logger.info({ id, latency: Date.now() - t0 }, 'Extraction complete');

  return {
    id,
    status: 'success',
    model: config.anthropic.model,
    document_type: detectedType,
    page_count: pageCount,
    word_count: wordCount,
    data: (parsed.data ?? {}) as ExtractResponse['data'],
    summary: parsed.summary as string | undefined,
    ...(req.output_format === 'raw' && { raw_text: textContent }),
    latency_ms: Date.now() - t0,
    usage: { input_tokens: response.usage.input_tokens, output_tokens: response.usage.output_tokens },
    created_at: new Date().toISOString(),
  };
}

function detectDocumentType(text: string): DocumentType {
  const lower = text.toLowerCase();
  if (lower.includes('invoice') || lower.includes('bill to') || lower.includes('amount due')) return 'invoice';
  if (lower.includes('receipt') || lower.includes('thank you for your purchase')) return 'receipt';
  if (lower.includes('agreement') || lower.includes('whereas') || lower.includes('hereinafter')) return 'contract';
  if (lower.includes('experience') || lower.includes('education') || lower.includes('skills') || lower.includes('resume') || lower.includes('curriculum vitae')) return 'resume';
  return 'report';
}
HEREDOC

cat > src/services/jobs.service.ts << 'HEREDOC'
import { v4 as uuidv4 } from 'uuid';
import { config } from '../utils/config';
import { logger } from '../utils/logger';
import type { Job, JobStatus, ExtractResponse } from '../types/index';
const store = new Map<string, Job>();
setInterval(() => {
  const now = Date.now(); const ttlMs = config.jobs.ttlSeconds * 1000;
  for (const [id, job] of store.entries()) { if (now - new Date(job.created_at).getTime() > ttlMs) { store.delete(id); logger.debug({ job_id: id }, 'Job expired'); } }
}, 60_000);
export function createJob(): Job { const job: Job = { job_id: `job_${uuidv4().replace(/-/g,'').slice(0,12)}`, status: 'pending', created_at: new Date().toISOString() }; store.set(job.job_id, job); return job; }
export function getJob(jobId: string): Job | undefined { return store.get(jobId); }
export function updateJob(jobId: string, status: JobStatus, result?: ExtractResponse, error?: string): void { const job = store.get(jobId); if (!job) return; job.status = status; if (result) job.result = result; if (error) job.error = error; if (status === 'success' || status === 'error') job.completed_at = new Date().toISOString(); store.set(jobId, job); }
HEREDOC

cat > src/middleware/error.middleware.ts << 'HEREDOC'
import { Request, Response, NextFunction } from 'express';
import { logger } from '../utils/logger';
export function errorHandler(err: Error, req: Request, res: Response, _next: NextFunction): void {
  logger.error({ err, path: req.path }, 'Unhandled error');
  if (err.message?.includes('File too large')) { res.status(413).json({ error: { code: 'FILE_TOO_LARGE', message: err.message } }); return; }
  if (err.constructor.name === 'APIError') { res.status(502).json({ error: { code: 'UPSTREAM_ERROR', message: 'Error communicating with AI provider' } }); return; }
  res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred' } });
}
export function notFound(req: Request, res: Response): void { res.status(404).json({ error: { code: 'NOT_FOUND', message: `Route ${req.method} ${req.path} not found` } }); }
HEREDOC

cat > src/middleware/ratelimit.middleware.ts << 'HEREDOC'
import rateLimit from 'express-rate-limit';
import { config } from '../utils/config';
export const rateLimiter = rateLimit({
  windowMs: config.rateLimit.windowMs, max: config.rateLimit.maxFree,
  standardHeaders: 'draft-7', legacyHeaders: false,
  keyGenerator: (req) => req.headers['authorization']?.replace('Bearer ', '') ?? req.ip ?? 'unknown',
  handler: (_req, res) => { res.status(429).json({ error: { code: 'RATE_LIMIT_EXCEEDED', message: 'Too many requests.' } }); },
});
HEREDOC

cat > src/routes/health.route.ts << 'HEREDOC'
import { Router, Request, Response } from 'express';
import { config } from '../utils/config';
export const healthRouter = Router();
const startTime = Date.now();
healthRouter.get('/', (_req: Request, res: Response) => {
  res.status(200).json({ status: 'ok', version: '1.0.0', model: config.anthropic.model, uptime_seconds: Math.floor((Date.now() - startTime) / 1000), timestamp: new Date().toISOString() });
});
HEREDOC

cat > src/routes/extract.route.ts << 'HEREDOC'
import { Router, Request, Response, NextFunction } from 'express';
import multer from 'multer';
import { extractSchema, batchSchema } from '../utils/validation';
import { extractDocument } from '../services/extraction.service';
import { createJob, getJob, updateJob } from '../services/jobs.service';
import { config } from '../utils/config';
import type { ExtractRequest, BatchRequest } from '../types/index';
export const extractRouter = Router();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: config.upload.maxFileSizeMb * 1024 * 1024 }, fileFilter: (_req, file, cb) => { config.upload.allowedMimeTypes.includes(file.mimetype) ? cb(null, true) : cb(new Error(`Unsupported file type: ${file.mimetype}`)); } });

extractRouter.post('/', upload.single('file'), async (req: Request, res: Response, next: NextFunction) => {
  try {
    let body: ExtractRequest = req.body;
    if (req.file) { body = { ...body, document: `data:${req.file.mimetype};base64,${req.file.buffer.toString('base64')}` }; }
    const { error, value } = extractSchema.validate(body, { abortEarly: false });
    if (error) { res.status(422).json({ error: { code: 'VALIDATION_ERROR', message: 'Validation failed', details: error.details.map((d) => d.message) } }); return; }
    if (value.async) {
      const job = createJob();
      res.status(202).json({ job_id: job.job_id, status: 'pending' });
      setImmediate(async () => {
        updateJob(job.job_id, 'processing');
        try { const result = await extractDocument(value); updateJob(job.job_id, 'success', result); }
        catch (err) { updateJob(job.job_id, 'error', undefined, err instanceof Error ? err.message : 'Unknown'); }
      });
      return;
    }
    res.status(200).json(await extractDocument(value));
  } catch (err) { next(err); }
});

extractRouter.post('/batch', async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { error, value } = batchSchema.validate(req.body, { abortEarly: false });
    if (error) { res.status(422).json({ error: { code: 'VALIDATION_ERROR', message: 'Validation failed', details: error.details.map((d) => d.message) } }); return; }
    const t0 = Date.now();
    const results = await Promise.allSettled((value as BatchRequest).documents.map((doc: ExtractRequest) => extractDocument(doc)));
    const out = results.map((r) => r.status === 'fulfilled' ? r.value : { error: r.reason instanceof Error ? r.reason.message : 'Unknown' });
    res.status(200).json({ batch_id: `batch_${Date.now()}`, total: (value as BatchRequest).documents.length, succeeded: out.filter((r) => !('error' in r)).length, failed: out.filter((r) => 'error' in r).length, results: out, latency_ms: Date.now() - t0 });
  } catch (err) { next(err); }
});

extractRouter.get('/jobs/:jobId', (req: Request, res: Response) => {
  const job = getJob(req.params.jobId);
  if (!job) { res.status(404).json({ error: { code: 'JOB_NOT_FOUND', message: `No job found: ${req.params.jobId}` } }); return; }
  res.status(200).json(job);
});
HEREDOC

cat > src/routes/openapi.route.ts << 'HEREDOC'
import { Router, Request, Response } from 'express';
import { config } from '../utils/config';
export const openapiRouter = Router();
openapiRouter.get('/', (_req: Request, res: Response) => {
  res.status(200).json({
    openapi: '3.0.3',
    info: { title: 'Document Intelligence API', version: '1.0.0', description: 'Extract structured data from PDFs, invoices, contracts and resumes — powered by Claude AI.' },
    servers: [{ url: 'https://document-intelligence-api.onrender.com', description: 'Production' }, { url: `http://localhost:${config.server.port}`, description: 'Local' }],
    paths: {
      '/v1/health': { get: { summary: 'Health check', operationId: 'getHealth', responses: { '200': { description: 'Service is healthy' } } } },
      '/v1/extract': {
        post: {
          summary: 'Extract structured data from a document',
          operationId: 'extractDocument',
          requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/ExtractRequest' }, examples: { invoice_url: { summary: 'Invoice from URL', value: { document: 'https://example.com/invoice.pdf', document_type: 'invoice', output_format: 'structured' } } } } } },
          responses: { '200': { description: 'Extracted data' }, '202': { description: 'Async job accepted' }, '422': { description: 'Validation error' }, '429': { description: 'Rate limit exceeded' }, '500': { description: 'Internal error' } },
        },
      },
      '/v1/extract/batch': { post: { summary: 'Extract from up to 10 documents', operationId: 'extractBatch', requestBody: { required: true, content: { 'application/json': { schema: { $ref: '#/components/schemas/BatchRequest' } } } }, responses: { '200': { description: 'Batch results' }, '422': { description: 'Validation error' } } } },
      '/v1/extract/jobs/{job_id}': { get: { summary: 'Poll async job', operationId: 'getJob', parameters: [{ name: 'job_id', in: 'path', required: true, schema: { type: 'string' } }], responses: { '200': { description: 'Job status' }, '404': { description: 'Not found' } } } },
    },
    components: {
      schemas: {
        ExtractRequest: { type: 'object', required: ['document'], properties: { document: { type: 'string', description: 'Base64 encoded document or HTTPS URL' }, document_type: { type: 'string', enum: ['invoice', 'contract', 'resume', 'receipt', 'report', 'form', 'auto'], default: 'auto' }, output_format: { type: 'string', enum: ['structured', 'markdown', 'raw'], default: 'structured' }, fields: { type: 'array', items: { type: 'string' }, description: 'Specific fields to extract' }, language: { type: 'string', default: 'en' }, async: { type: 'boolean', default: false }, webhook_url: { type: 'string', format: 'uri' } } },
        ExtractResponse: { type: 'object', properties: { id: { type: 'string' }, status: { type: 'string', enum: ['success', 'error', 'pending'] }, model: { type: 'string' }, document_type: { type: 'string' }, page_count: { type: 'integer' }, word_count: { type: 'integer' }, data: { type: 'object' }, summary: { type: 'string' }, latency_ms: { type: 'integer' }, usage: { type: 'object', properties: { input_tokens: { type: 'integer' }, output_tokens: { type: 'integer' } } }, created_at: { type: 'string', format: 'date-time' } } },
        BatchRequest: { type: 'object', required: ['documents'], properties: { documents: { type: 'array', items: { $ref: '#/components/schemas/ExtractRequest' }, minItems: 1, maxItems: 10 } } },
        Job: { type: 'object', properties: { job_id: { type: 'string' }, status: { type: 'string', enum: ['pending', 'processing', 'success', 'error'] }, created_at: { type: 'string', format: 'date-time' }, completed_at: { type: 'string', format: 'date-time' }, result: { $ref: '#/components/schemas/ExtractResponse' }, error: { type: 'string' } } },
      },
    },
  });
});
HEREDOC

cat > src/app.ts << 'HEREDOC'
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import pinoHttp from 'pino-http';
import { extractRouter } from './routes/extract.route';
import { healthRouter } from './routes/health.route';
import { openapiRouter } from './routes/openapi.route';
import { errorHandler, notFound } from './middleware/error.middleware';
import { rateLimiter } from './middleware/ratelimit.middleware';
import { logger } from './utils/logger';
import { config } from './utils/config';
const app = express();
app.use(helmet()); app.use(cors()); app.use(compression());
app.use(pinoHttp({ logger }));
app.use(express.json({ limit: '30mb' }));
app.use(express.urlencoded({ extended: true, limit: '30mb' }));
app.use(`/${config.server.apiVersion}/extract`, rateLimiter);
app.use(`/${config.server.apiVersion}/extract`, extractRouter);
app.use(`/${config.server.apiVersion}/health`, healthRouter);
app.use('/openapi.json', openapiRouter);
app.get('/', (_req, res) => res.redirect(`/${config.server.apiVersion}/health`));
app.use(notFound); app.use(errorHandler);
export { app };
HEREDOC

cat > src/index.ts << 'HEREDOC'
import { app } from './app';
import { config } from './utils/config';
import { logger } from './utils/logger';
const server = app.listen(config.server.port, () => { logger.info({ port: config.server.port, env: config.server.nodeEnv }, '🚀 Document Intelligence API started'); });
const shutdown = (signal: string) => { logger.info({ signal }, 'Shutting down'); server.close(() => { logger.info('Closed'); process.exit(0); }); setTimeout(() => process.exit(1), 10_000); };
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('unhandledRejection', (reason) => logger.error({ reason }, 'Unhandled rejection'));
process.on('uncaughtException', (err) => { logger.fatal({ err }, 'Uncaught exception'); process.exit(1); });
HEREDOC

cat > jest.config.js << 'HEREDOC'
module.exports = { preset: 'ts-jest', testEnvironment: 'node', rootDir: '.', testMatch: ['**/tests/**/*.test.ts'], collectCoverageFrom: ['src/**/*.ts', '!src/index.ts'], setupFiles: ['<rootDir>/tests/setup.ts'] };
HEREDOC

cat > tests/setup.ts << 'HEREDOC'
process.env.ANTHROPIC_API_KEY = 'sk-ant-test-key';
process.env.NODE_ENV = 'test';
process.env.LOG_LEVEL = 'silent';
HEREDOC

cat > .gitignore << 'HEREDOC'
node_modules/
dist/
.env
coverage/
*.log
.DS_Store
HEREDOC

cat > render.yaml << 'HEREDOC'
services:
  - type: web
    name: document-intelligence-api
    runtime: node
    buildCommand: npm install && npm run build
    startCommand: node dist/index.js
    healthCheckPath: /v1/health
    envVars:
      - key: NODE_ENV
        value: production
      - key: LOG_LEVEL
        value: info
      - key: ANTHROPIC_API_KEY
        sync: false
HEREDOC

echo ""
echo "✅ All files created! Run: npm install"