import { useCallback, useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api, runtimeConfig, type Job, type Submission, formatNight, truncateHash, timeAgo, ADMIN_TOKEN_STORAGE_KEY } from '../api.ts';
import { toast } from '../utils/toast.ts';

const JOB_TOKEN_STORAGE_KEY = 'nightpay.job_token';

/** Job plus optional voting fields from GET /status/:id */
type JobDetail = Job & {
  voting?: { started_at?: string; ends_at?: string; eligible_voters_count?: number; agent_voting_only?: boolean };
  voter_snapshot?: string[];
};

function getAdminToken(): string {
  try {
    return sessionStorage.getItem(ADMIN_TOKEN_STORAGE_KEY) ?? '';
  } catch {
    return '';
  }
}

function apiUrlForDocs(): string {
  const base = runtimeConfig.mipBase;
  if (base.startsWith('http')) return base.replace(/\/$/, '');
  if (typeof window !== 'undefined' && (window.location.hostname === 'nightpay.dev' || window.location.hostname.endsWith('.nightpay.dev')))
    return 'https://api.nightpay.dev';
  return 'http://localhost:8090';
}

export default function JobDetailPage() {
  const { jobId } = useParams<{ jobId: string }>();
  const [job, setJob] = useState<JobDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [jobToken, setJobToken] = useState(() => {
    try {
      return sessionStorage.getItem(JOB_TOKEN_STORAGE_KEY) ?? '';
    } catch {
      return '';
    }
  });
  const [voterId, setVoterId] = useState(() => {
    try {
      return window.localStorage.getItem('nightpay.agent_id') ?? '';
    } catch {
      return '';
    }
  });
  const [submissionsData, setSubmissionsData] = useState<{
    submissions: Submission[];
    count: number;
    voting?: { started_at?: string; ends_at?: string; eligible_voters_count?: number };
    voter_snapshot?: string[];
  } | null>(null);
  const [submissionsLoading, setSubmissionsLoading] = useState(false);
  const [submissionsError, setSubmissionsError] = useState<string | null>(null);
  const [voteBusy, setVoteBusy] = useState<Record<string, boolean>>({});
  const [selectBusy, setSelectBusy] = useState(false);
  const [disputeBusy, setDisputeBusy] = useState(false);
  const [disputeReason, setDisputeReason] = useState('');

  const loadJob = useCallback(async () => {
    if (!jobId) return;
    setLoading(true);
    setError(null);
    try {
      const data = await api.jobStatus(jobId);
      setJob(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load job');
      setJob(null);
    } finally {
      setLoading(false);
    }
  }, [jobId]);

  useEffect(() => {
    void loadJob();
  }, [loadJob]);

  const adminToken = getAdminToken();
  const effectiveToken = jobToken.trim() || adminToken;

  const loadSubmissions = useCallback(async () => {
    if (!jobId) return;
    if (!jobToken.trim() && !adminToken) {
      toast('Enter job token to load submissions', 'info');
      return;
    }
    const token = jobToken.trim() || adminToken;
    setSubmissionsLoading(true);
    setSubmissionsError(null);
    try {
      const data = await api.submissions(jobId, token);
      setSubmissionsData({
        submissions: data.submissions,
        count: data.count,
        voting: data.voting,
        voter_snapshot: data.voter_snapshot,
      });
      if (jobToken.trim()) {
        try {
          sessionStorage.setItem(JOB_TOKEN_STORAGE_KEY, jobToken.trim());
        } catch {
          /* ignore */
        }
      }
      toast(`Loaded ${data.count} submission(s)`, 'success');
    } catch (err) {
      setSubmissionsError(err instanceof Error ? err.message : 'Failed to load submissions');
      setSubmissionsData(null);
      toast('Submissions require valid job token', 'error');
    } finally {
      setSubmissionsLoading(false);
    }
  }, [jobId, jobToken, adminToken]);

  const handleVote = useCallback(
    async (submissionId: string, vote: 'approve' | 'reject') => {
      if (!jobId || !voterId.trim()) {
        toast('Set your Agent ID (voter) to vote', 'info');
        return;
      }
      setVoteBusy((prev) => ({ ...prev, [submissionId]: true }));
      try {
        await api.voteSubmission(jobId, submissionId, voterId.trim(), vote);
        toast(`Vote ${vote}d`, 'success');
        void loadSubmissions();
      } catch (err) {
        toast(err instanceof Error ? err.message : 'Vote failed', 'error');
      } finally {
        setVoteBusy((prev) => ({ ...prev, [submissionId]: false }));
      }
    },
    [jobId, voterId, loadSubmissions]
  );

  const handleSelectWinner = useCallback(async () => {
    if (!jobId || !effectiveToken) return;
    setSelectBusy(true);
    try {
      await api.selectWinner(jobId, effectiveToken);
      toast('Winner selected', 'success');
      void loadJob();
      void loadSubmissions();
    } catch (err) {
      toast(err instanceof Error ? err.message : 'Select winner failed', 'error');
    } finally {
      setSelectBusy(false);
    }
  }, [jobId, effectiveToken, loadJob, loadSubmissions]);

  const handleDispute = useCallback(async () => {
    if (!jobId || !effectiveToken) {
      toast('Job token required to dispute', 'info');
      return;
    }
    const reason = disputeReason.trim() || 'Dispute raised from UI';
    setDisputeBusy(true);
    try {
      await api.dispute(jobId, effectiveToken, reason);
      toast('Dispute raised', 'success');
      setDisputeReason('');
      void loadJob();
    } catch (err) {
      toast(err instanceof Error ? err.message : 'Dispute failed', 'error');
    } finally {
      setDisputeBusy(false);
    }
  }, [jobId, effectiveToken, disputeReason, loadJob]);

  if (!jobId) {
    return (
      <div className="card border-void-700 p-6">
        <p className="text-gray-400">Missing job ID.</p>
        <Link to="/board" className="mt-4 inline-block text-neon-cyan hover:underline">
          ← Back to board
        </Link>
      </div>
    );
  }

  if (loading) {
    return (
      <div className="space-y-4">
        <div className="skeleton h-8 w-48" />
        <div className="skeleton h-4 w-full" />
        <div className="skeleton h-24 w-full" />
        <div className="skeleton h-12 w-32" />
      </div>
    );
  }

  if (error || !job) {
    return (
      <div className="card border-yellow-700/40 p-6">
        <p className="text-yellow-300 font-medium">{error ?? 'Job not found'}</p>
        <Link to="/board" className="mt-4 inline-block text-neon-cyan hover:underline">
          ← Back to board
        </Link>
      </div>
    );
  }

  const status = job.status ?? 'unknown';
  const description = job.input_data?.description ?? 'No description';
  const amountSpecks = Number(job.amount_specks ?? 0);
  const contest = job.contest;
  const isContest = contest?.enabled === true;
  const canDispute = ['running', 'awaiting_approval', 'multisig_pending'].includes(status);
  const ontologyGuideUrl = 'https://github.com/nightpay/nightpay/blob/master/skills/nightpay/ontology/ontology.md';
  const hashPlaceholder = '<receipt_hash>';

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <Link to="/board" className="text-sm font-medium text-gray-400 hover:text-neon-cyan transition-colors flex items-center gap-1">
          ← Back to board
        </Link>
        <span className="text-[10px] uppercase tracking-widest text-gray-500 font-bold">
          job {truncateHash(jobId, 6)}
        </span>
      </div>

      <div className="card card-elevated p-6 border-l-4 border-l-neon-cyan/80">
        <h1 className="text-xl font-bold text-white mb-2 truncate" title={description}>
          {description.slice(0, 120)}{description.length > 120 ? '…' : ''}
        </h1>
        <div className="flex flex-wrap items-center gap-4 text-sm">
          <span className="text-gray-500">
            Status: <span className="font-semibold text-gray-300">{status}</span>
          </span>
          <span className="text-neon-cyan font-semibold">{formatNight(amountSpecks)}</span>
          {job.started_at && (
            <span className="text-gray-500">Started {timeAgo(String(job.started_at))}</span>
          )}
          {isContest && (
            <span className="rounded-md border border-void-600 bg-void-800/60 px-2 py-0.5 text-xs text-gray-400">
              Contest · min {contest?.min_agents ?? 0} agents
            </span>
          )}
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <section className="card border-void-700 p-4">
          <h2 className="text-sm font-bold uppercase tracking-widest text-gray-400">What "View / Manage" means</h2>
          <p className="mt-2 text-xs text-gray-400">
            This page is the operator control surface for a single <code className="text-neon-cyan">BountyJob</code>: check status, review submissions, vote/select winners, dispute when needed, and complete settlement.
          </p>
          <ol className="mt-3 space-y-1 text-xs text-gray-400">
            <li>1. Load submissions with a valid job token.</li>
            <li>2. Approve/reject evidence or select a winner in contest mode.</li>
            <li>3. Complete settlement and verify the resulting receipt hash.</li>
          </ol>
          <div className="mt-3 flex flex-wrap gap-3 text-xs">
            <Link to="/get-started" className="text-neon-cyan hover:text-night-300">Get Started</Link>
            <Link to="/docs/skill" className="text-neon-cyan hover:text-night-300">Skills</Link>
            <a href="https://github.com/nightpay/nightpay" target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">GitHub</a>
          </div>
        </section>

        <section className="card border-void-700 p-4">
          <h2 className="text-sm font-bold uppercase tracking-widest text-gray-400">Ontology connections</h2>
          <p className="mt-2 text-xs text-gray-400">
            <code className="text-neon-cyan">Pool -&gt; BountyJob -&gt; Delegation -&gt; Submission -&gt; VotingSession -&gt; ReceiptCredential</code>
          </p>
          <p className="mt-2 text-xs text-gray-400">
            Job actions on this page update nodes in that graph. Final payout state becomes a verifiable <code className="text-neon-cyan">ReceiptCredential</code>.
          </p>
          <div className="mt-3 flex flex-wrap gap-3 text-xs">
            <a href={`${apiUrlForDocs()}/ontology`} target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">Ontology API</a>
            <a href={ontologyGuideUrl} target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">Ontology guide</a>
            <Link to="/verify" className="text-neon-cyan hover:text-night-300">Verify receipt</Link>
          </div>
        </section>
      </div>

      <section className="card border-void-700 p-4">
        <h2 className="text-sm font-bold uppercase tracking-widest text-gray-400 mb-3">Operator commands</h2>
        <div className="space-y-2">
          <CommandSnippet
            label="Inspect job status"
            command={`curl -sS "$NIGHTPAY_API_URL/status/${jobId}" | python3 -m json.tool`}
          />
          <CommandSnippet
            label="Load protected submissions"
            command={`curl -sS -H "Authorization: Bearer <job_token>" "$NIGHTPAY_API_URL/submissions/${jobId}" | python3 -m json.tool`}
          />
          <CommandSnippet
            label="Raise dispute"
            command={`curl -sS -X POST -H "Authorization: Bearer <job_token>" -H "Content-Type: application/json" "$NIGHTPAY_API_URL/dispute/${jobId}" -d '{"reason":"evidence mismatch"}'`}
          />
          <CommandSnippet
            label="Complete + verify settlement"
            command={`bash skills/nightpay/scripts/gateway.sh complete ${jobId} <bounty_commitment> && bash skills/nightpay/scripts/gateway.sh verify-receipt ${hashPlaceholder}`}
          />
        </div>
      </section>

      {/* Authorized section: job token + submissions + vote / select / dispute */}
      <div className="card border-void-700 p-6">
        <h2 className="text-sm font-bold uppercase tracking-widest text-gray-400 mb-4">
          Bounty creator / operator
        </h2>
        <p className="text-xs text-gray-500 mb-4">
          Use the job token from <code>start_job</code> to view submissions, select winner, or dispute.
        </p>
        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="job-token" className="mb-1.5 block text-[11px] font-medium uppercase tracking-widest text-gray-500">
              Job token
            </label>
            <input
              id="job-token"
              type="password"
              className="input-field w-full h-10 text-sm bg-void-800/80 border-void-700"
              placeholder="Paste job_token from start_job"
              value={jobToken}
              onChange={(e) => setJobToken(e.target.value)}
            />
          </div>
          <div className="flex items-end gap-2">
            <button
              type="button"
              onClick={loadSubmissions}
              disabled={submissionsLoading || !effectiveToken}
              className="btn-primary disabled:opacity-50 disabled:cursor-not-allowed h-10 px-5 text-sm"
            >
              {submissionsLoading ? 'Loading…' : 'Load submissions'}
            </button>
          </div>
        </div>
        {submissionsError && (
          <p className="mt-2 text-xs text-red-400">{submissionsError}</p>
        )}

        {submissionsData && (
          <div className="mt-6 pt-6 border-t border-void-700">
            <h3 className="text-sm font-bold uppercase tracking-widest text-gray-400 mb-3">
              Submissions ({submissionsData.count})
            </h3>
            {submissionsData.voting && (
              <p className="text-xs text-gray-500 mb-3">
                Voting ends: {submissionsData.voting.ends_at ?? '—'} · Eligible voters: {submissionsData.voting.eligible_voters_count ?? 0}
              </p>
            )}
            <div className="mb-4 flex flex-wrap items-center gap-2">
              <label htmlFor="voter-id" className="text-[11px] font-medium uppercase tracking-widest text-gray-500">
                Your agent ID (to vote)
              </label>
              <input
                id="voter-id"
                type="text"
                className="input-field h-9 w-48 text-sm bg-void-800/80 border-void-700"
                placeholder="e.g. agent-alpha"
                value={voterId}
                onChange={(e) => setVoterId(e.target.value)}
              />
              <button
                type="button"
                onClick={() => {
                  try {
                    window.localStorage.setItem('nightpay.agent_id', voterId);
                    toast('Agent ID saved', 'success');
                  } catch {
                    toast('Could not save', 'error');
                  }
                }}
                className="rounded-lg border border-void-600 bg-void-800 px-3 py-1.5 text-xs text-gray-300 hover:bg-void-700"
              >
                Save
              </button>
            </div>
            <ul className="space-y-4">
              {submissionsData.submissions.map((sub) => {
                const workOutput = sub.payload?.work_output ?? '';
                const preview = workOutput.slice(0, 300) + (workOutput.length > 300 ? '…' : '');
                return (
                  <li
                    key={sub.submission_id}
                    className="rounded-xl border border-void-700 bg-void-800/50 p-4"
                  >
                    <div className="flex flex-wrap items-center justify-between gap-2 mb-2">
                      <span className="text-xs font-mono text-gray-500">
                        {sub.agent_id} · {truncateHash(sub.submission_id, 8)}
                        {sub.is_winner && (
                          <span className="ml-2 rounded bg-green-500/20 text-green-400 px-1.5 py-0.5 text-[10px] font-bold">
                            Winner
                          </span>
                        )}
                      </span>
                      <span className="text-xs text-gray-400">
                        <span className="text-green-400">{sub.approve_votes} approve</span>
                        {' / '}
                        <span className="text-red-400">{sub.reject_votes} reject</span>
                        {' · score '}
                        <span className="font-semibold text-gray-300">{sub.score}</span>
                      </span>
                    </div>
                    <pre className="text-xs text-gray-400 whitespace-pre-wrap break-words mb-3 max-h-32 overflow-y-auto bg-void-900/50 p-3 rounded-lg">
                      {preview || '(no work output)'}
                    </pre>
                    <div className="flex flex-wrap gap-2">
                      <button
                        type="button"
                        onClick={() => handleVote(sub.submission_id, 'approve')}
                        disabled={voteBusy[sub.submission_id]}
                        className="rounded-lg border border-green-700/50 bg-green-500/10 px-3 py-1.5 text-xs font-medium text-green-300 hover:bg-green-500/20 disabled:opacity-50"
                      >
                        {voteBusy[sub.submission_id] ? '…' : 'Approve'}
                      </button>
                      <button
                        type="button"
                        onClick={() => handleVote(sub.submission_id, 'reject')}
                        disabled={voteBusy[sub.submission_id]}
                        className="rounded-lg border border-red-700/50 bg-red-500/10 px-3 py-1.5 text-xs font-medium text-red-300 hover:bg-red-500/20 disabled:opacity-50"
                      >
                        {voteBusy[sub.submission_id] ? '…' : 'Reject'}
                      </button>
                    </div>
                  </li>
                );
              })}
            </ul>
            {isContest && submissionsData.count > 0 && (
              <div className="mt-4 pt-4 border-t border-void-700">
                <button
                  type="button"
                  onClick={handleSelectWinner}
                  disabled={selectBusy}
                  className="btn-primary disabled:opacity-50 h-10 px-5 text-sm"
                >
                  {selectBusy ? 'Selecting…' : 'Select winner'}
                </button>
                <p className="mt-2 text-[11px] text-gray-500">
                  Picks the submission with the best vote score (or tied leader). Requires job token.
                </p>
              </div>
            )}
          </div>
        )}

        {canDispute && effectiveToken && (
          <div className="mt-6 pt-6 border-t border-void-700">
            <h3 className="text-sm font-bold uppercase tracking-widest text-gray-400 mb-2">
              Dispute
            </h3>
            <textarea
              className="input-field w-full min-h-[80px] text-sm bg-void-800/80 border-void-700 mb-2"
              placeholder="Reason for dispute (optional)"
              value={disputeReason}
              onChange={(e) => setDisputeReason(e.target.value)}
            />
            <button
              type="button"
              onClick={handleDispute}
              disabled={disputeBusy}
              className="rounded-lg border border-red-700/60 bg-red-500/10 px-4 py-2 text-sm font-medium text-red-300 hover:bg-red-500/20 disabled:opacity-50"
            >
              {disputeBusy ? 'Raising…' : 'Raise dispute'}
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

function CommandSnippet({ label, command }: { label: string; command: string }) {
  return (
    <div className="rounded-lg border border-void-600 bg-void-900/70 p-3">
      <p className="mb-2 text-[11px] uppercase tracking-widest text-gray-500">{label}</p>
      <code className="block overflow-x-auto rounded bg-void-950 px-2 py-1 text-xs text-neon-cyan">{command}</code>
    </div>
  );
}
