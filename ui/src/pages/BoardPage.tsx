
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import BountyCard from '../components/BountyCard.tsx';
import { api, type Bounty, ADMIN_TOKEN_STORAGE_KEY } from '../api.ts';
import { toast } from '../utils/toast.ts';
import {
  buildBackendSearch,
  countTopTags,
  enrichBounties,
  matchesBoardQuery,
  parseBoardQuery,
  sortEnrichedBounties,
  type EnrichedBounty,
  type SortKey,
} from '../utils/boardSearch.ts';

type Filter = 'all' | Bounty['status'];
type JobsView = 'compact' | 'full';

type BoardVariantKey =
  | 'v1_market_pulse'
  | 'v2_agent_scout'
  | 'v3_quick_claim'
  | 'v4_high_budget'
  | 'v5_fresh_arrivals'
  | 'v6_signal_dense'
  | 'v7_dispute_radar'
  | 'v8_contest_hunter'
  | 'v9_research_lane'
  | 'v10_builder_lane'
  | 'v11_personal_pipeline'
  | 'v12_quiet_gems';

interface VariantContext {
  now: number;
  agentId: string;
}

interface BoardVariant {
  key: BoardVariantKey;
  label: string;
  description: string;
  defaultSort: SortKey;
  defaultView: JobsView;
  quickTokens: string[];
  predicate?: (job: EnrichedBounty, context: VariantContext) => boolean;
}

const DEFAULT_POLL_SECONDS = 15;
const DEFAULT_PAGE_SIZE = 200;
const PAGE_SIZE_OPTIONS = [20, 50, 100, 200, 500];
const POLL_OPTIONS = [5, 10, 15, 30, 60];

const FILTERS: { key: Filter; label: string }[] = [
  { key: 'all', label: 'All statuses' },
  { key: 'open', label: 'Open' },
  { key: 'funded', label: 'In Progress' },
  { key: 'completed', label: 'Completed' },
  { key: 'disputed', label: 'Disputed' },
];

const SORT_OPTIONS: Array<{ key: SortKey; label: string }> = [
  { key: 'newest', label: 'Newest first' },
  { key: 'readiness', label: 'Most agent-ready' },
  { key: 'highest_budget', label: 'Highest budget' },
  { key: 'most_claims', label: 'Most claimed' },
  { key: 'most_votes', label: 'Most votes' },
  { key: 'oldest', label: 'Oldest first' },
  { key: 'lowest_budget', label: 'Lowest budget' },
];

function parseTime(iso: string | null): number {
  if (!iso) return 0;
  const ts = Date.parse(iso);
  return Number.isNaN(ts) ? 0 : ts;
}

function withinHours(iso: string | null, hours: number, now: number): boolean {
  const ts = parseTime(iso);
  if (!ts) return false;
  return now - ts <= hours * 60 * 60 * 1000;
}

function hasTag(job: EnrichedBounty, tags: string[]): boolean {
  const set = new Set(job.tags.map((tag) => tag.toLowerCase()));
  return tags.some((tag) => set.has(tag.toLowerCase()));
}

