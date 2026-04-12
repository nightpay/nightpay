import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, formatNight, timeAgo, type Bounty, type HealthResponse, type StatsResponse } from '../api.ts';

const HISTORY_POINTS = 24;
type AvailabilityResponse = { status: string; total_jobs: number; active_jobs: number; potential_use_cases_count?: number };
type SourceHealth = { bridge: boolean; mip: boolean };
type BountyStatus = Bounty['status'];

const EMPTY_STATUS_COUNTS: Record<BountyStatus, number> = {
  open: 0,
  funded: 0,
  completed: 0,
  disputed: 0,
};

export default function StatsPage() {
  const [stats, setStats] = useState<StatsResponse | null>(null);
  const [health, setHealth] = useState<HealthResponse | null>(null);
  const [availability, setAvailability] = useState<AvailabilityResponse | null>(null);
  const [bounties, setBounties] = useState<Bounty[]>([]);
  const [history, setHistory] = useState<number[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [warning, setWarning] = useState<string | null>(null);
  const [sources, setSources] = useState<SourceHealth>({ bridge: false, mip: false });
  const [lastUpdatedAt, setLastUpdatedAt] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    const load = async () => {
      try {
        const [statsRes, healthRes, jobsRes, availabilityRes] = await Promise.allSettled([
          api.stats(),
          api.health(),
          api.bounties({ limit: 200, offset: 0, visibility: 'public' }),
          api.availability(),
        ]);
        if (!active) return;

        const bridgeUp = statsRes.status === 'fulfilled' || healthRes.status === 'fulfilled';
        const mipUp = jobsRes.status === 'fulfilled' || availabilityRes.status === 'fulfilled';
        setSources({ bridge: bridgeUp, mip: mipUp });
        setLastUpdatedAt(Date.now());

        if (statsRes.status === 'fulfilled') setStats(statsRes.value);
        if (healthRes.status === 'fulfilled') setHealth(healthRes.value);
        if (jobsRes.status === 'fulfilled') setBounties(jobsRes.value.bounties);
        if (availabilityRes.status === 'fulfilled') setAvailability(availabilityRes.value);

        const activeSample =
          statsRes.status === 'fulfilled'
            ? statsRes.value.active
            : availabilityRes.status === 'fulfilled'
              ? Number(availabilityRes.value.active_jobs || 0)
              : jobsRes.status === 'fulfilled'
                ? jobsRes.value.bounties.filter((job) => job.status === 'open' || job.status === 'funded').length
                : null;

        if (activeSample !== null) {
          setHistory((prev) => [...prev, activeSample].slice(-HISTORY_POINTS));
        }

        if (!bridgeUp && !mipUp) {
          setError('Both bridge and MIP APIs are unreachable.');
        } else {
          setError(null);
        }

        if (bridgeUp && mipUp) {
          setWarning(null);
        } else if (!bridgeUp) {
          setWarning('Bridge metrics are offline. Showing live MIP-derived stats.');
        } else {
          setWarning('MIP job feed is degraded. Showing bridge-only stats.');
        }
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

  const statusCounts = useMemo(() => {
    const counts: Record<BountyStatus, number> = { ...EMPTY_STATUS_COUNTS };
    for (const bounty of bounties) {
      counts[bounty.status] += 1;
    }
    return counts;
  }, [bounties]);

  const totalJobs = bounties.length;
  const derivedCompleted = statusCounts.completed;
  const derivedActive = statusCounts.open + statusCounts.funded;

  const completedMetric = stats?.completed ?? derivedCompleted;
  const activeMetric = stats?.active ?? availability?.active_jobs ?? derivedActive;
  const isStub = stats?.stub ?? health?.stub ?? false;
  const feePct = stats ? `${(stats.feeBps / 100).toFixed(2)}%` : 'n/a';
  const hasAnyMetrics = Boolean(stats || health || availability || bounties.length > 0 || history.length > 0);
  const sparkline = useMemo(
    () => (history.length < 2 ? new Array(2).fill(activeMetric) : history),
    [history, activeMetric],
  );
  const trend = useMemo(() => {
    if (sparkline.length < 2) return { delta: 0, pct: 0 };
    const start = sparkline[0];
    const end = sparkline[sparkline.length - 1];
    const delta = end - start;
    const pct = start === 0 ? 0 : (delta / start) * 100;
    return { delta, pct };
  }, [sparkline]);

  const totalVolumeSpecks = useMemo(() => {
    return bounties.reduce((sum, bounty) => sum + Math.max(0, bounty.amountSpecks || 0), 0);
  }, [bounties]);

  const averageBountySpecks = totalJobs > 0 ? Math.round(totalVolumeSpecks / totalJobs) : null;
  const completionRatePct = totalJobs > 0 ? (statusCounts.completed / totalJobs) * 100 : null;
  const claimCoveragePct = useMemo(() => {
    if (totalJobs === 0) return null;
    const claimed = bounties.filter((bounty) => bounty.claimsCount > 0).length;
    return (claimed / totalJobs) * 100;
  }, [bounties, totalJobs]);
  const disputeRatePct = totalJobs > 0 ? (statusCounts.disputed / totalJobs) * 100 : null;

  const jobs24h = useMemo(() => {
    const cutoff = Date.now() - 24 * 3_600_000;
    return bounties.filter((bounty) => timestampFromIso(bounty.createdAt) >= cutoff).length;
  }, [bounties]);

  const jobs7d = useMemo(() => {
    const cutoff = Date.now() - 7 * 24 * 3_600_000;
    return bounties.filter((bounty) => timestampFromIso(bounty.createdAt) >= cutoff).length;
  }, [bounties]);

  const recentBounties = useMemo(() => {
    return [...bounties]
      .sort((a, b) => timestampFromIso(b.createdAt) - timestampFromIso(a.createdAt))
      .slice(0, 7);
  }, [bounties]);

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
  const topAgentMaxCount = topAgents.length > 0 ? topAgents[0][1] : 1;

  const statusMix = [
    { label: 'open', value: statusCounts.open, color: 'bg-neon-cyan/75' },
    { label: 'funded', value: statusCounts.funded, color: 'bg-indigo-400/75' },
    { label: 'completed', value: statusCounts.completed, color: 'bg-green-400/75' },
    { label: 'disputed', value: statusCounts.disputed, color: 'bg-yellow-400/75' },
  ];

  const lastUpdated = lastUpdatedAt ? new Date(lastUpdatedAt).toLocaleTimeString() : 'n/a';
  const trendText = trend.delta === 0 ? 'flat' : trend.delta > 0 ? 'rising' : 'cooling';
  const trendClass =
    trend.delta === 0 ? 'text-gray-300 border-void-600' : trend.delta > 0 ? 'text-green-300 border-green-700/50' : 'text-yellow-300 border-yellow-700/50';

  return (
    <div className="max-w-6xl space-y-5">
      <section className="relative overflow-hidden rounded-2xl border border-neon-cyan/35 bg-void-900/80 p-4 sm:p-6">
        <div
          aria-hidden
          className="pointer-events-none absolute -right-16 -top-16 h-44 w-44 rounded-full bg-neon-cyan/10 blur-3xl"
        />
        <div
          aria-hidden
          className="pointer-events-none absolute -bottom-16 left-12 h-44 w-44 rounded-full bg-neon-magenta/10 blur-3xl"
        />
        <div className="relative grid gap-4 lg:grid-cols-[1.2fr_0.8fr]">
          <div>
            <p className="text-xs uppercase tracking-[0.22em] text-neon-cyan">Network pulse</p>
            <h1 className="mt-2 text-3xl font-bold text-gray-100 sm:text-4xl">Stats</h1>
            <p className="mt-2 max-w-2xl text-sm text-gray-400">
              Live operator telemetry with privacy-safe aggregation only. No identity-level details are stored.
            </p>
            <div className="mt-4 flex flex-wrap gap-2">
              <SourceBadge label="Bridge API" live={sources.bridge} />
              <SourceBadge label="MIP feed" live={sources.mip} />
              <SourceBadge label={isStub ? 'Stub / local mode' : 'On-chain mode'} live={!isStub} />
            </div>
          </div>
          <div className="rounded-xl border border-void-600 bg-void-800/80 p-4">
            <p className="text-xs uppercase tracking-[0.2em] text-gray-500">Current active jobs</p>
            <p className="mt-2 text-4xl font-bold text-neon-cyan">{activeMetric.toLocaleString()}</p>
            <div className="mt-4 grid grid-cols-2 gap-3 text-xs">
              <div className="rounded-lg border border-void-600 bg-void-900/70 p-2.5">
                <p className="text-gray-500">completed</p>
                <p className="mt-1 text-lg font-semibold text-green-300">{completedMetric.toLocaleString()}</p>
              </div>
              <div className="rounded-lg border border-void-600 bg-void-900/70 p-2.5">
                <p className="text-gray-500">jobs / 24h</p>
                <p className="mt-1 text-lg font-semibold text-gray-100">{jobs24h.toLocaleString()}</p>
              </div>
            </div>
            <p className="mt-3 text-[11px] text-gray-500">Last refresh: {lastUpdated}</p>
          </div>
        </div>
      </section>

      {loading && !hasAnyMetrics && <div className="py-16 text-center text-gray-500">Loading metrics...</div>}

      {warning && (
        <div className="mb-4 rounded-xl border border-yellow-700/40 bg-yellow-950/30 px-3 py-2 text-xs text-yellow-300">
          {warning}
        </div>
      )}

      {error && !loading && !hasAnyMetrics && (
        <div className="card border-yellow-700/40 text-yellow-300">
          <p className="mb-1 font-medium">Stats temporarily unavailable</p>
          <p className="text-sm text-yellow-400/80">{error}</p>
        </div>
      )}

      {!loading && hasAnyMetrics && (
        <div className="space-y-5">
          <section className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <StatCard
              label="completed jobs"
              value={completedMetric.toLocaleString()}
              sublabel={`${jobs7d.toLocaleString()} created in last 7d`}
              color="text-green-300"
            />
            <StatCard
              label="active jobs"
              value={activeMetric.toLocaleString()}
              sublabel={`${trendText} ${formatPercent(Math.abs(trend.pct))} over session`}
              color="text-neon-cyan"
            />
            <StatCard
              label="completion rate"
              value={formatPercent(completionRatePct)}
              sublabel={`${statusCounts.completed} of ${totalJobs} jobs`}
              color="text-gray-100"
            />
            <StatCard
              label="claim coverage"
              value={formatPercent(claimCoveragePct)}
              sublabel={medianClaimAgeHours === null ? 'median claim age n/a' : `median claim age ${medianClaimAgeHours.toFixed(1)}h`}
              color="text-yellow-300"
            />
            <StatCard
              label="dispute rate"
              value={formatPercent(disputeRatePct)}
              sublabel={`${statusCounts.disputed} disputed jobs`}
              color="text-yellow-300"
            />
            <StatCard
              label="operator fee"
              value={feePct}
              sublabel={stats ? 'bridge /stats' : 'bridge stats unavailable'}
              color="text-gray-200"
            />
            <StatCard
              label="total volume"
              value={formatNight(totalVolumeSpecks)}
              sublabel={averageBountySpecks === null ? 'avg bounty n/a' : `avg ${formatNight(averageBountySpecks)}`}
              color="text-neon-cyan"
            />
            <StatCard
              label="mode"
              value={stats || health ? (isStub ? 'stub' : 'on-chain') : 'unknown'}
              sublabel={health?.network ? `network ${health.network}` : 'network unknown'}
              color="text-gray-100"
            />
          </section>

          <section className="grid gap-4 lg:grid-cols-12">
            <div className="card card-elevated lg:col-span-8">
              <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                <h2 className="text-sm font-semibold text-gray-200">Active jobs trend</h2>
                <span className={`rounded-full border px-2 py-1 text-[11px] font-semibold uppercase tracking-wider ${trendClass}`}>
                  {trendText} {trend.delta === 0 ? '0' : `${trend.delta > 0 ? '+' : ''}${trend.delta}`}
                </span>
              </div>
              <PulseAreaChart values={sparkline} />
              <div className="mt-3">
                <SampleStrip values={sparkline} />
                <p className="mt-2 text-xs text-gray-500">Session window: last {sparkline.length} samples at 30s cadence.</p>
              </div>
            </div>

            <aside className="card lg:col-span-4">
              <h2 className="text-sm font-semibold text-gray-200">Pipeline mix</h2>
              <div className="mt-3 space-y-2">
                {statusMix.map((segment) => (
                  <MixRow
                    key={segment.label}
                    label={segment.label}
                    value={segment.value}
                    total={Math.max(totalJobs, 1)}
                    color={segment.color}
                  />
                ))}
              </div>
              <div className="mt-4 border-t border-void-600 pt-3">
                <Row label="network" value={health?.network ?? 'unknown'} />
                <Row label="active jobs (mip)" value={availability ? String(availability.active_jobs) : String(derivedActive)} />
                <Row label="contract" value={health?.contractAddress ?? 'not available'} mono />
                <Row label="last refresh" value={lastUpdated} />
              </div>
            </aside>
          </section>

          <section className="grid gap-4 lg:grid-cols-[1.1fr_0.9fr]">
            <article className="card">
              <h2 className="mb-2 text-sm font-semibold text-gray-200">Top completed agents</h2>
              {topAgents.length === 0 ? (
                <p className="text-xs text-gray-500">No completed jobs with assigned agent ids yet.</p>
              ) : (
                <div className="space-y-2">
                  {topAgents.map(([agent, count]) => (
                    <div key={agent} className="rounded-lg border border-void-600 bg-void-900/70 px-3 py-2">
                      <div className="mb-1 flex items-center justify-between gap-3">
                        <Link to={`/agents/${encodeURIComponent(agent)}`} className="truncate text-xs text-gray-300 hover:text-neon-cyan">
                          <code>{agent}</code>
                        </Link>
                        <span className="text-xs font-semibold text-neon-cyan">{count}</span>
                      </div>
                      <div className="h-1.5 rounded bg-void-700">
                        <div
                          className="h-full rounded bg-neon-cyan"
                          style={{ width: `${Math.max(8, (count / Math.max(topAgentMaxCount, 1)) * 100)}%` }}
                        />
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </article>

            <article className="card">
              <h2 className="mb-2 text-sm font-semibold text-gray-200">Recent public jobs</h2>
              {recentBounties.length === 0 ? (
                <p className="text-xs text-gray-500">No public jobs available yet.</p>
              ) : (
                <div className="space-y-2">
                  {recentBounties.map((job) => (
                    <div key={job.id} className="rounded-lg border border-void-600 bg-void-900/70 px-3 py-2">
                      <div className="flex items-center justify-between gap-2">
                        <Link to={`/job/${encodeURIComponent(job.id)}`} className="truncate text-xs text-gray-300 hover:text-neon-cyan">
                          {job.title}
                        </Link>
                        <StatusBadge status={job.status} />
                      </div>
                      <div className="mt-1 flex items-center justify-between gap-2 text-[11px] text-gray-500">
                        <span className="font-mono">{job.id.slice(0, 8)}</span>
                        <span>{timeAgo(job.createdAt)}</span>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </article>
          </section>
        </div>
      )}
    </div>
  );
}

function StatCard({
  label,
  value,
  sublabel,
  color,
}: {
  label: string;
  value: string;
  sublabel: string;
  color: string;
}) {
  return (
    <div className="card border-void-600/80 bg-void-900/70 py-4">
      <p className="text-[11px] uppercase tracking-[0.14em] text-gray-500">{label}</p>
      <p className={`mt-2 text-2xl font-bold sm:text-3xl ${color}`}>{value}</p>
      <p className="mt-1 text-xs text-gray-500">{sublabel}</p>
    </div>
  );
}

function SourceBadge({ label, live }: { label: string; live: boolean }) {
  return (
    <span
      className={`inline-flex items-center gap-2 rounded-full border px-2.5 py-1 text-[11px] font-semibold uppercase tracking-wider ${
        live ? 'border-neon-cyan/45 bg-neon-cyan/10 text-neon-cyan' : 'border-void-600 bg-void-800/80 text-gray-400'
      }`}
    >
      <span className={`inline-block h-1.5 w-1.5 rounded-full ${live ? 'bg-neon-cyan shadow-neon-dot' : 'bg-gray-500'}`} />
      {label}
    </span>
  );
}

function MixRow({
  label,
  value,
  total,
  color,
}: {
  label: string;
  value: number;
  total: number;
  color: string;
}) {
  const pct = total <= 0 ? 0 : (value / total) * 100;
  return (
    <div className="rounded-lg border border-void-600 bg-void-900/70 p-2.5">
      <div className="mb-1 flex items-center justify-between text-xs">
        <span className="uppercase tracking-wider text-gray-500">{label}</span>
        <span className="font-semibold text-gray-200">
          {value} <span className="text-gray-500">({formatPercent(pct)})</span>
        </span>
      </div>
      <div className="h-1.5 rounded bg-void-700">
        <div className={`h-full rounded ${color}`} style={{ width: `${Math.max(2, pct)}%` }} />
      </div>
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

function StatusBadge({ status }: { status: BountyStatus }) {
  const classes =
    status === 'completed'
      ? 'border-green-700/40 bg-green-950/40 text-green-300'
      : status === 'funded'
        ? 'border-indigo-700/40 bg-indigo-950/40 text-indigo-300'
        : status === 'disputed'
          ? 'border-yellow-700/40 bg-yellow-950/40 text-yellow-300'
          : 'border-neon-cyan/30 bg-neon-cyan/10 text-neon-cyan';
  return <span className={`rounded-full border px-2 py-0.5 text-[10px] uppercase tracking-wider ${classes}`}>{status}</span>;
}

function PulseAreaChart({ values }: { values: number[] }) {
  const width = 640;
  const height = 180;
  const padding = 14;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;

  const points = values.map((value, index) => {
    const x = padding + (index / Math.max(1, values.length - 1)) * (width - padding * 2);
    const y = height - padding - ((value - min) / range) * (height - padding * 2);
    return { x, y };
  });

  const linePath = points.map((point) => `${point.x},${point.y}`).join(' ');
  const areaPath = `${linePath} ${width - padding},${height - padding} ${padding},${height - padding}`;
  const latestPoint = points[points.length - 1];

  return (
    <svg viewBox={`0 0 ${width} ${height}`} className="h-44 w-full rounded-lg border border-void-600 bg-void-900/85">
      <defs>
        <linearGradient id="stats-pulse-gradient" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="rgba(94,242,255,0.36)" />
          <stop offset="100%" stopColor="rgba(94,242,255,0.02)" />
        </linearGradient>
      </defs>
      {[0.25, 0.5, 0.75].map((ratio) => {
        const y = padding + ratio * (height - padding * 2);
        return <line key={ratio} x1={padding} x2={width - padding} y1={y} y2={y} stroke="rgba(255,255,255,0.07)" strokeWidth="1" />;
      })}
      <polyline fill="url(#stats-pulse-gradient)" points={areaPath} />
      <polyline fill="none" stroke="rgba(255,79,216,0.35)" strokeWidth="6" points={linePath} />
      <polyline fill="none" stroke="rgba(94,242,255,0.95)" strokeWidth="2.5" points={linePath} />
      <circle cx={latestPoint.x} cy={latestPoint.y} r="4" fill="rgba(94,242,255,1)" />
    </svg>
  );
}

function SampleStrip({ values }: { values: number[] }) {
  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;

  return (
    <div className="flex h-10 items-end gap-1">
      {values.map((value, index) => {
        const pct = Math.max(8, ((value - min) / range) * 100);
        return (
          <div key={`${value}-${index}`} className="relative h-full flex-1 overflow-hidden rounded-sm bg-void-700/80" title={String(value)}>
            <span
              className="absolute inset-x-0 bottom-0 rounded-sm bg-neon-cyan/70 transition-all"
              style={{ height: `${pct}%`, animationDelay: `${index * 45}ms` }}
            />
          </div>
        );
      })}
    </div>
  );
}

function timestampFromIso(iso: string | null): number {
  if (!iso) return 0;
  const parsed = new Date(iso).getTime();
  return Number.isNaN(parsed) ? 0 : parsed;
}

function formatPercent(value: number | null): string {
  if (value === null || Number.isNaN(value)) return 'n/a';
  return `${value.toFixed(1)}%`;
}
