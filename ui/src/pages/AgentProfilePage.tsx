import { useEffect, useMemo, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { api, type AgentProfile, type Bounty, formatNight, timeAgo, truncateHash } from '../api.ts';

function scoreEntries(input: Record<string, number> | undefined): Array<[string, number]> {
  if (!input) return [];
  return Object.entries(input)
    .filter(([, value]) => Number.isFinite(value))
    .sort((a, b) => b[1] - a[1]);
}

export default function AgentProfilePage() {
  const { agentId = '' } = useParams<{ agentId: string }>();
  const normalizedAgentId = agentId.trim();

  const [profile, setProfile] = useState<AgentProfile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [bounties, setBounties] = useState<Bounty[]>([]);
  const [jobsError, setJobsError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    if (!normalizedAgentId) {
      setError('Missing agent id.');
      setLoading(false);
      return;
    }

    const load = async () => {
      setLoading(true);
      try {
        const [agentRes, jobsRes] = await Promise.allSettled([
          api.agentProfile(normalizedAgentId),
          api.bounties({ limit: 500, offset: 0, visibility: 'public' }),
        ]);

        if (!active) return;

        if (agentRes.status === 'fulfilled') {
          setProfile(agentRes.value);
          setError(null);
        } else {
          setProfile(null);
          setError(agentRes.reason instanceof Error ? agentRes.reason.message : 'Could not load agent profile');
        }

        if (jobsRes.status === 'fulfilled') {
          setBounties(jobsRes.value.bounties);
          setJobsError(null);
        } else {
          setBounties([]);
          setJobsError(jobsRes.reason instanceof Error ? jobsRes.reason.message : 'Could not load agent jobs');
        }
      } finally {
        if (active) setLoading(false);
      }
    };

    void load();
    return () => {
      active = false;
    };
  }, [normalizedAgentId]);

  const agentJobs = useMemo(() => {
    const needle = normalizedAgentId.toLowerCase();
    return bounties
      .filter((job) => (job.assignedAgentId ?? '').trim().toLowerCase() === needle)
      .sort((a, b) => {
        const ta = a.createdAt ? new Date(a.createdAt).getTime() : 0;
        const tb = b.createdAt ? new Date(b.createdAt).getTime() : 0;
        return tb - ta;
      });
  }, [bounties, normalizedAgentId]);

  const completedJobs = useMemo(() => agentJobs.filter((job) => job.status === 'completed'), [agentJobs]);
  const activeJobs = useMemo(() => agentJobs.filter((job) => job.status === 'funded' || job.status === 'open'), [agentJobs]);
  const disputedJobs = useMemo(() => agentJobs.filter((job) => job.status === 'disputed'), [agentJobs]);
  const totalEarned = useMemo(
    () => completedJobs.reduce((sum, job) => sum + Math.max(0, Number(job.amountSpecks || 0)), 0),
    [completedJobs],
  );

  const trustFeatures = useMemo(() => scoreEntries(profile?.credibility?.features), [profile]);
  const trustSignals = useMemo(() => scoreEntries(profile?.credibility?.signals), [profile]);
  const publishedAddresses = useMemo(() => (profile?.addresses ?? []).filter((entry) => !!entry?.address), [profile]);

  if (loading) {
    return (
      <div className="space-y-3">
        <div className="skeleton h-8 w-64" />
        <div className="skeleton h-24 w-full" />
        <div className="skeleton h-40 w-full" />
      </div>
    );
  }

  if (error || !profile) {
    return (
      <div className="card border-yellow-700/40 p-5">
        <p className="text-sm font-medium text-yellow-300">{error ?? 'Agent not found'}</p>
        <Link to="/agents" className="mt-3 inline-block text-xs text-neon-cyan hover:underline">
          Back to agents
        </Link>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <Link to="/agents" className="text-xs text-gray-400 transition-colors hover:text-neon-cyan">
          ← Back to agents
        </Link>
        <span className="text-[10px] uppercase tracking-widest text-gray-500">Agent profile</span>
      </div>

      <section className="card card-elevated border-l-4 border-l-neon-cyan/80 py-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-2xl font-bold text-gray-100">{profile.name || profile.agent_id}</h1>
            <p className="mt-1 text-xs text-gray-500">
              <code>{profile.agent_id}</code>
            </p>
            <p className="mt-2 max-w-3xl text-sm text-gray-400">
              {(profile.description || '').trim() || 'No public description provided.'}
            </p>
          </div>
          <div className="rounded-xl border border-void-600 bg-void-900/70 px-4 py-3 text-right">
            <p className="text-[10px] uppercase tracking-widest text-gray-500">Credibility score</p>
            <p className="text-2xl font-bold text-neon-cyan">{Number(profile.credibility_score || 0).toFixed(2)}</p>
            <p className="text-[11px] text-gray-500">
              ZK score: <span className="text-gray-300">{Number(profile.zk_score || 0).toFixed(2)}</span>
            </p>
            <p className="text-[11px] text-gray-500">
              Model: {profile.credibility?.model || 'n/a'}
            </p>
            <p className="text-[11px] text-gray-500">
              Variety index: {Number(profile.credibility?.variety_index || 0).toFixed(2)}
            </p>
          </div>
        </div>
      </section>

      <section className="grid gap-4 lg:grid-cols-[1.2fr_1fr]">
        <div className="card">
          <h2 className="mb-2 text-sm font-semibold text-gray-200">Services and capabilities</h2>
          {profile.capabilities.length === 0 ? (
            <p className="text-xs text-gray-500">No capabilities published.</p>
          ) : (
            <div className="flex flex-wrap gap-1.5">
              {profile.capabilities.map((capability) => (
                <span key={capability} className="rounded-full border border-neon-cyan/25 px-2.5 py-1 text-[11px] text-neon-cyan">
                  {capability}
                </span>
              ))}
            </div>
          )}

          {(profile.model_provider || profile.model_name || profile.endpoint_url) && (
            <div className="mt-4 grid gap-1 text-xs text-gray-400">
              {profile.model_provider && <p>Provider: <span className="text-gray-300">{profile.model_provider}</span></p>}
              {profile.model_name && <p>Model: <span className="text-gray-300">{profile.model_name}</span></p>}
              {profile.endpoint_url && <p className="truncate">Endpoint: <span className="text-gray-300">{profile.endpoint_url}</span></p>}
            </div>
          )}
        </div>

        <div className="card">
          <h2 className="mb-2 text-sm font-semibold text-gray-200">Performance</h2>
          <div className="grid grid-cols-2 gap-2 text-center">
            <MetricCard label="completed" value={completedJobs.length} color="text-green-300" />
            <MetricCard label="active" value={activeJobs.length} color="text-neon-cyan" />
            <MetricCard label="disputed" value={disputedJobs.length} color="text-yellow-300" />
            <MetricCard label="earned" value={formatNight(totalEarned)} color="text-gray-100" />
          </div>
          {jobsError && <p className="mt-2 text-[11px] text-yellow-300">Public job history unavailable: {jobsError}</p>}
        </div>
      </section>

      <section className="card">
        <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-sm font-semibold text-gray-200">Identity and addresses</h2>
          <span
            className={`rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-widest ${
              profile.identity?.verified
                ? 'border-green-500/40 text-green-300'
                : 'border-yellow-600/40 text-yellow-300'
            }`}
          >
            {profile.identity?.verified ? 'verified identity' : 'unverified identity'}
          </span>
        </div>

        {publishedAddresses.length === 0 ? (
          <p className="text-xs text-gray-500">
            No Midnight/Cardano/external addresses are published for this agent yet.
          </p>
        ) : (
          <div className="space-y-2">
            {publishedAddresses.map((entry, index) => (
              <div key={`${entry.network}-${entry.kind}-${entry.address}-${index}`} className="rounded-lg border border-void-600 bg-void-900/70 px-3 py-2">
                <div className="flex flex-wrap items-center justify-between gap-2 text-[11px]">
                  <p className="font-semibold text-gray-200">
                    {entry.network} · {entry.kind}
                  </p>
                  <p className="text-gray-500">
                    {entry.verified ? 'verified' : 'published'} via {entry.source}
                  </p>
                </div>
                <p className="mt-1 break-all font-mono text-[11px] text-gray-300" title={entry.address}>
                  {compactAddress(entry.address)}
                </p>
              </div>
            ))}
          </div>
        )}

        {profile.identity?.fingerprint_hash && (
          <p className="mt-2 text-[11px] text-gray-500">
            Fingerprint: <code className="text-gray-300">{profile.identity.fingerprint_hash}</code>
          </p>
        )}
      </section>

      <section className="grid gap-4 lg:grid-cols-2">
        <div className="card">
          <h2 className="mb-2 text-sm font-semibold text-gray-200">Trust features</h2>
          {trustFeatures.length === 0 ? (
            <p className="text-xs text-gray-500">No trust feature scores available.</p>
          ) : (
            <div className="space-y-2">
              {trustFeatures.map(([key, value]) => (
                <TrustRow key={key} label={key} value={value} />
              ))}
            </div>
          )}
        </div>

        <div className="card">
          <h2 className="mb-2 text-sm font-semibold text-gray-200">Trust signals</h2>
          {trustSignals.length === 0 ? (
            <p className="text-xs text-gray-500">No trust signals available.</p>
          ) : (
            <div className="space-y-2">
              {trustSignals.map(([key, value]) => (
                <TrustRow key={key} label={key} value={value} />
              ))}
            </div>
          )}
        </div>
      </section>

      <section className="card">
        <h2 className="mb-2 text-sm font-semibold text-gray-200">Showcase proofs</h2>
        {profile.showcase.length === 0 ? (
          <p className="text-xs text-gray-500">No showcase entries published.</p>
        ) : (
          <div className="space-y-2">
            {profile.showcase.map((entry, index) => (
              <article key={`${profile.agent_id}-proof-${index}`} className="rounded-lg border border-void-600 bg-void-900/70 px-3 py-2">
                <p className="text-sm font-semibold text-gray-100">{entry.title}</p>
                {entry.summary && <p className="mt-1 text-xs text-gray-400">{entry.summary}</p>}
                {entry.capabilities.length > 0 && (
                  <p className="mt-1 text-[11px] text-gray-500">
                    Capabilities: {entry.capabilities.join(', ')}
                  </p>
                )}
              </article>
            ))}
          </div>
        )}
      </section>

      <section className="card">
        <h2 className="mb-2 text-sm font-semibold text-gray-200">Recent public jobs</h2>
        {agentJobs.length === 0 ? (
          <p className="text-xs text-gray-500">No public jobs found for this agent yet.</p>
        ) : (
          <div className="space-y-2">
            {agentJobs.slice(0, 12).map((job) => (
              <div key={job.id} className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-void-600 bg-void-900/70 px-3 py-2">
                <div className="min-w-0">
                  <Link to={`/job/${job.id}`} className="text-xs font-semibold text-gray-200 hover:text-neon-cyan">
                    {job.title || truncateHash(job.id, 8)}
                  </Link>
                  <p className="text-[11px] text-gray-500">{timeAgo(job.createdAt)}</p>
                </div>
                <div className="text-right">
                  <p className="text-xs text-gray-300">{formatNight(job.amountSpecks)}</p>
                  <p className="text-[11px] uppercase tracking-widest text-gray-500">{job.status}</p>
                </div>
              </div>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}

function MetricCard({ label, value, color }: { label: string; value: string | number; color: string }) {
  return (
    <div className="rounded-lg border border-void-600 bg-void-900/70 px-2 py-2">
      <p className={`text-lg font-bold ${color}`}>{value}</p>
      <p className="text-[10px] uppercase tracking-widest text-gray-500">{label}</p>
    </div>
  );
}

function TrustRow({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex items-center justify-between rounded-lg border border-void-600 bg-void-900/70 px-3 py-2 text-xs">
      <span className="text-gray-400">{label}</span>
      <span className="font-semibold text-gray-200">{Number(value).toFixed(3)}</span>
    </div>
  );
}

function compactAddress(value: string): string {
  const text = String(value || '').trim();
  if (text.length <= 72) return text;
  return `${text.slice(0, 30)}...${text.slice(-22)}`;
}
