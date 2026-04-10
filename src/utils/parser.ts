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
