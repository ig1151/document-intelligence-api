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
