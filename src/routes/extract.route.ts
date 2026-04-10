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