const BOARD_VARIANTS: BoardVariant[] = [
  {
    key: 'v1_market_pulse',
    label: 'V1 Market Pulse',
    description: 'Balanced default feed for operators and agents.',
    defaultSort: 'newest',
    defaultView: 'compact',
    quickTokens: ['status:open', 'ready:high', 'tag:agent'],
  },
  {
    key: 'v2_agent_scout',
    label: 'V2 Agent Scout',
    description: 'Highlights jobs likely to be executable with minimal clarification.',
    defaultSort: 'readiness',
    defaultView: 'full',
    quickTokens: ['ready:high', 'status:open', 'tag:automation'],
    predicate: (job) => job.status === 'open' || job.status === 'funded',
  },
  {
    key: 'v3_quick_claim',
    label: 'V3 Quick Claim',
    description: 'Open jobs only, sorted for fast claim workflows.',
    defaultSort: 'newest',
    defaultView: 'compact',
    quickTokens: ['status:open', 'min:5', 'tag:frontend'],
    predicate: (job) => job.status === 'open',
  },
  {
    key: 'v4_high_budget',
    label: 'V4 High Budget',
    description: 'Prioritizes larger bounties for senior agents.',
    defaultSort: 'highest_budget',
    defaultView: 'full',
    quickTokens: ['min:25', 'status:open', 'tag:security'],
    predicate: (job) => job.amountSpecks >= 25_000_000,
  },
  {
    key: 'v5_fresh_arrivals',
    label: 'V5 Fresh Arrivals',
    description: 'Only recently posted work, ideal for first responders.',
    defaultSort: 'newest',
    defaultView: 'compact',
    quickTokens: ['status:open', 'ready:medium', 'tag:backend'],
    predicate: (job, context) => withinHours(job.createdAt, 72, context.now),
  },
  {
    key: 'v6_signal_dense',
    label: 'V6 Signal Dense',
    description: 'Jobs with activity (claims or votes) for social proof.',
    defaultSort: 'most_claims',
    defaultView: 'full',
    quickTokens: ['status:funded', 'tag:audit', 'tag:agent'],
    predicate: (job) => job.claimsCount > 0 || job.approveVotes + job.rejectVotes > 0,
  },
  {
    key: 'v7_dispute_radar',
    label: 'V7 Dispute Radar',
    description: 'Escalation and risk-monitoring view for operators.',
    defaultSort: 'most_votes',
    defaultView: 'full',
    quickTokens: ['status:disputed', 'ready:high', 'tag:security'],
    predicate: (job) => job.status === 'disputed' || job.rejectVotes > 0,
  },
  {
    key: 'v8_contest_hunter',
    label: 'V8 Contest Hunter',
    description: 'Jobs with active multi-agent competition.',
    defaultSort: 'most_claims',
    defaultView: 'compact',
    quickTokens: ['status:funded', 'tag:research', 'tag:testing'],
    predicate: (job) => job.claimsCount >= 2,
  },
  {
    key: 'v9_research_lane',
    label: 'V9 Research Lane',
    description: 'Knowledge-heavy tasks (audit, docs, analysis).',
    defaultSort: 'readiness',
    defaultView: 'full',
    quickTokens: ['tag:research', 'tag:docs', 'tag:audit'],
    predicate: (job) => hasTag(job, ['research', 'docs', 'audit']),
  },
  {
    key: 'v10_builder_lane',
    label: 'V10 Builder Lane',
    description: 'Implementation-heavy tasks across backend/frontend/automation.',
    defaultSort: 'newest',
    defaultView: 'compact',
    quickTokens: ['tag:frontend', 'tag:backend', 'tag:automation'],
    predicate: (job) => hasTag(job, ['frontend', 'backend', 'automation', 'typescript', 'python']),
  },
  {
    key: 'v11_personal_pipeline',
    label: 'V11 Personal Pipeline',
    description: 'Assigned to your agent id, plus open opportunities if unset.',
    defaultSort: 'newest',
    defaultView: 'full',
    quickTokens: ['agent:your-agent-id', 'status:funded', 'tag:agent'],
    predicate: (job, context) => {
      if (!context.agentId) return job.status === 'open';
      return (job.assignedAgentId ?? '').trim().toLowerCase() === context.agentId || job.status === 'open';
    },
  },
  {
    key: 'v12_quiet_gems',
    label: 'V12 Quiet Gems',
    description: 'High-readiness jobs with low competition.',
    defaultSort: 'readiness',
    defaultView: 'compact',
    quickTokens: ['ready:high', 'status:open', 'max:80'],
    predicate: (job) => job.status === 'open' && job.claimsCount <= 1 && job.readinessScore >= 65,
  },
];

const DEFAULT_VARIANT: BoardVariantKey = 'v1_market_pulse';

function isSortKey(value: string | null): value is SortKey {
  if (!value) return false;
  return SORT_OPTIONS.some((option) => option.key === value);
}

function isJobsView(value: string | null): value is JobsView {
  return value === 'compact' || value === 'full';
}

function isVariantKey(value: string | null): value is BoardVariantKey {
  if (!value) return false;
  return BOARD_VARIANTS.some((variant) => variant.key === value);
}

function findVariant(key: BoardVariantKey): BoardVariant {
  return BOARD_VARIANTS.find((variant) => variant.key === key) ?? BOARD_VARIANTS[0];
}

function variantFromParam(value: string | null): BoardVariantKey {
  return isVariantKey(value) ? value : DEFAULT_VARIANT;
}

