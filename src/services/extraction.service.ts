import { v4 as uuidv4 } from 'uuid';
import { logger } from '../utils/logger';
import { extractText } from '../utils/parser';
import type { ExtractRequest, ExtractResponse, DocumentType } from '../types/index';

const OPENROUTER_API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const MODEL = 'anthropic/claude-sonnet-4-5';

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
  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) throw new Error('OPENROUTER_API_KEY not set');

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

  const response = await fetch(OPENROUTER_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 2048,
      messages: [{ role: 'user', content: fullPrompt }],
      response_format: { type: 'json_object' },
    }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`OpenRouter error: ${response.status} ${err}`);
  }

  const data = await response.json() as { choices: { message: { content: string } }[], usage: { prompt_tokens: number; completion_tokens: number } };
  const raw = data.choices[0].message.content ?? '{}';

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
    model: MODEL,
    document_type: detectedType,
    page_count: pageCount,
    word_count: wordCount,
    data: (parsed.data ?? {}) as ExtractResponse['data'],
    summary: parsed.summary as string | undefined,
    ...(req.output_format === 'raw' && { raw_text: textContent }),
    latency_ms: Date.now() - t0,
    usage: { input_tokens: data.usage.prompt_tokens, output_tokens: data.usage.completion_tokens },
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
