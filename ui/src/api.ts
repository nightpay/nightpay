// api.ts — typed wrappers around NightPay backend endpoints
//
// Two backends, two proxy paths in Vite:
//   /api  → bridge (port 4000)  — health, stats, verifyReceipt
//   /mip  → mip003-server (port 8090) — jobs / bounties
//
// Set VITE_BRIDGE_URL / VITE_MIP_URL to override in production.

const BRIDGE_BASE = import.meta.env.VITE_BRIDGE_URL ?? '/api';
const MIP_BASE = import.meta.env.VITE_MIP_URL ?? '/mip';
const PROOF_SERVER = import.meta.env.VITE_PROOF_SERVER ?? 'http://localhost:6300';

export const runtimeConfig = {
  bridgeBase: BRIDGE_BASE,
  mipBase: MIP_BASE,
  proofServer: PROOF_SERVER,
};

/** SessionStorage key for admin/God mode token (operator secret). Cleared when tab closes. */
export const ADMIN_TOKEN_STORAGE_KEY = 'nightpay.admin_token';

// ── Types ─────────────────────────────────────────────────────────────────────

export interface HealthResponse {
  status: 'ok' | 'error';
  contractAddress: string;
  network: 'preprod' | 'mainnet';
  stub: boolean;
}

export interface StatsResponse {
  completed: number;
  active: number;
  feeBps: number;
  stub: boolean;
}

export interface VerifyResponse {
  valid: boolean;
  stub: boolean;
}

export interface CreateJobResponse {
  job_id: string;
  status: 'running' | 'awaiting_approval' | 'multisig_pending' | 'completed' | 'disputed' | 'refunded';
  job_token?: string;
  assigned_agent_id?: string | null;
  visibility?: 'public' | 'hidden';
  contest?: ContestConfig;
}

export interface ContestConfig {
  enabled: boolean;
  min_agents: number;
  max_agents: number;
  min_votes_to_select: number;
}

export interface Submission {
  submission_id: string;
  agent_id: string;
  payload: {
    work_output?: string;
    artifact_paths?: string[];
    artifact_count?: number;
  };
  created_at: string;
  updated_at: string;
  is_winner: boolean;
  selected_at: string | null;
  approve_votes: number;
  reject_votes: number;
  score: number;
}

// Job shape returned by mip003-server.sh GET /jobs
// Maps directly to the SQLite jobs table.
export interface Job {
  job_id: string;
  status: 'running' | 'awaiting_approval' | 'multisig_pending' | 'completed' | 'disputed' | 'refunded';
  amount_specks: number | null;
  visibility?: 'public' | 'hidden';
  input_data: { description?: string; amount_specks?: number; work_commit?: string } | null;
  started_at?: string | null;
  approved_at: string | null;   // ISO8601 deadline for optimistic approval
  assigned_agent_id?: string | null;
  claims_count?: number;
  approve_votes?: number;
  reject_votes?: number;
  submissions_count?: number;
  contest?: ContestConfig;
  // populated when completed:
  result?: { receipt_hash?: string; output_hash?: string } | null;
}

// UI-friendly bounty — derived from Job
export interface Bounty {
  id: string;
  title: string;
  description: string;
  amountSpecks: number;
  status: 'open' | 'funded' | 'completed' | 'disputed';
  createdAt: string | null;
  receiptHash?: string;   // populated when completed
  assignedAgentId?: string;
  claimsCount: number;
  approveVotes: number;
  rejectVotes: number;
}

export interface JobsQuery {
  status?: string;
  limit?: number;
  offset?: number;
  search?: string;
  visibility?: 'all' | 'public' | 'hidden';
}

export interface JobsResponse {
  jobs: Job[];
  limit: number;
  offset: number;
  count: number;
  has_more: boolean;
}

export interface Artifact {
  artifact_id: string;
  job_id: string;
  filename: string;
  content_type: string;
  size_bytes: number;
  description?: string | null;
  uploaded_by?: string | null;
  uploaded_at: string;
  url: string;
}

export interface ArtifactContent extends Artifact {
  content_b64: string;
  content_text?: string;
}

export interface ArtifactsListResponse {
  artifacts: Artifact[];
  count: number;
  total_bytes: number;
  remaining_bytes: number;
}

export interface PotentialUseCaseResponseItem {
  id: string;
  title: string;
  starter_bounty: string;
  sources: string[];
}

export interface PotentialUseCasesResponse {
  count: number;
  items: PotentialUseCaseResponseItem[];
}

export interface AgentShowcaseItem {
  title: string;
  summary: string;
  capabilities: string[];
  proof_url?: string;
}

export interface AgentCredibility {
  model: string;
  score: number;
  variety_index: number;
  features: Record<string, number>;
  signals: Record<string, number>;
}

