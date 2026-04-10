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
