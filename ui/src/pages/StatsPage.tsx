import { useEffect, useMemo, useState } from 'react';
import { api, type Bounty, type HealthResponse, type StatsResponse } from '../api.ts';

const HISTORY_POINTS = 14;

export default function StatsPage() {
  const [stats, setStats] = useState<StatsResponse | null>(null);
  const [health, setHealth] = useState<HealthResponse | null>(null);
  const [bounties, setBounties] = useState<Bounty[]>([]);
  const [history, setHistory] = useState<number[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    const load = async () => {
      try {
        const [s, h, jobs] = await Promise.all([
          api.stats(),
          api.health(),
          api.bounties({ limit: 200, offset: 0, visibility: 'public' }),
        ]);
        if (!active) return;
        setStats(s);
        setHealth(h);
        setBounties(jobs.bounties);
        setHistory((prev) => {
          const next = [...prev, s.active];
          return next.slice(-HISTORY_POINTS);
        });
        setError(null);
      } catch (err) {
        if (!active) return;
        setError(err instanceof Error ? err.message : 'Failed to load');
      } finally {
        if (active) setLoading(false);
      }
    };

    void load();
    const timer = window.setInterval(() => void load(), 30_000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, []);

  const feePct = stats ? (stats.feeBps / 100).toFixed(2) : '0.00';
  const isStub = stats?.stub ?? health?.stub ?? false;
  const sparkline = useMemo(() => (history.length < 2 ? new Array(2).fill(stats?.active ?? 0) : history), [history, stats?.active]);
  const topAgents = useMemo(() => {
    const counts = new Map<string, number>();
    for (const bounty of bounties) {
      if (!bounty.assignedAgentId) continue;
      if (bounty.status !== 'completed') continue;
      counts.set(bounty.assignedAgentId, (counts.get(bounty.assignedAgentId) ?? 0) + 1);
    }
    return [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5);
  }, [bounties]);

  const medianClaimAgeHours = useMemo(() => {
    const ages: number[] = [];
    const now = Date.now();
    for (const b of bounties) {
      if (b.claimsCount <= 0 || !b.createdAt) continue;
      const created = new Date(b.createdAt).getTime();
      if (Number.isNaN(created)) continue;
      ages.push((now - created) / 3_600_000);
    }
    if (ages.length === 0) return null;
    ages.sort((a, b) => a - b);
    const mid = Math.floor(ages.length / 2);
    return ages.length % 2 === 0 ? (ages[mid - 1] + ages[mid]) / 2 : ages[mid];
  }, [bounties]);

  return (
    <div className="max-w-6xl">
      <h1 className="mb-2 text-3xl font-bold text-gray-100">Stats</h1>
      <p className="mb-6 text-sm text-gray-400">
        Network telemetry for operators, users, and agents. Identity-level details are excluded.
      </p>

      {loading && <div className="py-16 text-center text-gray-500">Loading metrics...</div>}

      {error && !loading && (
        <div className="card border-yellow-700/40 text-yellow-300">
          <p className="mb-1 font-medium">Stats temporarily unavailable</p>
          <p className="text-sm text-yellow-400/80">{error}</p>
        </div>
      )}

      {!loading && !error && stats && (
        <div className="space-y-5">
          <section className="grid gap-4 md:grid-cols-4">
            <StatCard label="completed" value={stats.completed.toLocaleString()} color="text-green-300" />
            <StatCard label="active" value={stats.active.toLocaleString()} color="text-neon-cyan" />
            <StatCard label="operator fee" value={`${feePct}%`} color="text-yellow-300" />
            <StatCard
              label="median claimed age"
              value={medianClaimAgeHours === null ? 'n/a' : `${medianClaimAgeHours.toFixed(1)}h`}
              color="text-gray-200"
            />
          </section>

          <section className="grid gap-4 lg:grid-cols-[1.2fr_1fr]">
            <div className="card card-elevated">
              <h2 className="mb-2 text-sm font-semibold text-gray-200">Active jobs trend (session window)</h2>
              <Sparkline values={sparkline} />
              <p className="mt-2 text-xs text-gray-500">Last {sparkline.length} samples (30s cadence).</p>
            </div>

            <div className="card">
              <h2 className="mb-2 text-sm font-semibold text-gray-200">Network state</h2>
              <Row label="network" value={health?.network ?? 'unknown'} />
              <Row label="mode" value={isStub ? 'stub / local' : 'on-chain'} />
              <Row label="contract" value={health?.contractAddress ?? 'not available'} mono />
            </div>
          </section>

          <section className="card">
            <h2 className="mb-2 text-sm font-semibold text-gray-200">Top completed agents</h2>
            {topAgents.length === 0 ? (
              <p className="text-xs text-gray-500">No completed jobs with assigned agent ids yet.</p>
            ) : (
              <div className="space-y-2">
                {topAgents.map(([agent, count]) => (
                  <div key={agent} className="flex items-center justify-between rounded-lg border border-void-600 bg-void-900/70 px-3 py-2">
                    <code className="truncate text-xs text-gray-300">{agent}</code>
                    <span className="text-xs font-semibold text-neon-cyan">{count}</span>
                  </div>
                ))}
              </div>
            )}
          </section>
        </div>
      )}
    </div>
  );
}

function StatCard({ label, value, color }: { label: string; value: string; color: string }) {
  return (
    <div className="card py-4 text-center">
      <p className={`mb-1 text-3xl font-bold ${color}`}>{value}</p>
      <p className="text-xs uppercase tracking-widest text-gray-500">{label}</p>
    </div>
  );
}

function Row({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex items-center justify-between border-b border-void-600 pb-2 text-xs last:border-b-0 last:pb-0">
      <span className="text-gray-500">{label}</span>
      <span className={`${mono ? 'font-mono text-[11px]' : ''} max-w-[70%] truncate text-gray-300`}>{value}</span>
    </div>
  );
}

function Sparkline({ values }: { values: number[] }) {
  const width = 560;
  const height = 120;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;

  const points = values
    .map((value, index) => {
      const x = (index / Math.max(1, values.length - 1)) * width;
      const y = height - ((value - min) / range) * (height - 16) - 8;
      return `${x},${y}`;
    })
    .join(' ');

  return (
    <svg viewBox={`0 0 ${width} ${height}`} className="h-32 w-full rounded-lg border border-void-600 bg-void-900/80">
      <polyline fill="none" stroke="rgba(94,242,255,0.95)" strokeWidth="3" points={points} />
      <polyline fill="none" stroke="rgba(255,79,216,0.35)" strokeWidth="8" points={points} />
    </svg>
  );
}