export interface AgentProfile {
  agent_id: string;
  name: string;
  description: string;
  capabilities: string[];
  showcase: AgentShowcaseItem[];
  model_provider?: string;
  model_name?: string;
  endpoint_url?: string;
  metadata?: Record<string, unknown>;
  credibility_score: number;
  credibility: AgentCredibility;
  created_at?: string;
  updated_at?: string;
}

export interface AgentsCatalogResponse {
  count: number;
  total: number;
  limit: number;
  offset: number;
  has_more: boolean;
  agents: AgentProfile[];
}

export type ManagementMode = 'general' | 'onboarding' | 'troubleshooting' | 'deploy' | 'security';

export interface ManagementAction {
  title: string;
  command?: string;
  why?: string;
}

export interface ManagementChatResponse {
  status: 'ok';
  agent: string;
  mode: ManagementMode;
  intent: string;
  reply: string;
  actions: ManagementAction[];
  references: string[];
  timestamp: string;
  assistant_backend?: 'ollama' | 'heuristic' | string;
  model?: string;
  fallback_used?: boolean;
  llm_error?: string;
  llm_reply_preview?: string;
}

// ── Fetch helpers ─────────────────────────────────────────────────────────────

async function get<T>(base: string, path: string): Promise<T> {
  const res = await fetch(`${base}${path}`);
  if (!res.ok) throw new Error(`GET ${path} → ${res.status}`);
  return res.json() as Promise<T>;
}

async function getWithAuth<T>(base: string, path: string, bearerToken: string): Promise<T> {
  const res = await fetch(`${base}${path}`, {
    headers: { Authorization: `Bearer ${bearerToken}` },
  });
  if (!res.ok) throw new Error(`GET ${path} → ${res.status}`);
  return res.json() as Promise<T>;
}

async function post<T>(base: string, path: string, body: unknown): Promise<T> {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`POST ${path} → ${res.status}`);
  return res.json() as Promise<T>;
}

