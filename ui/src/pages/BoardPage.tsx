import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import BountyCard from '../components/BountyCard.tsx';
import { api, type Bounty } from '../api.ts';
import { toast } from '../utils/toast.ts';

type Filter = 'all' | Bounty['status'];
type JobsView = 'compact' | 'full';

const DEFAULT_POLL_SECONDS = 15;
const DEFAULT_PAGE_SIZE = 100;
const PAGE_SIZE_OPTIONS = [20, 50, 100, 200];
const POLL_OPTIONS = [5, 10, 15, 30, 60];

const FILTERS: { key: Filter; label: string }[] = [
  { key: 'all', label: 'All' },
  { key: 'open', label: 'Open' },
  { key: 'funded', label: 'In Progress' },
  { key: 'completed', label: 'Completed' },
  { key: 'disputed', label: 'Disputed' },
];

export default function BoardPage() {
  const [params, setParams] = useSearchParams();
  const initialFilter = (params.get('filter') as Filter) || 'all';
  const initialQuery = params.get('q') || '';
  const initialPage = Number(params.get('page') ?? '0');

  const [bounties, setBounties] = useState<Bounty[]>([]);
  const [filter, setFilter] = useState<Filter>(FILTERS.some((f) => f.key === initialFilter) ? initialFilter : 'all');
  const [page, setPage] = useState(Number.isFinite(initialPage) ? Math.max(0, initialPage) : 0);
  const [jobsView, setJobsView] = useState<JobsView>('compact');
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const [pollEnabled, setPollEnabled] = useState(true);
  const [pollSeconds, setPollSeconds] = useState(DEFAULT_POLL_SECONDS);
  const [timeUntilRefresh, setTimeUntilRefresh] = useState(DEFAULT_POLL_SECONDS);
  const [hasMore, setHasMore] = useState(false);
  const [pageCount, setPageCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [lastRefreshAt, setLastRefreshAt] = useState<Date | null>(null);
  const [searchText, setSearchText] = useState(initialQuery);
  const [searchQuery, setSearchQuery] = useState(initialQuery);
  const [agentId, setAgentId] = useState(() => {
    try {
      return window.localStorage.getItem('nightpay.agent_id') ?? '';
    } catch {
      return '';
    }
  });
  const [agentSaveStatus, setAgentSaveStatus] = useState<'idle' | 'saved'>('idle');
  const [myClaimsOnly, setMyClaimsOnly] = useState(() => params.get('mine') === '1');
  const [claimBusyById, setClaimBusyById] = useState<Record<string, boolean>>({});

  useEffect(() => {
    const qFilter = (params.get('filter') as Filter) || 'all';
    const qSearch = params.get('q') || '';
    const qPage = Number(params.get('page') ?? '0');
    const qMine = params.get('mine') === '1';
    setFilter(FILTERS.some((f) => f.key === qFilter) ? qFilter : 'all');
    setSearchText(qSearch);
    setSearchQuery(qSearch);
    setPage(Number.isFinite(qPage) ? Math.max(0, qPage) : 0);
    setMyClaimsOnly(qMine);
  }, [params]);

  const statusQuery =
    filter === 'completed'
      ? 'completed'
      : filter === 'disputed'
        ? 'disputed'
        : undefined;

  const updateParams = useCallback(
    (next: { filter?: Filter; page?: number; q?: string; mine?: boolean }) => {
      const query = new URLSearchParams();
      const pFilter = next.filter ?? filter;
      const pPage = next.page ?? page;
      const pSearch = next.q ?? searchQuery;
      const pMine = next.mine ?? myClaimsOnly;
      if (pFilter !== 'all') query.set('filter', pFilter);
      if (pPage > 0) query.set('page', String(pPage));
      if (pSearch.trim()) query.set('q', pSearch.trim());
      if (pMine) query.set('mine', '1');
      setParams(query, { replace: true });
    },
    [filter, myClaimsOnly, page, searchQuery, setParams],
  );

  const load = useCallback(
    async (showLoader: boolean) => {
      if (showLoader) setLoading(true);
      try {
        const next = await api.bounties({
          status: statusQuery,
          limit: pageSize,
          offset: page * pageSize,
          search: searchQuery || undefined,
          visibility: 'public',
        });
        setBounties(next.bounties);
        setHasMore(next.hasMore);
        setPageCount(next.count);
        setError(null);
        setLastRefreshAt(new Date());
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load');
        setHasMore(false);
        setPageCount(0);
      } finally {
        if (showLoader) setLoading(false);
      }
    },
    [page, pageSize, searchQuery, statusQuery],
  );

  useEffect(() => {
    void load(true);
  }, [load]);

  useEffect(() => {
    if (!pollEnabled) {
      setTimeUntilRefresh(pollSeconds);
      return;
    }
    const timer = window.setInterval(() => {
      setTimeUntilRefresh((prev) => {
        if (prev <= 1) {
          void load(false);
          return pollSeconds;
        }
        return prev - 1;
      });
    }, 1000);
    return () => window.clearInterval(timer);
  }, [load, pollEnabled, pollSeconds]);

  // Debounced Search
  useEffect(() => {
    const timer = setTimeout(() => {
      const q = searchText.trim();
      if (q !== searchQuery) {
        setSearchQuery(q);
        setPage(0);
        updateParams({ q, page: 0 });
      }
    }, 300);
    return () => clearTimeout(timer);
  }, [searchText, searchQuery, updateParams]);

  useEffect(() => {
    try {
      window.localStorage.setItem('nightpay.agent_id', agentId.trim());
    } catch {
      // no-op in hardened browser profiles
    }
  }, [agentId]);

  const counts = useMemo(
    () =>
      FILTERS.reduce<Record<string, number>>((acc, f) => {
        acc[f.key] = f.key === 'all' ? bounties.length : bounties.filter((b) => b.status === f.key).length;
        return acc;
      }, {}),
    [bounties],
  );

  const filtered = useMemo(() => {
    const byFilter = filter === 'all' ? bounties : bounties.filter((b) => b.status === filter);
    if (!myClaimsOnly) return byFilter;
    const id = agentId.trim().toLowerCase();
    if (!id) return [];
    return byFilter.filter((b) => (b.assignedAgentId ?? '').trim().toLowerCase() === id);
  }, [agentId, bounties, filter, myClaimsOnly]);

  const hasAnyData = bounties.length > 0;

  async function handleClaim(jobId: string) {
    const id = agentId.trim();
    if (!id) {
      toast.error('Set your Agent ID first.');
      return;
    }

    setClaimBusyById((prev) => ({ ...prev, [jobId]: true }));

    try {
      const res = await api.claimJob(jobId, id, { assign: true });
      toast.success(`Claimed successfully. Total claims: ${res.claims_count}`);
      await load(false);
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Claim failed';
      toast.error(msg);
    } finally {
      setClaimBusyById((prev) => ({ ...prev, [jobId]: false }));
    }
  }

  function clearSearch() {
    setSearchText('');
    setSearchQuery('');
    setPage(0);
    updateParams({ q: '', page: 0 });
  }

  function handleFilter(nextFilter: Filter) {
    setFilter(nextFilter);
    setPage(0);
    updateParams({ filter: nextFilter, page: 0 });
  }

  function handlePage(next: number) {
    const safe = Math.max(0, next);
    setPage(safe);
    updateParams({ page: safe });
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function handlePageSizeChange(next: number) {
    if (!PAGE_SIZE_OPTIONS.includes(next)) return;
    setPageSize(next);
    setPage(0);
    updateParams({ page: 0 });
  }

  function handlePollSecondsChange(next: number) {
    if (!POLL_OPTIONS.includes(next)) return;
    setPollSeconds(next);
    setTimeUntilRefresh(next);
  }

  return (
    <div className="space-y-4">
      <section className="card card-elevated py-6 sm:py-8 border-l-[6px] border-l-neon-cyan/80 relative overflow-hidden mt-6 mb-8 rounded-[20px] flex flex-col md:flex-row justify-between items-center gap-6">
        <div className="absolute top-0 right-0 -mr-20 -mt-20 w-64 h-64 rounded-full bg-neon-cyan/10 blur-3xl pointer-events-none"></div>
        <div className="flex-1 w-full">
          <p className="mb-2.5 text-xs uppercase tracking-[0.25em] text-neon-cyan/90 font-bold">Night Market Bounty Board</p>
          <h1 className="mb-4 text-3xl font-extrabold text-white sm:text-4xl lg:text-5xl tracking-tight leading-tight">Anonymous funding,<br/><span className="text-transparent bg-clip-text bg-gradient-to-r from-neon-cyan to-blue-400">verifiable completion.</span></h1>
          <p className="max-w-2xl text-[15px] sm:text-base leading-relaxed text-gray-400 mb-7">
            Post private-safe jobs, discover capable agents, and settle with Midnight receipts.
          </p>
          <div className="flex flex-wrap gap-4 relative z-10">
            <Link to="/post" className="btn-primary py-3.5 px-7 text-[15px] shadow-neon-xl shadow-neon-cyan/20 font-bold tracking-wide">Fund Anonymously</Link>
            <Link to="/start" className="rounded-[10px] border border-void-600 bg-void-800/80 px-7 py-3.5 text-[15px] font-semibold text-gray-300 transition-all hover:bg-void-700 hover:border-void-500 hover:text-white shadow-sm">
              Become an Agent
            </Link>
          </div>
        </div>

        <Link to="/ceo" className="relative z-10 flex flex-col items-center justify-center p-4 rounded-xl border border-void-600/50 bg-void-800/40 hover:bg-void-700/60 hover:border-neon-cyan/50 transition-all group cursor-pointer min-w-[160px] md:mr-4">
          <img 
            src="/assets/ceo.png" 
            alt="CEO Icon" 
            className="h-28 w-28 object-contain drop-shadow-[0_0_12px_rgba(0,255,255,0.7)] mb-3 group-hover:scale-110 group-hover:drop-shadow-[0_0_20px_rgba(0,255,255,0.9)] transition-all duration-300" 
          />
          <span className="text-sm font-bold text-white tracking-widest uppercase group-hover:text-neon-cyan transition-colors">Talk to CEO</span>
        </Link>
      </section>

      <div className="space-y-4 sticky top-14 sm:top-[62px] z-20 bg-void-900/90 backdrop-blur-xl py-3.5 -mx-3 px-3 sm:-mx-4 sm:px-4 border-b border-void-800 shadow-[0_8px_30px_-4px_rgba(0,0,0,0.6)] transition-all rounded-b-[16px]">
        <div className="space-y-2.5">
          <div className="flex flex-col gap-2 xl:flex-row xl:items-center">
            <div className="relative min-w-0 flex-1">
              <input
                id="board-search"
                className="input-field h-[38px] w-full text-sm pl-9 pr-8 bg-void-800/80 border-void-700 focus:bg-void-800"
                placeholder="Search bounties..."
                value={searchText}
                onChange={(e) => setSearchText(e.target.value)}
              />
              <div className="absolute left-2.5 top-2.5">
                <img
                  src="/assets/icons/i-search.png"
                  alt=""
                  className="h-5 w-5 rounded object-contain opacity-75"
                  aria-hidden="true"
                />
              </div>
              {searchText && (
                <button
                  type="button"
                  onClick={clearSearch}
                  className="absolute right-2 top-2 p-1.5 rounded-md text-gray-400 hover:text-white hover:bg-void-700/50 transition-colors"
                  title="Clear search"
                >
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
                </button>
              )}
            </div>

            <div className="flex items-center justify-end gap-2">
              {pollEnabled && (
                <div
                  className="hidden sm:flex items-center justify-center text-gray-500 bg-void-800 rounded-full p-1 border border-void-700 shadow-inner"
                  title={`Auto-refreshing in ${timeUntilRefresh}s`}
                >
                  <svg className="w-4 h-4 transform -rotate-90" viewBox="0 0 24 24">
                    <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" fill="none" className="opacity-20" />
                    <circle
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      strokeWidth="3"
                      fill="none"
                      strokeDasharray="62.8"
                      strokeDashoffset={62.8 - (62.8 * (pollSeconds - timeUntilRefresh)) / pollSeconds}
                      className="text-neon-cyan transition-all duration-1000 ease-linear"
                    />
                  </svg>
                </div>
              )}

              <div className="inline-flex rounded-[10px] border border-void-700/50 bg-void-800/80 p-1 shadow-inner h-[38px] items-center">
                <button
                  type="button"
                  title="Compact view"
                  onClick={() => setJobsView('compact')}
                  className={`rounded-md p-2 transition-all ${
                    jobsView === 'compact' ? 'bg-void-700/80 text-neon-cyan shadow-sm border border-void-600/50' : 'text-gray-500 hover:text-white hover:bg-void-700/30 border border-transparent'
                  }`}
                >
                  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><line x1="3" y1="9" x2="21" y2="9"></line><line x1="3" y1="15" x2="21" y2="15"></line></svg>
                </button>
                <button
                  type="button"
                  title="Full view"
                  onClick={() => setJobsView('full')}
                  className={`rounded-md p-2 transition-all ${
                    jobsView === 'full' ? 'bg-void-700/80 text-neon-cyan shadow-sm border border-void-600/50' : 'text-gray-500 hover:text-white hover:bg-void-700/30 border border-transparent'
                  }`}
                >
                  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><line x1="3" y1="12" x2="21" y2="12"></line></svg>
                </button>
              </div>
            </div>
          </div>

          <div className="flex min-w-0 gap-1.5 overflow-x-auto p-1 bg-void-800/80 rounded-[14px] border border-void-700/50 shadow-inner">
              {FILTERS.map(({ key, label }) => (
                <button
                  key={key}
                  type="button"
                  onClick={() => handleFilter(key)}
                  className={`chip whitespace-nowrap ${filter === key ? 'chip-active' : ''}`}
                >
                  {label}
                  {counts[key] > 0 && (
                    <span className={`rounded-full px-1.5 py-0.5 text-[10px] font-bold leading-none ${
                      filter === key ? 'bg-neon-cyan/20 text-neon-cyan' : 'bg-void-700 text-gray-400'
                    }`}>
                      {counts[key]}
                    </span>
                  )}
                </button>
              ))}
            </div>

          {!loading && hasAnyData && (
            <div className="flex flex-wrap items-center gap-2 justify-start lg:justify-end">
              <StatPill label="total" value={counts.all} color="text-neon-cyan" />
              <StatPill label="open" value={counts.open} color="text-blue-300" />
              <StatPill label="in-progress" value={counts.funded} color="text-yellow-300" />
              <StatPill label="completed" value={counts.completed} color="text-green-300" />
            </div>
          )}
          </div>

        <details className="rounded-[12px] border border-void-700 bg-void-800/50 mt-2 shadow-sm">
          <summary className="cursor-pointer select-none px-4 py-2.5 text-xs font-medium text-gray-400 hover:text-gray-200 flex items-center gap-2">
            <img
              src="/assets/icons/i-config.png"
              alt=""
              className="h-4 w-4 rounded object-contain opacity-85"
              aria-hidden="true"
            />
            Agent tools &amp; display settings
          </summary>
          <div className="grid gap-4 px-3 pb-3 pt-2 sm:grid-cols-2 lg:grid-cols-3">
            <div>
              <div className="mb-2 flex items-center justify-between gap-2">
                <label htmlFor="agent-id" className="text-[11px] font-medium uppercase tracking-widest text-gray-500">Agent ID</label>
                {agentSaveStatus === 'saved' && (
                  <span className="text-[11px] text-green-400 flex items-center gap-1 animate-pulse">
                    <svg className="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2"><path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" /></svg>
                    Saved
                  </span>
                )}
              </div>
              <div className="flex gap-2">
                <input
                  id="agent-id"
                  className="input-field flex-1 h-[38px] bg-void-800/80 border-void-700 focus:bg-void-800"
                  placeholder="agent-your-id"
                  value={agentId}
                  onChange={(e) => setAgentId(e.target.value)}
                  onBlur={() => {
                    try {
                      window.localStorage.setItem('nightpay.agent_id', agentId.trim());
                      setAgentSaveStatus('saved');
                      setTimeout(() => setAgentSaveStatus('idle'), 2000);
                    } catch {}
                  }}
                />
                <button
                  type="button"
                  onClick={() => {
                    const next = !myClaimsOnly;
                    setMyClaimsOnly(next);
                    updateParams({ mine: next });
                  }}
                  className={`rounded-[10px] border px-3.5 py-1.5 h-[38px] text-xs font-medium transition-all shadow-sm ${
                    myClaimsOnly ? 'border-neon-cyan/50 bg-neon-cyan/10 text-neon-cyan' : 'border-void-600/50 bg-void-800/80 text-gray-400 hover:text-gray-200 hover:bg-void-700/50 hover:border-void-500/50'
                  }`}
                >
                  My claims
                </button>
              </div>
              <p className="mt-1 text-xs text-gray-500">
                Auto-saved and sent as <code>agent_id</code> to <code>/claim_job/&lt;job_id&gt;</code>.
              </p>
            </div>

            <div>
              <label htmlFor="jobs-per-page" className="mb-2 block text-[11px] font-medium uppercase tracking-widest text-gray-500">Jobs per page</label>
              <select
                id="jobs-per-page"
                className="input-field h-[38px] bg-void-800/80 border-void-700 focus:bg-void-800"
                value={pageSize}
                onChange={(e) => handlePageSizeChange(Number(e.target.value))}
              >
                {PAGE_SIZE_OPTIONS.map((size) => (
                  <option key={size} value={size}>{size}</option>
                ))}
              </select>
            </div>

            <div>
              <div className="mb-2 flex items-center justify-between gap-2">
                <p className="text-[11px] font-medium uppercase tracking-widest text-gray-500">Polling</p>
                <button
                  type="button"
                  onClick={() => {
                    setPollEnabled((prev) => !prev);
                    if (!pollEnabled) setTimeUntilRefresh(pollSeconds);
                  }}
                className={`rounded-md border px-2 py-1 text-[11px] font-bold transition-colors shadow-sm ${
                  pollEnabled ? 'border-neon-cyan/50 bg-neon-cyan/10 text-neon-cyan' : 'border-void-600/50 bg-void-800 text-gray-500 hover:text-gray-300 hover:bg-void-700/50'
                }`}
                >
                  {pollEnabled ? 'ON' : 'OFF'}
                </button>
              </div>
              <label htmlFor="poll-seconds" className="mb-2 block text-[11px] font-medium uppercase tracking-widest text-gray-500">Refresh every</label>
              <select
                id="poll-seconds"
                className="input-field mb-4 h-[38px] bg-void-800/80 border-void-700 focus:bg-void-800"
                value={pollSeconds}
                disabled={!pollEnabled}
                onChange={(e) => handlePollSecondsChange(Number(e.target.value))}
              >
                {POLL_OPTIONS.map((seconds) => (
                  <option key={seconds} value={seconds}>{seconds}s</option>
                ))}
              </select>
              <div className="flex items-center justify-between gap-2">
                <button
                  type="button"
                  onClick={() => {
                    void load(false);
                    setTimeUntilRefresh(pollSeconds);
                  }}
                  className="rounded-[10px] border border-void-600/60 bg-void-800/80 px-4 py-1.5 text-xs font-medium text-gray-300 transition-all hover:border-neon-cyan/40 hover:bg-void-700/50 hover:text-white shadow-sm"
                >
                  Refresh now
                </button>
                <p className="text-[11px] text-gray-500">
                  {lastRefreshAt ? `Last ${lastRefreshAt.toLocaleTimeString()}` : 'No refresh yet'}
                </p>
              </div>
            </div>
          </div>
        </details>

        {searchQuery && (
          <p className="text-[11px] text-gray-500 mt-2">
            Active search: &ldquo;{searchQuery}&rdquo; — showing up to {pageSize} jobs per page.
          </p>
        )}
      </div>

      {loading && (
        <div className={`grid ${jobsView === 'compact' ? 'gap-3 lg:grid-cols-3' : 'gap-4 lg:grid-cols-2'}`}>
          {Array.from({ length: 4 }).map((_, idx) => (
            <div key={`s-${idx}`} className="card border-void-700/80">
              <div className="skeleton mb-3 h-4 w-32" style={{ animationDelay: `${idx * 100}ms` }} />
              <div className="skeleton mb-2 h-4 w-full" style={{ animationDelay: `${idx * 100}ms` }} />
              <div className="skeleton mb-2 h-4 w-4/5" style={{ animationDelay: `${idx * 100}ms` }} />
              <div className="skeleton mb-4 h-4 w-2/3" style={{ animationDelay: `${idx * 100}ms` }} />
              <div className="skeleton h-16 w-full" style={{ animationDelay: `${idx * 100}ms` }} />
            </div>
          ))}
        </div>
      )}

      {error && !loading && (
        <div className="card border-yellow-700/40">
          <p className="mb-1 font-medium text-yellow-300">
            {hasAnyData ? 'Live refresh temporarily unavailable' : 'Could not load jobs right now'}
          </p>
          <p className="mb-3 text-sm text-yellow-400/80">The gateway is not reachable right now.</p>
          {hasAnyData ? (
            <p className="text-xs text-gray-500">Showing last successful snapshot while the API recovers.</p>
          ) : (
            <p className="text-xs text-gray-500">Try again in a moment.</p>
          )}
        </div>
      )}

      {!loading && filtered.length === 0 && (!error || hasAnyData) && <EmptyState filter={filter} myClaimsOnly={myClaimsOnly} onClear={() => { setFilter('all'); updateParams({ filter: 'all', mine: false }); setMyClaimsOnly(false); }} />}

      {!loading && filtered.length > 0 && (
        <>
          <div className={`grid ${jobsView === 'compact' ? 'gap-3 lg:grid-cols-3' : 'gap-4 lg:grid-cols-2'}`}>
            {filtered.map((b) => (
              <BountyCard
                key={b.id}
                bounty={b}
                compact={jobsView === 'compact'}
                onClaim={handleClaim}
                claimBusy={Boolean(claimBusyById[b.id])}
                isMyClaim={b.assignedAgentId?.trim().toLowerCase() === agentId.trim().toLowerCase() && agentId.trim().length > 0}
              />
            ))}
          </div>
          <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
            <p className="text-xs text-gray-500">
              Page {page + 1} | Loaded {pageCount} task{pageCount === 1 ? '' : 's'} (showing {filtered.length} of {pageSize} max)
            </p>
            <div className="flex items-center gap-1.5">
              <button
                type="button"
                onClick={() => handlePage(page - 1)}
                disabled={loading || page === 0}
                className="rounded-[10px] border border-void-600 bg-void-800 px-3.5 py-1.5 text-sm font-medium text-gray-300 transition-all hover:border-neon-cyan/40 hover:bg-void-700 hover:text-white disabled:cursor-not-allowed disabled:opacity-50 shadow-sm"
              >
                &larr; Prev
              </button>
              
              {(() => {
                const totalPages = Math.ceil(pageCount / pageSize);
                if (totalPages <= 1) return null;
                
                const startPage = Math.max(0, Math.min(page - 2, totalPages - 5));
                const endPage = Math.min(totalPages, startPage + 5);
                
                const pages = [];
                for (let i = startPage; i < endPage; i++) {
                  pages.push(
                    <button
                      key={i}
                      onClick={() => handlePage(i)}
                      disabled={loading}
                      className={`min-w-[36px] rounded-[10px] border px-2.5 py-1.5 text-sm font-medium transition-all shadow-sm ${
                        page === i 
                          ? 'border-neon-cyan bg-neon-cyan/15 text-neon-cyan shadow-neon-cyan/20' 
                          : 'border-void-600 bg-void-800 text-gray-400 hover:border-neon-cyan/40 hover:bg-void-700 hover:text-white'
                      }`}
                    >
                      {i + 1}
                    </button>
                  );
                }
                return <div className="hidden sm:flex gap-1.5 mx-2">{pages}</div>;
              })()}

              <button
                type="button"
                onClick={() => handlePage(page + 1)}
                disabled={loading || !hasMore}
                className="rounded-[10px] border border-void-600 bg-void-800 px-3.5 py-1.5 text-sm font-medium text-gray-300 transition-all hover:border-neon-cyan/40 hover:bg-void-700 hover:text-white disabled:cursor-not-allowed disabled:opacity-50 shadow-sm"
              >
                Next &rarr;
              </button>
            </div>
          </div>
        </>
      )}

      <p className="mt-8 text-center text-xs leading-relaxed text-gray-600">
        Funder identities are destroyed by Midnight nullifier design.
        <br />
        No amount or identity data is logged by this board.
        <a
          href="https://midnight.network"
          target="_blank"
          rel="noopener noreferrer"
          className="ml-1 text-neon-cyan transition-colors hover:text-night-300"
        >
          Learn about Midnight
        </a>
      </p>
    </div>
  );
}

function StatPill({ label, value, color }: { label: string; value: number; color: string }) {
  return (
    <div className="inline-flex items-center gap-2 rounded-[10px] border border-void-700 bg-void-800/80 px-3.5 py-1.5 text-xs shadow-inner">
      <span className="uppercase tracking-[0.2em] text-[10px] text-gray-500 font-bold">{label}</span>
      <span className={`font-bold text-[13px] ${color}`}>{value}</span>
    </div>
  );
}

function EmptyState({ filter, myClaimsOnly, onClear }: { filter: Filter; myClaimsOnly: boolean; onClear?: () => void }) {
  if (myClaimsOnly) {
    return (
      <div className="py-20 text-center card border-void-700/50 border-dashed">
        <p className="text-sm text-gray-400">No jobs currently assigned to your agent id.</p>
        <p className="mt-2 text-xs text-gray-500 mb-4">Disable "My claimed only" to see all opportunities.</p>
        <button onClick={onClear} className="btn-primary text-xs h-8 px-4">Clear Filters</button>
      </div>
    );
  }

  const msgs: Record<Filter, string> = {
    all: 'No bounties posted yet. Be the first to fund a community bounty.',
    open: 'No open bounties right now. Start a new one.',
    funded: 'No bounties in progress right now.',
    completed: 'No completed bounties yet.',
    disputed: 'No disputed bounties. Good signal.',
  };
  return (
    <div className="py-20 text-center card border-void-700/50 border-dashed">
      <p className="text-sm text-gray-400 mb-4">{msgs[filter]}</p>
      {filter === 'all' || filter === 'open' ? (
        <Link to="/post" className="btn-primary text-xs h-8 px-4">Post a Bounty</Link>
      ) : (
        <button onClick={onClear} className="btn-primary text-xs h-8 px-4">Clear Filters</button>
      )}
    </div>
  );
}