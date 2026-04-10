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
