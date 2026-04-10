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