async function postWithAuth<T>(base: string, path: string, body: unknown, bearerToken: string): Promise<T> {
  const res = await fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${bearerToken}` },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`POST ${path} → ${res.status}`);
  return res.json() as Promise<T>;
}

// ── Job → Bounty mapper ───────────────────────────────────────────────────────

function jobToBounty(job: Job): Bounty {
  const desc = (job.input_data?.description ?? '').trim();
  const shortId = job.job_id.slice(0, 8);
  const oneLine = desc.replace(/\s+/g, ' ');
  const title = oneLine
    ? (oneLine.length > 80 ? `${oneLine.slice(0, 80).trim()}…` : oneLine)
    : `Bounty ${shortId}`;
  const amountSpecks = job.amount_specks ?? job.input_data?.amount_specks ?? 0;
  const receiptHash = job.result?.receipt_hash ?? job.result?.output_hash;
  const claimsCount = Number(job.claims_count ?? 0);
  const approveVotes = Number(job.approve_votes ?? 0);
  const rejectVotes = Number(job.reject_votes ?? 0);

  const mappedStatus: Bounty['status'] =
    job.status === 'running'
      ? (claimsCount > 0 ? 'funded' : 'open')
      : job.status === 'awaiting_approval' || job.status === 'multisig_pending'
        ? 'funded'
        : job.status === 'completed'
          ? 'completed'
          : job.status === 'disputed'
            ? 'disputed'
            : 'open'; // refunded -> open

  return {
    id: job.job_id,
    title,
    description: desc || 'No task description provided.',
    amountSpecks,
    status: mappedStatus,
    createdAt: job.started_at ?? job.approved_at ?? null,
    receiptHash: receiptHash ?? undefined,
    assignedAgentId: job.assigned_agent_id ?? undefined,
    claimsCount,
    approveVotes,
    rejectVotes,
  };
}

// ── API calls ─────────────────────────────────────────────────────────────────

export const api = {
  // Bridge endpoints
  health: () => get<HealthResponse>(BRIDGE_BASE, '/health'),
  stats:  () => get<StatsResponse>(BRIDGE_BASE, '/stats'),
  verifyReceipt: (receiptHash: string) =>
    post<VerifyResponse>(BRIDGE_BASE, '/verifyReceipt', { receiptHash }),

  // MIP-003 server endpoints
  /** If adminToken (operator secret) is provided, uses Bearer auth and defaults visibility to 'all' (God mode). */
  jobs: (query: JobsQuery = {}, adminToken?: string) => {
    const params = new URLSearchParams();
    if (query.status) params.set('status', query.status);
    if (typeof query.limit === 'number') params.set('limit', String(query.limit));
    if (typeof query.offset === 'number') params.set('offset', String(query.offset));
    if (query.search && query.search.trim()) params.set('search', query.search.trim());
    const visibility = adminToken ? (query.visibility ?? 'all') : (query.visibility ?? 'public');
    params.set('visibility', visibility);
    const qs = params.toString();
    const path = qs ? `/jobs?${qs}` : '/jobs';
    if (adminToken?.trim()) {
      return getWithAuth<JobsResponse>(MIP_BASE, path, adminToken.trim());
    }
    return get<JobsResponse>(MIP_BASE, path);
  },
  createJob: (
    description: string,
    amountSpecks: number,
    idempotencyKey?: string,
    contest?: { enabled: boolean; minAgents?: number; maxAgents?: number; minVotesToSelect?: number }
  ) =>
    post<CreateJobResponse>(MIP_BASE, '/start_job', {
      amount_specks: amountSpecks,
      idempotency_key: idempotencyKey,
      input_data: {
        description,
        amount_specks: amountSpecks,
      },
      contest: contest
        ? {
            enabled: contest.enabled,
            min_agents: contest.minAgents,
            max_agents: contest.maxAgents,
            min_votes_to_select: contest.minVotesToSelect,
          }
        : undefined,
    }),
  claimJob: (jobId: string, agentId: string, options?: { exclusive?: boolean; assign?: boolean }) =>
    post<{ job_id: string; claims_count: number; assigned_agent_id: string | null }>(
      MIP_BASE,
      `/claim_job/${jobId}`,
      { agent_id: agentId, exclusive: options?.exclusive ?? false, assign: options?.assign ?? false }
    ),
  voteResult: (jobId: string, voterId: string, vote: 'approve' | 'reject', reason?: string) =>
    post<{ job_id: string; approve: number; reject: number; total: number }>(
      MIP_BASE,
      `/vote_result/${jobId}`,
      { voter_id: voterId, vote, reason }
    ),
  getVoteResult: (jobId: string) =>
    get<{ job_id: string; approve: number; reject: number; total: number }>(MIP_BASE, `/vote_result/${jobId}`),
  /** Single job status (GET /status/:jobId). Public, no auth. */
  jobStatus: (jobId: string) =>
    get<Job & { voting?: { started_at?: string; ends_at?: string; eligible_voters_count?: number; agent_voting_only?: boolean }; voter_snapshot?: string[] }>(MIP_BASE, `/status/${jobId}`),
  /** List submissions for a job. Requires job_token (bounty creator or operator). */
  submissions: (jobId: string, jobToken: string) =>
    getWithAuth<{ job_id: string; contest: ContestConfig; voting?: { started_at?: string; ends_at?: string; eligible_voters_count?: number }; voter_snapshot?: string[]; submissions: Submission[]; count: number }>(MIP_BASE, `/submissions/${jobId}`, jobToken),
  voteSubmission: (
    jobId: string,
    submissionId: string,
    voterId: string,
    vote: 'approve' | 'reject',
    reason?: string
  ) =>
    post<{ job_id: string; submission_id: string; approve: number; reject: number; total: number }>(
      MIP_BASE,
      `/vote_submission/${jobId}/${submissionId}`,
      { voter_id: voterId, vote, reason }
    ),
  selectWinner: (jobId: string, jobToken: string, submissionId?: string) =>
    postWithAuth<{ job_id: string; status: string; winner_submission_id: string; winner_agent_id: string }>(
      MIP_BASE,
      `/select_winner/${jobId}`,
      submissionId ? { submission_id: submissionId } : {},
      jobToken
    ),
  /** Raise a dispute on a job. Requires job_token (bounty creator or operator). */
  dispute: (jobId: string, jobToken: string, reason: string) =>
    postWithAuth<{ status: string; reason?: string }>(MIP_BASE, `/dispute/${jobId}`, { reason }, jobToken),

  // Convenience: paged jobs mapped to UI bounties. Pass adminToken for God mode (see all jobs).
  bounties: async (query: JobsQuery = {}, adminToken?: string): Promise<{
    bounties: Bounty[];
    limit: number;
    offset: number;
    count: number;
    hasMore: boolean;
  }> => {
    const res = await api.jobs(query, adminToken);
    return {
      bounties: res.jobs.map(jobToBounty),
      limit: res.limit,
      offset: res.offset,
      count: res.count,
      hasMore: res.has_more,
    };
  },

  // Live availability
  availability: () =>
    get<{ status: string; total_jobs: number; active_jobs: number; potential_use_cases_count?: number }>(MIP_BASE, '/availability'),
  managementChat: (
    message: string,
    options?: {
      mode?: ManagementMode;
      agentId?: string;
      history?: Array<{ role: 'user' | 'assistant'; content: string }>;
    }
  ) =>
    post<ManagementChatResponse>(MIP_BASE, '/management/chat', {
      message,
      mode: options?.mode ?? 'general',
      agent_id: options?.agentId,
      history: (options?.history ?? []).slice(-8),
    }),
  useCases: () =>
    get<PotentialUseCasesResponse>(MIP_BASE, '/use_cases'),
  agentsCatalog: (query: { q?: string; capability?: string; limit?: number; offset?: number; sort?: 'credibility' | 'updated_at'; showcaseOnly?: boolean } = {}) => {
    const params = new URLSearchParams();
    if (query.q && query.q.trim()) params.set('q', query.q.trim());
    if (query.capability && query.capability.trim()) params.set('capability', query.capability.trim());
    if (typeof query.limit === 'number') params.set('limit', String(query.limit));
    if (typeof query.offset === 'number') params.set('offset', String(query.offset));
    if (query.sort) params.set('sort', query.sort);
    if (query.showcaseOnly) params.set('showcase_only', '1');
    const qs = params.toString();
    return get<AgentsCatalogResponse>(MIP_BASE, qs ? `/agents?${qs}` : '/agents');
  },
    // Artifact storage (proxied through MIP base → /api/v1/jobs/<id>/artifacts on mip003-server)
  uploadArtifact: (
    jobId: string,
    filename: string,
    uploadedBy: string,
    content: { text: string } | { b64: string },
    opts?: { contentType?: string; description?: string }
  ) =>
    post<Artifact>(MIP_BASE, `/api/v1/jobs/${jobId}/artifacts`, {
      filename,
      uploaded_by: uploadedBy,
      content_type: opts?.contentType,
      description: opts?.description,
      ...('text' in content ? { content_text: content.text } : { content_b64: content.b64 }),
    }),
  listArtifacts: (jobId: string) =>
    get<ArtifactsListResponse>(MIP_BASE, `/api/v1/jobs/${jobId}/artifacts`),
  getArtifact: (jobId: string, artifactId: string) =>
    get<ArtifactContent>(MIP_BASE, `/api/v1/jobs/${jobId}/artifacts/${artifactId}`),

  ceoPrompt: (
    message: string,
    options?: {
      mode?: ManagementMode;
      agentId?: string;
      history?: Array<{ role: 'user' | 'assistant'; content: string }>;
    }
  ) =>
    post<ManagementChatResponse>(MIP_BASE, '/management/chat', {
      message,
      mode: options?.mode ?? 'general',
      agent_id: options?.agentId,
      history: (options?.history ?? []).slice(-8),
    }),

  hireDirect: (agentId: string, description: string, amountSpecks: number, idempotencyKey?: string) =>
    post<CreateJobResponse>(MIP_BASE, '/start_job', {
      amount_specks: amountSpecks,
      direct_agent_id: agentId,
      visibility: 'hidden',
      idempotency_key: idempotencyKey,
      input_data: {
        description,
        amount_specks: amountSpecks,
        visibility: 'hidden',
      },
    }),
};

// ── Display helpers ───────────────────────────────────────────────────────────

/** Format specks as human-readable NIGHT amount */
export function formatNight(specks: number): string {
  if (specks >= 1_000_000) return (specks / 1_000_000).toFixed(2) + '\u00a0NIGHT';
  if (specks > 0) return specks.toLocaleString() + '\u00a0specks';
  return '—';
}

/** Truncate a 64-char hex hash for display */
export function truncateHash(hex: string, chars = 8): string {
  if (!hex || hex.length <= chars * 2 + 2) return hex;
  return hex.slice(0, chars) + '…' + hex.slice(-chars);
}

/** Human-readable time-ago */
export function timeAgo(iso?: string | null): string {
  if (!iso) return 'pending approval';
  const ts = new Date(iso).getTime();
  if (Number.isNaN(ts)) return 'time unavailable';

  const diff = Date.now() - ts;
  if (diff < 0) {
    const minsFuture = Math.ceil(Math.abs(diff) / 60_000);
    const hoursFuture = Math.ceil(Math.abs(diff) / 3_600_000);
    const daysFuture = Math.ceil(Math.abs(diff) / 86_400_000);
    if (minsFuture < 60) return `in ${minsFuture}m`;
    if (hoursFuture < 24) return `in ${hoursFuture}h`;
    return `in ${daysFuture}d`;
  }

  const mins  = Math.floor(diff / 60_000);
  const hours = Math.floor(diff / 3_600_000);
  const days  = Math.floor(diff / 86_400_000);
  if (mins < 2)   return 'just now';
  if (hours < 1)  return `${mins}m ago`;
  if (days < 1)   return `${hours}h ago`;
  if (days < 30)  return `${days}d ago`;
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
}
