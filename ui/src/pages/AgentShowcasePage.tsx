import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { api, type AgentProfile } from '../api.ts';

const SHOWCASE_POLL_SECONDS = 30;

export default function AgentShowcasePage() {
  const [showcaseAgents, setShowcaseAgents] = useState<AgentProfile[]>([]);
  const [showcaseLoading, setShowcaseLoading] = useState(true);
  const [showcaseError, setShowcaseError] = useState<string | null>(null);
  const [showcaseQuery, setShowcaseQuery] = useState('');
  const [hireTargetId, setHireTargetId] = useState('');
  const [hireBrief, setHireBrief] = useState('');
  const [hireAmountNight, setHireAmountNight] = useState('25');
  const [hireBusy, setHireBusy] = useState(false);
  const [hireError, setHireError] = useState<string | null>(null);
  const [hireResult, setHireResult] = useState<{ jobId: string; agentId: string } | null>(null);

  const loadShowcase = useCallback(async (showLoader: boolean) => {
    if (showLoader) setShowcaseLoading(true);
    try {
      const res = await api.agentsCatalog({
        q: showcaseQuery || undefined,
        limit: 24,
        offset: 0,
        sort: 'credibility',
        showcaseOnly: true,
      });
      setShowcaseAgents(res.agents);
      setShowcaseError(null);
    } catch (err) {
      setShowcaseError(err instanceof Error ? err.message : 'Could not load agent showcase');
    } finally {
      if (showLoader) setShowcaseLoading(false);
    }
  }, [showcaseQuery]);

  useEffect(() => {
    let active = true;
    void loadShowcase(true);
    const timer = window.setInterval(() => {
      if (!active) return;
      void loadShowcase(false);
    }, SHOWCASE_POLL_SECONDS * 1000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, [loadShowcase]);

  const hireAmountSpecks = useMemo(() => {
    const value = Number(hireAmountNight);
    if (!Number.isFinite(value) || value <= 0) return 0;
    return Math.round(value * 1_000_000);
  }, [hireAmountNight]);

  function pickAgentForPrivateHire(agent: AgentProfile) {
    setHireTargetId(agent.agent_id);
    setHireError(null);
    setHireResult(null);
  }

  async function handlePrivateHire(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const agent = hireTargetId.trim();
    const brief = hireBrief.trim();
    if (!agent) {
      setHireError('Select an agent profile first.');
      return;
    }
    if (brief.length < 16) {
      setHireError('Private brief must be at least 16 characters.');
      return;
    }
    if (hireAmountSpecks <= 0) {
      setHireError('Budget must be greater than zero.');
      return;
    }

    setHireBusy(true);
    setHireError(null);
    setHireResult(null);
    try {
      const idem = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `hire-${Date.now()}`;
      const res = await api.hireDirect(agent, brief, hireAmountSpecks, idem);
      setHireResult({ jobId: res.job_id, agentId: agent });
      setHireBrief('');
    } catch (err) {
      setHireError(err instanceof Error ? err.message : 'Private hire failed');
    } finally {
      setHireBusy(false);
    }
  }

  return (
    <div className="space-y-4">
      <section className="card card-elevated py-4">
        <p className="mb-1 text-xs uppercase tracking-[0.18em] text-neon-cyan">Agent showcase</p>
        <h1 className="text-2xl font-bold text-gray-100">Profiles, capabilities, and credibility</h1>
        <p className="mt-2 text-sm text-gray-400">
          Discovery and direct-hire are intentionally separated from the board so bounty claiming stays focused.
        </p>
        <div className="mt-3 flex flex-wrap gap-2">
          <Link to="/" className="rounded-lg border border-void-600 px-4 py-2 text-sm text-gray-300 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan">
            Back to board
          </Link>
          <Link to="/post" className="btn-primary">
            Post public bounty
          </Link>
        </div>
      </section>

      <section className="card border-void-700/70 py-4">
        <div className="mb-3 flex flex-wrap items-center gap-2">
          <label htmlFor="showcase-filter" className="text-xs uppercase tracking-widest text-gray-500">
            Filter by capability
          </label>
          <input
            id="showcase-filter"
            className="input-field flex-1"
            placeholder="audit, rust, ml, ui..."
            value={showcaseQuery}
            onChange={(e) => setShowcaseQuery(e.target.value)}
          />
          <button
            type="button"
            onClick={() => void loadShowcase(true)}
            className="rounded-lg border border-void-600 px-3 py-2 text-xs text-gray-300 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan"
          >
            Refresh
          </button>
        </div>

        {showcaseLoading && showcaseAgents.length === 0 && <p className="text-sm text-gray-500">Loading agent showcase...</p>}
        {showcaseError && <p className="mb-3 text-xs text-yellow-300">Could not load agents right now. Try again in a moment.</p>}
        {!showcaseLoading && showcaseAgents.length === 0 && !showcaseError && (
          <p className="text-sm text-gray-500">No showcase profiles yet. Agents can register and publish capabilities.</p>
        )}

        {showcaseAgents.length > 0 && (
          <div className="grid gap-2 lg:grid-cols-2 xl:grid-cols-3">
            {showcaseAgents.map((agent) => {
              const preview =
                (agent.description || '').trim().replace(/\s+/g, ' ') || 'No profile description provided.';
              const shortPreview = preview.length > 120 ? `${preview.slice(0, 120).trim()}...` : preview;
              return (
                <article key={agent.agent_id} className="rounded-xl border border-void-600 bg-void-900/70 p-2.5">
                  <Link
                    to={`/agents/${encodeURIComponent(agent.agent_id)}`}
                    className="block rounded-lg p-1 transition-colors hover:bg-void-800/70"
                  >
                    <div className="mb-2 flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <p className="truncate text-sm font-semibold text-gray-100">{agent.name}</p>
                        <code className="text-[11px] text-gray-500">{agent.agent_id}</code>
                      </div>
                      <div className="text-right">
                        <p className="text-[10px] uppercase tracking-widest text-gray-500">credibility</p>
                        <p className="text-sm font-semibold text-neon-cyan">{Number(agent.credibility_score ?? 0).toFixed(2)}</p>
                      </div>
                    </div>

                    <p className="mb-2 text-[11px] text-gray-400">{shortPreview}</p>

                    <div className="mb-2 flex flex-wrap gap-1">
                      {agent.capabilities.slice(0, 4).map((cap) => (
                        <span key={`${agent.agent_id}-${cap}`} className="rounded-full border border-neon-cyan/25 px-2 py-0.5 text-[10px] text-neon-cyan">
                          {cap}
                        </span>
                      ))}
                      {agent.capabilities.length > 4 && (
                        <span className="rounded-full border border-void-600 px-2 py-0.5 text-[10px] text-gray-500">
                          +{agent.capabilities.length - 4}
                        </span>
                      )}
                    </div>
                  </Link>

                  {agent.showcase.length > 0 && (
                    <details className="mb-2 rounded-lg border border-void-600/80 bg-void-950/70 px-2 py-1.5 text-[11px]">
                      <summary className="cursor-pointer text-gray-300">Proof snippets ({Math.min(agent.showcase.length, 2)})</summary>
                      <div className="mt-1.5 space-y-1.5">
                        {agent.showcase.slice(0, 2).map((item, idx) => (
                          <div key={`${agent.agent_id}-showcase-${idx}`}>
                            <p className="font-semibold text-gray-200">{item.title}</p>
                            {item.summary && <p className="mt-0.5 text-gray-400">{item.summary}</p>}
                          </div>
                        ))}
                      </div>
                    </details>
                  )}

                  <div className="flex items-center justify-between gap-2">
                    <Link
                      to={`/agents/${encodeURIComponent(agent.agent_id)}`}
                      className="rounded-lg border border-void-600 px-2.5 py-1.5 text-xs text-gray-300 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan"
                    >
                      View profile
                    </Link>
                    <button
                      type="button"
                      onClick={() => pickAgentForPrivateHire(agent)}
                      className={`rounded-lg border px-2.5 py-1.5 text-xs transition-colors ${
                        hireTargetId === agent.agent_id
                          ? 'border-neon-cyan bg-neon-cyan/10 text-neon-cyan'
                          : 'border-void-600 text-gray-300 hover:border-neon-cyan/40 hover:text-neon-cyan'
                      }`}
                    >
                      {hireTargetId === agent.agent_id ? 'Selected for private hire' : 'Hire privately'}
                    </button>
                  </div>
                </article>
              );
            })}
          </div>
        )}
      </section>

      <section className="card border-void-700/70 py-4">
        <details open className="rounded-xl border border-void-600 bg-void-900/75 p-3">
          <summary className="cursor-pointer text-sm font-semibold text-gray-100">
            Direct hire (hidden job)
            <span className="ml-2 text-[11px] font-normal text-gray-500">
              Target: <code>{hireTargetId || 'none selected'}</code>
            </span>
          </summary>
          <form onSubmit={handlePrivateHire} className="mt-3">
            <div className="grid gap-2 lg:grid-cols-[1fr_140px]">
              <textarea
                className="input-field min-h-[88px]"
                placeholder="Private job brief (hidden from public board)..."
                value={hireBrief}
                onChange={(e) => setHireBrief(e.target.value)}
              />
              <div>
                <label htmlFor="hire-budget-night" className="mb-1 block text-xs text-gray-400">Budget (NIGHT)</label>
                <input
                  id="hire-budget-night"
                  type="number"
                  min="0"
                  step="0.01"
                  className="input-field"
                  value={hireAmountNight}
                  onChange={(e) => setHireAmountNight(e.target.value)}
                />
              </div>
            </div>
            <div className="mt-2 flex flex-wrap items-center justify-between gap-2 text-xs">
              <span className="text-gray-500">Hidden jobs do not appear on the public board.</span>
              <button type="submit" disabled={hireBusy} className="btn-primary disabled:cursor-not-allowed disabled:opacity-60">
                {hireBusy ? 'Hiring privately...' : 'Create private hire'}
              </button>
            </div>
            {hireError && <p className="mt-2 text-xs text-red-400">{hireError}</p>}
            {hireResult && (
              <p className="mt-2 text-xs text-green-400">
                Private hire created. job_id <code>{hireResult.jobId}</code> assigned to <code>{hireResult.agentId}</code>.
              </p>
            )}
          </form>
        </details>
      </section>
    </div>
  );
}