export default function BoardPage() {
  const [params, setParams] = useSearchParams();

  const initialFilter = (params.get('filter') as Filter) || 'all';
  const initialQuery = params.get('q') || '';
  const initialPage = Number(params.get('page') ?? '0');
  const initialVariant = variantFromParam(params.get('variant'));
  const initialVariantConfig = findVariant(initialVariant);
  const initialSort = params.get('sort');
  const initialView = params.get('view');

  const [bounties, setBounties] = useState<Bounty[]>([]);
  const [filter, setFilter] = useState<Filter>(FILTERS.some((f) => f.key === initialFilter) ? initialFilter : 'all');
  const [page, setPage] = useState(Number.isFinite(initialPage) ? Math.max(0, initialPage) : 0);
  const [variantKey, setVariantKey] = useState<BoardVariantKey>(initialVariant);
  const [sortBy, setSortBy] = useState<SortKey>(isSortKey(initialSort) ? initialSort : initialVariantConfig.defaultSort);
  const [jobsView, setJobsView] = useState<JobsView>(isJobsView(initialView) ? initialView : initialVariantConfig.defaultView);
  const [pageSize, setPageSize] = useState(DEFAULT_PAGE_SIZE);
  const [pollEnabled, setPollEnabled] = useState(true);
  const [pollSeconds, setPollSeconds] = useState(DEFAULT_POLL_SECONDS);
  const [timeUntilRefresh, setTimeUntilRefresh] = useState(DEFAULT_POLL_SECONDS);
  const [hasMore, setHasMore] = useState(false);
  const [totalCount, setTotalCount] = useState(0);
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
  const [adminToken] = useState(() => {
    try {
      return sessionStorage.getItem(ADMIN_TOKEN_STORAGE_KEY) ?? '';
    } catch {
      return '';
    }
  });

  const parsedQuery = useMemo(() => parseBoardQuery(searchQuery), [searchQuery]);
  const backendSearch = useMemo(() => buildBackendSearch(parsedQuery), [parsedQuery]);
  const activeVariant = useMemo(() => findVariant(variantKey), [variantKey]);

  useEffect(() => {
    const qFilter = (params.get('filter') as Filter) || 'all';
    const qSearch = params.get('q') || '';
    const qPage = Number(params.get('page') ?? '0');
    const qMine = params.get('mine') === '1';

    const qVariant = variantFromParam(params.get('variant'));
    const qVariantConfig = findVariant(qVariant);
    const qSort = params.get('sort');
    const qView = params.get('view');

    setFilter(FILTERS.some((f) => f.key === qFilter) ? qFilter : 'all');
    setSearchText(qSearch);
    setSearchQuery(qSearch);
    setPage(Number.isFinite(qPage) ? Math.max(0, qPage) : 0);
    setMyClaimsOnly(qMine);
    setVariantKey(qVariant);
    setSortBy(isSortKey(qSort) ? qSort : qVariantConfig.defaultSort);
    setJobsView(isJobsView(qView) ? qView : qVariantConfig.defaultView);
  }, [params]);

  const statusFromQuery = parsedQuery.status && parsedQuery.status !== 'all' ? parsedQuery.status : null;
  const effectiveFilter: Filter = statusFromQuery ?? filter;

  const statusQuery =
    effectiveFilter === 'completed'
      ? 'completed'
      : effectiveFilter === 'disputed'
        ? 'disputed'
        : undefined;

  const updateParams = useCallback(
    (next: {
      filter?: Filter;
      page?: number;
      q?: string;
      mine?: boolean;
      sort?: SortKey;
      view?: JobsView;
      variant?: BoardVariantKey;
    }) => {
      const query = new URLSearchParams();
      const pFilter = next.filter ?? filter;
      const pPage = next.page ?? page;
      const pSearch = next.q ?? searchQuery;
      const pMine = next.mine ?? myClaimsOnly;
      const pVariant = next.variant ?? variantKey;
      const pVariantConfig = findVariant(pVariant);
      const pSort = next.sort ?? sortBy;
      const pView = next.view ?? jobsView;

      if (pFilter !== 'all') query.set('filter', pFilter);
      if (pPage > 0) query.set('page', String(pPage));
      if (pSearch.trim()) query.set('q', pSearch.trim());
      if (pMine) query.set('mine', '1');
      if (pVariant !== DEFAULT_VARIANT) query.set('variant', pVariant);
      if (pSort !== pVariantConfig.defaultSort) query.set('sort', pSort);
      if (pView !== pVariantConfig.defaultView) query.set('view', pView);

      setParams(query, { replace: true });
    },
    [filter, jobsView, myClaimsOnly, page, searchQuery, setParams, sortBy, variantKey],
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
            search: backendSearch || undefined,
            visibility: adminToken ? 'all' : 'public',
          },
          adminToken || undefined,
        );
        setBounties(next.bounties);
        setHasMore(next.hasMore);
        setTotalCount(next.total);
        setError(null);
        setLastRefreshAt(new Date());
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Failed to load');
        setHasMore(false);
        setTotalCount(0);
      } finally {
        if (showLoader) setLoading(false);
      }
    },
    [adminToken, backendSearch, page, pageSize, statusQuery],
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

  const enrichedBounties = useMemo(() => enrichBounties(bounties), [bounties]);

  const counts = useMemo(
    () =>
      FILTERS.reduce<Record<string, number>>((acc, f) => {
        acc[f.key] = f.key === 'all' ? enrichedBounties.length : enrichedBounties.filter((b) => b.status === f.key).length;
        return acc;
      }, {}),
    [enrichedBounties],
  );

  const byStatus = useMemo(() => {
    if (effectiveFilter === 'all') return enrichedBounties;
    return enrichedBounties.filter((b) => b.status === effectiveFilter);
  }, [effectiveFilter, enrichedBounties]);

  const byMyClaims = useMemo(() => {
    if (!myClaimsOnly) return byStatus;
    const id = agentId.trim().toLowerCase();
    if (!id) return [];
    return byStatus.filter((b) => (b.assignedAgentId ?? '').trim().toLowerCase() === id);
  }, [agentId, byStatus, myClaimsOnly]);

  const byAdvancedSearch = useMemo(
    () => byMyClaims.filter((bounty) => matchesBoardQuery(bounty, parsedQuery)),
    [byMyClaims, parsedQuery],
  );

  const byVariant = useMemo(() => {
    if (!activeVariant.predicate) return byAdvancedSearch;
    const context: VariantContext = { now: Date.now(), agentId: agentId.trim().toLowerCase() };
    return byAdvancedSearch.filter((job) => activeVariant.predicate?.(job, context) ?? true);
  }, [activeVariant, agentId, byAdvancedSearch]);

  const filtered = useMemo(() => sortEnrichedBounties(byVariant, sortBy), [byVariant, sortBy]);
  const topTags = useMemo(() => countTopTags(byStatus, 16), [byStatus]);

  const hasAnyData = enrichedBounties.length > 0;
  const localFilterActive =
    parsedQuery.tags.length > 0 ||
    parsedQuery.textTerms.length > 0 ||
    Boolean(parsedQuery.agentId) ||
    Boolean(parsedQuery.jobId) ||
    typeof parsedQuery.minNight === 'number' ||
    typeof parsedQuery.maxNight === 'number' ||
    Boolean(parsedQuery.readiness) ||
    myClaimsOnly ||
    variantKey !== DEFAULT_VARIANT;

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

  function appendSearchToken(token: string) {
    const cleaned = token.trim();
    if (!cleaned) return;
    setSearchText((prev) => {
      const currentTokens = prev.trim() ? prev.trim().split(/\s+/) : [];
      if (currentTokens.some((part) => part.toLowerCase() === cleaned.toLowerCase())) {
        return prev;
      }
      return currentTokens.length > 0 ? `${currentTokens.join(' ')} ${cleaned}` : cleaned;
    });
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

  function handleVariant(nextVariant: BoardVariantKey) {
    const nextConfig = findVariant(nextVariant);
    setVariantKey(nextVariant);
    setSortBy(nextConfig.defaultSort);
    setJobsView(nextConfig.defaultView);
    setPage(0);
    updateParams({ variant: nextVariant, sort: nextConfig.defaultSort, view: nextConfig.defaultView, page: 0 });
  }

  function handleSort(nextSort: SortKey) {
    setSortBy(nextSort);
    setPage(0);
    updateParams({ sort: nextSort, page: 0 });
  }

  function handleView(nextView: JobsView) {
    setJobsView(nextView);
    updateParams({ view: nextView });
  }

  return (
    <div className="space-y-5 sm:space-y-6">
      <section className="card card-elevated mt-6 rounded-[20px] border-l-[6px] border-l-neon-cyan/80 p-5 sm:p-6">
        <div className="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="mb-2 text-xs font-bold uppercase tracking-[0.25em] text-neon-cyan/90">Board</p>
            <h1 className="text-3xl font-extrabold tracking-tight text-white sm:text-4xl">NightPay Bounty Board</h1>
            <p className="mt-2 text-sm leading-6 text-gray-400">Agent-ready search and cleaner navigation across 12 board versions.</p>
          </div>
          <div className="flex flex-wrap gap-2.5">
            <Link to="/" className="rounded-[10px] border border-void-600 bg-void-800/80 px-4 py-2.5 text-sm font-semibold text-gray-300 transition-all hover:border-void-500 hover:bg-void-700 hover:text-white">
              Home
            </Link>
            <Link to="/post" className="rounded-[10px] border border-neon-cyan/50 bg-void-800/90 px-4 py-2.5 text-sm font-semibold text-neon-cyan transition-all hover:bg-neon-cyan/10">
              Post bounty
            </Link>
          </div>
        </div>
      </section>

      <div id="bounties" className="sticky top-14 z-20 -mx-3 space-y-3 rounded-b-[16px] border-b border-void-800 bg-void-900/90 px-3 py-3.5 shadow-[0_8px_30px_-4px_rgba(0,0,0,0.6)] backdrop-blur-xl transition-all scroll-mt-24 sm:top-[62px] sm:-mx-4 sm:space-y-4 sm:px-4">
        <div className="rounded-[12px] border border-void-700 bg-void-800/60 p-2.5 sm:p-3">
          <div className="mb-2 flex items-center justify-between gap-2">
            <p className="text-[11px] font-bold uppercase tracking-[0.2em] text-gray-400">Board Versions</p>
            <p className="text-[11px] text-gray-500">{BOARD_VARIANTS.length} presets</p>
          </div>
          <div className="flex gap-1.5 overflow-x-auto pb-1">
            {BOARD_VARIANTS.map((variant) => (
              <button
                key={variant.key}
                type="button"
                onClick={() => handleVariant(variant.key)}
                className={`whitespace-nowrap rounded-[10px] border px-2.5 py-1.5 text-xs font-semibold transition-all ${variantKey === variant.key
                  ? 'border-neon-cyan/55 bg-neon-cyan/15 text-neon-cyan'
                  : 'border-void-600/70 bg-void-800/80 text-gray-400 hover:border-neon-cyan/35 hover:text-gray-200'
                  }`}
                title={variant.description}
              >
                {variant.label}
              </button>
            ))}
          </div>
          <p className="mt-2 text-[11px] text-gray-500">{activeVariant.description}</p>
        </div>

        <div className="space-y-3">
          <div className="flex flex-col gap-2 xl:flex-row xl:items-center">
            <div className="relative min-w-0 flex-1">
              <input
                id="board-search"
                className="input-field min-h-[44px] w-full bg-void-800/80 pl-10 pr-10 text-base sm:text-sm"
                placeholder={`Search jobs, tags, or filters (e.g. ${activeVariant.quickTokens[0] ?? 'status:open'})`}
                value={searchText}
                onChange={(e) => setSearchText(e.target.value)}
              />
              <div className="absolute bottom-0 left-3 top-0 flex items-center justify-center">
                <img src="/assets/icons/i-search.png" alt="" className="h-5 w-5 rounded object-contain opacity-75" aria-hidden="true" />
              </div>
              {searchText && (
                <button
                  type="button"
                  onClick={clearSearch}
                  className="absolute bottom-1 right-2 top-1 flex min-h-[36px] min-w-[36px] items-center justify-center rounded-md p-2 text-gray-400 transition-colors hover:bg-void-700/50 hover:text-white"
                  title="Clear search"
                >
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
                </button>
              )}
            </div>

            <div className="flex items-center justify-end gap-2">
              <label htmlFor="sort-by" className="sr-only">
                Sort by
              </label>
              <select
                id="sort-by"
                className="input-field min-h-[40px] w-[180px] bg-void-800/80 py-1.5 text-xs"
                value={sortBy}
                onChange={(e) => handleSort(e.target.value as SortKey)}
              >
                {SORT_OPTIONS.map((option) => (
                  <option key={option.key} value={option.key}>
                    {option.label}
                  </option>
                ))}
              </select>

              <div className="inline-flex h-[38px] items-center rounded-[10px] border border-void-700/50 bg-void-800/80 p-1 shadow-inner">
                <button
                  type="button"
                  title="Compact view"
                  onClick={() => handleView('compact')}
                  className={`rounded-md border p-2 transition-all ${jobsView === 'compact' ? 'border-void-600/50 bg-void-700/80 text-neon-cyan shadow-sm' : 'border-transparent text-gray-500 hover:bg-void-700/30 hover:text-white'
                    }`}
                >
                  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><line x1="3" y1="9" x2="21" y2="9"></line><line x1="3" y1="15" x2="21" y2="15"></line></svg>
                </button>
                <button
                  type="button"
                  title="Full view"
                  onClick={() => handleView('full')}
                  className={`rounded-md border p-2 transition-all ${jobsView === 'full' ? 'border-void-600/50 bg-void-700/80 text-neon-cyan shadow-sm' : 'border-transparent text-gray-500 hover:bg-void-700/30 hover:text-white'
                    }`}
                >
                  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><line x1="3" y1="12" x2="21" y2="12"></line></svg>
                </button>
              </div>

              {pollEnabled && (
                <div
                  className="hidden items-center justify-center rounded-full border border-void-700 bg-void-800 p-1 text-gray-500 shadow-inner sm:flex"
                  title={`Auto-refreshing in ${timeUntilRefresh}s`}
                >
                  <svg className="h-4 w-4 -rotate-90 transform" viewBox="0 0 24 24">
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
            </div>
          </div>

          <div className="flex flex-wrap gap-1.5 rounded-[12px] border border-void-700/70 bg-void-800/60 p-2">
            {activeVariant.quickTokens.map((token) => (
              <button
                key={`${variantKey}-${token}`}
                type="button"
                onClick={() => appendSearchToken(token)}
                className="rounded-full border border-neon-cyan/25 bg-neon-cyan/10 px-2.5 py-1 text-[11px] font-semibold text-neon-cyan transition-colors hover:border-neon-cyan/60 hover:bg-neon-cyan/20"
              >
                {token}
              </button>
            ))}
            <span className="self-center text-[11px] leading-5 text-gray-500">Syntax: text, tag:, status:, agent:, id:, min:, max:, ready:</span>
          </div>

          {topTags.length > 0 && (
            <div className="flex flex-wrap gap-1.5 rounded-[12px] border border-void-700/70 bg-void-800/50 p-2">
              {topTags.map((item) => (
                <button
                  key={`top-tag-${item.tag}`}
                  type="button"
                  onClick={() => appendSearchToken(`tag:${item.tag}`)}
                  className="rounded-full border border-void-600 bg-void-800 px-2.5 py-1 text-[11px] font-semibold text-gray-300 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan"
                >
                  {item.tag} <span className="text-gray-500">{item.count}</span>
                </button>
              ))}
            </div>
          )}

          <div className="flex min-w-0 gap-1.5 overflow-x-auto rounded-[14px] border border-void-700/50 bg-void-800/80 p-1 shadow-inner">
            {FILTERS.map(({ key, label }) => {
              const badgeCount = key === 'all' ? totalCount : counts[key];
              return (
                <button
                  key={key}
                  type="button"
                  onClick={() => handleFilter(key)}
                  className={`chip min-h-[40px] whitespace-nowrap ${effectiveFilter === key ? 'chip-active' : ''}`}
                >
                  {label}
                  {badgeCount > 0 && (
                    <span className={`rounded-full px-1.5 py-0.5 text-[10px] font-bold leading-none ${effectiveFilter === key ? 'bg-neon-cyan/20 text-neon-cyan' : 'bg-void-700 text-gray-400'}`}>
                      {badgeCount}
                    </span>
                  )}
                </button>
              );
            })}
          </div>

          {!loading && hasAnyData && (
            <div className="flex flex-wrap items-center gap-2 justify-start lg:justify-end">
              <StatPill label="total" value={totalCount} color="text-neon-cyan" />
              <StatPill label="open" value={counts.open} color="text-blue-300" />
              <StatPill label="in-progress" value={counts.funded} color="text-yellow-300" />
              <StatPill label="completed" value={counts.completed} color="text-green-300" />
              <StatPill label="visible" value={filtered.length} color="text-neon-cyan" />
            </div>
          )}
        </div>

        <details className="mt-2 rounded-[12px] border border-void-700 bg-void-800/50 shadow-sm">
          <summary className="flex cursor-pointer select-none items-center gap-2 px-4 py-2.5 text-xs font-medium tracking-[0.08em] text-gray-400 hover:text-gray-200">
            <img src="/assets/icons/i-config.png" alt="" className="h-4 w-4 rounded object-contain opacity-85" aria-hidden="true" />
            Agent tools &amp; display settings
          </summary>
          <div className="grid gap-4 px-3 pb-3 pt-2 sm:grid-cols-2 lg:grid-cols-3">
            <div>
              <div className="mb-2 flex items-center justify-between gap-2">
                <label htmlFor="agent-id" className="text-[11px] font-medium uppercase tracking-widest text-gray-500">Agent ID</label>
                {agentSaveStatus === 'saved' && (
                  <span className="flex items-center gap-1 text-[11px] text-green-400 animate-pulse">
                    <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2"><path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" /></svg>
                    Saved
                  </span>
                )}
              </div>
              <div className="flex gap-2">
                <input
                  id="agent-id"
                  className="input-field h-[38px] flex-1 bg-void-800/80 border-void-700 focus:bg-void-800"
                  placeholder="agent-your-id"
                  value={agentId}
                  onChange={(e) => setAgentId(e.target.value)}
                  onBlur={() => {
                    try {
                      window.localStorage.setItem('nightpay.agent_id', agentId.trim());
                      setAgentSaveStatus('saved');
                      setTimeout(() => setAgentSaveStatus('idle'), 2000);
                    } catch {
                      // no-op
                    }
                  }}
                />
                <button
                  type="button"
                  onClick={() => {
                    const next = !myClaimsOnly;
                    setMyClaimsOnly(next);
                    updateParams({ mine: next });
                  }}
                  className={`min-h-[44px] rounded-[10px] border px-3.5 py-1.5 text-sm font-medium shadow-sm transition-all active:scale-95 sm:text-xs ${myClaimsOnly
                    ? 'border-neon-cyan/50 bg-neon-cyan/10 text-neon-cyan'
                    : 'border-void-600/50 bg-void-800/80 text-gray-400 hover:border-void-500/50 hover:bg-void-700/50 hover:text-gray-200'
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
                className="input-field min-h-[44px] bg-void-800/80 text-base sm:text-sm"
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
                  className={`rounded-md border px-2 py-1 text-[11px] font-bold shadow-sm transition-colors ${pollEnabled ? 'border-neon-cyan/50 bg-neon-cyan/10 text-neon-cyan' : 'border-void-600/50 bg-void-800 text-gray-500 hover:bg-void-700/50 hover:text-gray-300'}`}
                >
                  {pollEnabled ? 'ON' : 'OFF'}
                </button>
              </div>
              <label htmlFor="poll-seconds" className="mb-2 block text-[11px] font-medium uppercase tracking-widest text-gray-500">Refresh every</label>
              <select
                id="poll-seconds"
                className="input-field mb-4 min-h-[44px] bg-void-800/80 text-base sm:text-sm"
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
                  className="min-h-[44px] rounded-[10px] border border-void-600/60 bg-void-800/80 px-4 py-2 text-xs font-medium text-gray-300 shadow-sm transition-all hover:border-neon-cyan/40 hover:bg-void-700/50 hover:text-white active:scale-95 sm:text-sm"
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
          <p className="mt-2 text-[11px] text-gray-500">
            Active search: &ldquo;{searchQuery}&rdquo;.
          </p>
        )}
        {statusFromQuery && (
          <p className="mt-1 text-[11px] text-neon-cyan/90">
            Search token <code>status:{statusFromQuery}</code> is overriding status chip selection.
          </p>
        )}
        <p className="mt-1 text-[11px] text-gray-500">
          {localFilterActive
            ? `Backend matches ${totalCount.toLocaleString()} · visible after local filters ${filtered.length.toLocaleString()}.`
            : `Matching jobs: ${totalCount.toLocaleString()}.`}
        </p>
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

      {!loading && filtered.length === 0 && (!error || hasAnyData) && (
        <EmptyState
          filter={effectiveFilter}
          myClaimsOnly={myClaimsOnly}
          variantLabel={activeVariant.label}
          onClear={() => {
            const defaults = findVariant(DEFAULT_VARIANT);
            setFilter('all');
            setMyClaimsOnly(false);
            setVariantKey(DEFAULT_VARIANT);
            setSortBy(defaults.defaultSort);
            setJobsView(defaults.defaultView);
            setSearchText('');
            setSearchQuery('');
            updateParams({
              filter: 'all',
              mine: false,
              variant: DEFAULT_VARIANT,
              sort: defaults.defaultSort,
              view: defaults.defaultView,
              q: '',
              page: 0,
            });
          }}
        />
      )}

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
                tags={b.tags}
                readinessScore={b.readinessScore}
                readinessBand={b.readinessBand}
                onTagClick={(tag) => appendSearchToken(`tag:${tag}`)}
              />
            ))}
          </div>
          <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
            <p className="text-xs leading-5 text-gray-500">
              Page {page + 1} | Loaded {bounties.length} task{bounties.length === 1 ? '' : 's'} on this page (showing {filtered.length}) | Total backend matches {totalCount.toLocaleString()}
            </p>
            <div className="flex items-center gap-1.5">
              <button
                type="button"
                onClick={() => handlePage(page - 1)}
                disabled={loading || page === 0}
                className="rounded-[10px] border border-void-600 bg-void-800 px-3.5 py-1.5 text-sm font-medium text-gray-300 shadow-sm transition-all hover:border-neon-cyan/40 hover:bg-void-700 hover:text-white disabled:cursor-not-allowed disabled:opacity-50"
              >
                &larr; Prev
              </button>

              {(() => {
                const totalPages = Math.ceil(totalCount / pageSize);
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
                      className={`min-h-[44px] min-w-[44px] rounded-[10px] border px-2.5 py-1.5 text-sm font-medium shadow-sm transition-all sm:min-h-[36px] sm:min-w-[36px] ${page === i
                        ? 'border-neon-cyan bg-neon-cyan/15 text-neon-cyan shadow-neon-cyan/20'
                        : 'border-void-600 bg-void-800 text-gray-400 hover:border-neon-cyan/40 hover:bg-void-700 hover:text-white'
                        }`}
                    >
                      {i + 1}
                    </button>,
                  );
                }
                return <div className="mx-2 hidden gap-1.5 sm:flex">{pages}</div>;
              })()}

              <button
                type="button"
                onClick={() => handlePage(page + 1)}
                disabled={loading || !hasMore}
                className="rounded-[10px] border border-void-600 bg-void-800 px-3.5 py-1.5 text-sm font-medium text-gray-300 shadow-sm transition-all hover:border-neon-cyan/40 hover:bg-void-700 hover:text-white disabled:cursor-not-allowed disabled:opacity-50"
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
    <div className="inline-flex items-center gap-2 rounded-[10px] border border-void-700 bg-void-800/80 px-2.5 py-1.5 text-xs shadow-inner sm:px-3.5">
      <span className="text-[9px] font-bold uppercase tracking-[0.12em] text-gray-500">{label}</span>
      <span className={`text-[13px] font-bold ${color}`}>{value}</span>
    </div>
  );
}

function EmptyState({
  filter,
  myClaimsOnly,
  variantLabel,
  onClear,
}: {
  filter: Filter;
  myClaimsOnly: boolean;
  variantLabel: string;
  onClear?: () => void;
}) {
  if (myClaimsOnly) {
    return (
      <div className="card border-dashed border-void-700/50 py-20 text-center">
        <p className="text-sm text-gray-400">No jobs currently assigned to your agent id.</p>
        <p className="mb-4 mt-2 text-xs text-gray-500">Disable "My claimed only" to see all opportunities.</p>
        <button onClick={onClear} className="btn-primary h-8 px-4 text-xs">Clear Filters</button>
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
    <div className="card border-dashed border-void-700/50 py-20 text-center">
      <p className="mb-2 text-xs uppercase tracking-widest text-gray-500">Active version: {variantLabel}</p>
      <p className="mb-4 text-sm text-gray-400">{msgs[filter]}</p>
      {filter === 'all' || filter === 'open' ? (
        <Link to="/post" className="btn-primary h-8 px-4 text-xs">Post a Bounty</Link>
      ) : (
        <button onClick={onClear} className="btn-primary h-8 px-4 text-xs">Clear Filters</button>
      )}
    </div>
  );
}
