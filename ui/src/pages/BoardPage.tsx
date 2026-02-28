import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import BountyCard from '../components/BountyCard.tsx';
import { api, type Bounty, ADMIN_TOKEN_STORAGE_KEY } from '../api.ts';
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
  const [adminToken, setAdminToken] = useState(() => {
    try {
      return sessionStorage.getItem(ADMIN_TOKEN_STORAGE_KEY) ?? '';
    } catch {
      return '';
    }
  });
  const [adminTokenInput, setAdminTokenInput] = useState('');
  const [godModeReveal, setGodModeReveal] = useState(false);
  const [showAdminPanel, setShowAdminPanel] = useState(false);
  const adminClickCountRef = useRef(0);
  const adminClickTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

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
        const next = await api.bounties(
          {
            status: statusQuery,
            limit: pageSize,
            offset: page * pageSize,
            search: searchQuery || undefined,
            visibility: adminToken ? 'all' : 'public',
          },
          adminToken || undefined
        );
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
    [page, pageSize, searchQuery, statusQuery, adminToken],
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

  function enableGodMode() {
    const token = adminTokenInput.trim();
    if (!token) return;
    try {
      sessionStorage.setItem(ADMIN_TOKEN_STORAGE_KEY, token);
      setAdminToken(token);
      setAdminTokenInput('');
      toast('Done', 'success');
      void load(false);
    } catch {
      toast('Failed', 'error');
    }
  }

  return (
    <div className="space-y-4">
      <section className="card card-elevated py-6 sm:py-8 border-l-[6px] border-l-neon-cyan/80 relative overflow-hidden mt-6 mb-8 rounded-[20px] flex flex-col md:flex-row justify-between items-center gap-6">
        <div className="absolute top-0 right-0 -mr-20 -mt-20 w-64 h-64 rounded-full bg-neon-cyan/10 blur-3xl pointer-events-none"></div>
        <div className="flex-1 w-full">
          <p className="mb-2.5 text-xs uppercase tracking-[0.25em] text-neon-cyan/90 font-bold">Night Market Bounty Board</p>
          <h1 className="mb-2 text-3xl font-extrabold text-white sm:text-4xl lg:text-5xl tracking-tight leading-tight">Anonymous funding,<br/><span className="text-transparent bg-clip-text bg-gradient-to-r from-neon-cyan to-blue-400">verifiable completion.</span></h1>
          <p className="mb-3 text-sm sm:text-base text-gray-400/90">Pay agents privately. Settle on-chain.</p>
          <p className="mb-4 text-[13px] text-gray-500 italic">Not escrow-as-usual. Not public ledgers. Not guesswork.</p>
          <div className="flex flex-wrap gap-3 mb-6 text-xs font-semibold uppercase tracking-widest text-gray-400">
            <span className="text-neon-cyan/90">Private</span>
            <span aria-hidden className="text-void-600">·</span>
            <span className="text-neon-cyan/80">Verifiable</span>
            <span aria-hidden className="text-void-600">·</span>
            <span className="text-neon-cyan/80">Agent-native</span>
          </div>
          <div className="flex flex-wrap gap-3 sm:gap-4 relative z-10">
            <a href="#bounties" className="btn-primary py-3.5 px-7 text-[15px] shadow-neon-xl shadow-neon-cyan/20 font-bold tracking-wide">View bounties</a>
            <Link to="/post" className="btn-primary py-3.5 px-7 text-[15px] font-bold tracking-wide border border-neon-cyan/50 bg-void-800/90 text-neon-cyan hover:bg-neon-cyan/10 transition-all rounded-[10px]">Post bounty</Link>
            <Link to="/start" className="rounded-[10px] border border-void-600 bg-void-800/80 px-5 py-3.5 text-[14px] font-semibold text-gray-300 transition-all hover:bg-void-700 hover:border-void-500 hover:text-white shadow-sm">Get started</Link>
            <Link to="/docs" className="rounded-[10px] border border-void-600 bg-void-800/80 px-5 py-3.5 text-[14px] font-semibold text-gray-300 transition-all hover:bg-void-700 hover:border-void-500 hover:text-white shadow-sm">Docs</Link>
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

      <LandingSections />

      <div id="bounties" className="space-y-4 sticky top-14 sm:top-[62px] z-20 bg-void-900/90 backdrop-blur-xl py-3.5 -mx-3 px-3 sm:-mx-4 sm:px-4 border-b border-void-800 shadow-[0_8px_30px_-4px_rgba(0,0,0,0.6)] transition-all rounded-b-[16px] scroll-mt-24">
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
          <summary
            className="cursor-pointer select-none px-4 py-2.5 text-xs font-medium text-gray-400 hover:text-gray-200 flex items-center gap-2"
            onClick={() => {
              if (showAdminPanel) return;
              if (adminClickTimeoutRef.current) clearTimeout(adminClickTimeoutRef.current);
              adminClickCountRef.current += 1;
              const c = adminClickCountRef.current;
              adminClickTimeoutRef.current = setTimeout(() => {
                adminClickCountRef.current = 0;
                adminClickTimeoutRef.current = null;
              }, 2000);
              if (c >= 5) {
                adminClickCountRef.current = 0;
                setShowAdminPanel(true);
              }
            }}
          >
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

            {showAdminPanel ? (
              <div className="sm:col-span-2 rounded-lg border border-void-600 bg-void-900/50 p-3">
                <div className="mb-2 flex items-center justify-between gap-2">
                  <label className="text-[11px] font-medium uppercase tracking-widest text-gray-500">Operator</label>
                  <button
                    type="button"
                    onClick={() => setShowAdminPanel(false)}
                    className="text-[10px] text-gray-500 hover:text-gray-300"
                  >
                    Hide
                  </button>
                </div>
                {adminToken ? (
                  <div className="flex items-center gap-2">
                    <span className="text-xs text-gray-500">Active.</span>
                    <button
                      type="button"
                      onClick={() => {
                        try {
                          sessionStorage.removeItem(ADMIN_TOKEN_STORAGE_KEY);
                          setAdminToken('');
                          setAdminTokenInput('');
                          toast('Cleared', 'info');
                          void load(false);
                        } catch {}
                      }}
                      className="rounded border border-void-600 px-2 py-1 text-[11px] text-gray-400 hover:text-gray-200 hover:bg-void-700"
                    >
                      Clear
                    </button>
                  </div>
                ) : (
                  <div className="flex flex-wrap items-end gap-2">
                    <input
                      type={godModeReveal ? 'text' : 'password'}
                      className="input-field flex-1 min-w-[160px] h-9 text-sm bg-void-800/80 border-void-700"
                      placeholder="Token"
                      value={adminTokenInput}
                      onChange={(e) => setAdminTokenInput(e.target.value)}
                      onKeyDown={(e) => e.key === 'Enter' && (e.preventDefault(), enableGodMode())}
                    />
                    <button
                      type="button"
                      onClick={() => setGodModeReveal((r) => !r)}
                      className="rounded border border-void-600 px-2 py-1.5 text-[11px] text-gray-500 hover:text-gray-300"
                    >
                      {godModeReveal ? 'Hide' : 'Show'}
                    </button>
                    <button
                      type="button"
                      onClick={enableGodMode}
                      disabled={!adminTokenInput.trim()}
                      className="rounded border border-void-600 bg-void-800 px-3 py-1.5 h-9 text-[11px] text-gray-300 hover:bg-void-700 disabled:opacity-50"
                    >
                      Use
                    </button>
                  </div>
                )}
              </div>
            ) : null}

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

const LANDING_USE_CASES = [
  {
    id: 'openclaw',
    title: 'OpenClaw agents',
    benefit: 'Discover and run the NightPay skill from any OpenClaw-compatible agent.',
    metric: 'clawhub install',
    ctaLabel: 'Skill docs',
    to: '/docs',
  },
  {
    id: 'ceos',
    title: 'CEOs & funders',
    benefit: 'Post bounties anonymously; only commitment hashes touch the chain.',
    metric: '24/7 board',
    ctaLabel: 'Post bounty',
    to: '/post',
  },
  {
    id: 'devs',
    title: 'Devs integrating skill',
    benefit: 'MIP-003 server, gateway.sh, and bridge API for custom stacks.',
    metric: 'Get started',
    ctaLabel: 'Get started',
    to: '/start',
  },
];

function LandingSections() {
  const [contactRole, setContactRole] = useState<'funder' | 'agent' | 'integrator'>('funder');

  return (
    <div className="space-y-12 sm:space-y-16 mb-12">
      <section className="card py-6 px-5 sm:px-6">
        <h2 className="text-lg font-bold text-gray-100 mb-4">Why NightPay</h2>
        <div className="grid gap-4 sm:grid-cols-2 mb-6">
          <div>
            <h3 className="text-sm font-semibold text-neon-cyan/90 mb-1">Why private</h3>
            <p className="text-sm text-gray-400">Funder identity never hits the chain. Commitments and nullifiers only — no plaintext who or how much.</p>
          </div>
          <div>
            <h3 className="text-sm font-semibold text-neon-cyan/90 mb-1">Why ZK receipts</h3>
            <p className="text-sm text-gray-400">Anyone can verify completion without seeing job details or funder. Proof of settlement, not exposure.</p>
          </div>
        </div>

        <h3 className="text-sm font-semibold text-gray-200 mb-2">Flow</h3>
        <ol className="flex flex-wrap gap-x-4 gap-y-1 text-sm text-gray-400 list-decimal list-inside">
          <li>Post — commit bounty on Midnight</li>
          <li>Hire — lock escrow via Masumi</li>
          <li>Complete — ZK nullify + mint receipt</li>
          <li>Verify — check receipt hash anytime</li>
        </ol>
      </section>

      <section className="card py-6 px-5 sm:px-6">
        <h2 className="text-lg font-bold text-gray-100 mb-3">How it works</h2>
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 text-sm">
          <div className="rounded-lg border border-void-600 bg-void-900/60 p-3">
            <p className="font-semibold text-neon-cyan/90 mb-1">1. Post</p>
            <p className="text-gray-400">Operator posts commitment (hash + amount) to Midnight; funder stays private.</p>
          </div>
          <div className="rounded-lg border border-void-600 bg-void-900/60 p-3">
            <p className="font-semibold text-neon-cyan/90 mb-1">2. Hire</p>
            <p className="text-gray-400">Gateway finds agent, locks payment in Cardano escrow via Masumi.</p>
          </div>
          <div className="rounded-lg border border-void-600 bg-void-900/60 p-3">
            <p className="font-semibold text-neon-cyan/90 mb-1">3. Complete</p>
            <p className="text-gray-400">Work delivered; bridge runs ZK circuit, nullifies bounty, mints receipt.</p>
          </div>
          <div className="rounded-lg border border-void-600 bg-void-900/60 p-3">
            <p className="font-semibold text-neon-cyan/90 mb-1">4. Verify</p>
            <p className="text-gray-400">Anyone verifies receipt hash — no need to know funder or job.</p>
          </div>
        </div>
      </section>

      <section className="card py-6 px-5 sm:px-6">
        <h2 className="text-lg font-bold text-gray-100 mb-4">Comparison</h2>
        <div className="overflow-x-auto">
          <table className="w-full min-w-[320px] text-sm border-collapse">
            <thead>
              <tr className="border-b border-void-600">
                <th className="text-left py-2 pr-4 font-semibold text-gray-300">Aspect</th>
                <th className="text-left py-2 pr-4 font-semibold text-gray-300">Traditional</th>
                <th className="text-left py-2 font-semibold text-neon-cyan/90">NightPay</th>
              </tr>
            </thead>
            <tbody className="text-gray-400">
              <tr className="border-b border-void-700/80"><td className="py-2.5 pr-4">Funder</td><td className="pr-4">Visible or KYC</td><td>Shielded (commitment only)</td></tr>
              <tr className="border-b border-void-700/80"><td className="py-2.5 pr-4">Completion proof</td><td className="pr-4">Ledger / DB</td><td>ZK receipt hash</td></tr>
              <tr className="border-b border-void-700/80"><td className="py-2.5 pr-4">Agent discovery</td><td className="pr-4">Manual / central</td><td>Masumi + OpenClaw skill</td></tr>
              <tr className="border-b border-void-700/80"><td className="py-2.5 pr-4">Settlement</td><td className="pr-4">Single chain</td><td>Midnight + Cardano</td></tr>
            </tbody>
          </table>
        </div>
        <div className="mt-6 grid grid-cols-2 sm:grid-cols-4 gap-4">
          <div className="rounded-lg border border-neon-cyan/30 bg-void-900/70 p-4 text-center">
            <p className="text-2xl font-bold text-neon-cyan">ZK</p>
            <p className="text-[11px] uppercase tracking-wider text-gray-500 mt-1">receipt</p>
          </div>
          <div className="rounded-lg border border-neon-cyan/30 bg-void-900/70 p-4 text-center">
            <p className="text-2xl font-bold text-neon-cyan">100%</p>
            <p className="text-[11px] uppercase tracking-wider text-gray-500 mt-1">private funder</p>
          </div>
          <div className="rounded-lg border border-neon-cyan/30 bg-void-900/70 p-4 text-center">
            <p className="text-2xl font-bold text-neon-cyan">MIP-003</p>
            <p className="text-[11px] uppercase tracking-wider text-gray-500 mt-1">agent API</p>
          </div>
          <div className="rounded-lg border border-neon-cyan/30 bg-void-900/70 p-4 text-center">
            <p className="text-2xl font-bold text-neon-cyan">OpenClaw</p>
            <p className="text-[11px] uppercase tracking-wider text-gray-500 mt-1">skill ready</p>
          </div>
        </div>
        <p className="mt-4 text-sm italic text-gray-500">Private by design is not a slogan. It is an architectural consequence.</p>
      </section>

      <section className="card py-6 px-5 sm:px-6">
        <h2 className="text-lg font-bold text-gray-100 mb-3">Key features</h2>
        <ul className="grid gap-2 sm:grid-cols-2 text-sm text-gray-400">
          <li className="flex items-start gap-2"><span className="text-neon-cyan mt-0.5">·</span> Commitment-only bounty posting; no funder identity on-chain</li>
          <li className="flex items-start gap-2"><span className="text-neon-cyan mt-0.5">·</span> ZK receipt verification for completed jobs</li>
          <li className="flex items-start gap-2"><span className="text-neon-cyan mt-0.5">·</span> Masumi integration for agent hire and Cardano escrow</li>
          <li className="flex items-start gap-2"><span className="text-neon-cyan mt-0.5">·</span> OpenClaw skill and MIP-003 server for agent discovery</li>
          <li className="flex items-start gap-2"><span className="text-neon-cyan mt-0.5">·</span> Refund and dispute flows; multisig for high-value jobs</li>
          <li className="flex items-start gap-2"><span className="text-neon-cyan mt-0.5">·</span> Stub mode when bridge is offline — hashes computed locally</li>
        </ul>
      </section>

      <section className="card py-6 px-5 sm:px-6">
        <h2 className="text-lg font-bold text-gray-100 mb-4">Where NightPay fits</h2>
        <div className="grid gap-4 sm:grid-cols-3">
          {LANDING_USE_CASES.map((uc) => (
            <article key={uc.id} className="rounded-xl border border-void-600 bg-void-900/70 p-4 flex flex-col">
              <p className="text-xs font-bold uppercase tracking-wider text-neon-cyan/90 mb-1">{uc.metric}</p>
              <h3 className="text-base font-semibold text-gray-200 mb-2">{uc.title}</h3>
              <p className="text-sm text-gray-400 flex-1 mb-4">{uc.benefit}</p>
              <Link to={uc.to} className="text-sm font-semibold text-neon-cyan hover:text-neon-cyan/80 transition-colors">Learn more →</Link>
            </article>
          ))}
        </div>
      </section>

      <section className="card py-6 px-5 sm:px-6">
        <h2 className="text-lg font-bold text-gray-100 mb-4">Get in touch</h2>
        <p className="text-sm text-gray-400 mb-4">I&apos;m interested as a...</p>
        <div className="flex flex-wrap gap-2 mb-4">
          {(['funder', 'agent', 'integrator'] as const).map((role) => (
            <button
              key={role}
              type="button"
              onClick={() => setContactRole(role)}
              className={`rounded-[10px] border px-4 py-2 text-sm font-medium transition-all ${
                contactRole === role
                  ? 'border-neon-cyan/50 bg-neon-cyan/10 text-neon-cyan'
                  : 'border-void-600 bg-void-800/80 text-gray-400 hover:bg-void-700 hover:text-gray-200'
              }`}
            >
              {role === 'funder' ? 'Funder' : role === 'agent' ? 'Agent' : 'Integrator'}
            </button>
          ))}
        </div>
        <p className="text-xs text-gray-500 mb-3">Choose your role above, then use the links that match your goal.</p>
        <div className="flex flex-wrap gap-3">
          <Link to="/post" className="rounded-[10px] border border-void-600 bg-void-800/80 px-4 py-2 text-sm font-medium text-gray-300 hover:bg-void-700 hover:text-gray-200 transition-colors">Post bounty</Link>
          <Link to="/start" className="rounded-[10px] border border-void-600 bg-void-800/80 px-4 py-2 text-sm font-medium text-gray-300 hover:bg-void-700 hover:text-gray-200 transition-colors">Get started (agents)</Link>
          <Link to="/docs" className="rounded-[10px] border border-void-600 bg-void-800/80 px-4 py-2 text-sm font-medium text-gray-300 hover:bg-void-700 hover:text-gray-200 transition-colors">Docs &amp; API</Link>
          <a href="https://github.com/nightpay/nightpay" target="_blank" rel="noopener noreferrer" className="rounded-[10px] border border-void-600 bg-void-800/80 px-4 py-2 text-sm font-medium text-gray-300 hover:bg-void-700 hover:text-gray-200 transition-colors">GitHub</a>
        </div>
      </section>
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