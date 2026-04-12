import type { Bounty } from '../api.ts';

export type ReadinessBand = 'low' | 'medium' | 'high';
export type SearchStatus = Bounty['status'] | 'all';

export type SortKey =
  | 'newest'
  | 'oldest'
  | 'highest_budget'
  | 'lowest_budget'
  | 'most_claims'
  | 'most_votes'
  | 'readiness';

export interface ParsedBoardQuery {
  raw: string;
  textTerms: string[];
  tags: string[];
  status?: SearchStatus;
  agentId?: string;
  jobId?: string;
  minNight?: number;
  maxNight?: number;
  readiness?: ReadinessBand;
}

export interface EnrichedBounty extends Bounty {
  tags: string[];
  readinessScore: number;
  readinessBand: ReadinessBand;
  searchableText: string;
}

const KNOWN_STATUSES: ReadonlyArray<SearchStatus> = ['all', 'open', 'funded', 'completed', 'disputed'];
const KNOWN_READINESS: ReadonlyArray<ReadinessBand> = ['low', 'medium', 'high'];

const TAG_HINTS: Array<{ tag: string; keywords: string[] }> = [
  { tag: 'audit', keywords: ['audit', 'review', 'security review'] },
  { tag: 'security', keywords: ['security', 'vulnerability', 'threat', 'harden'] },
  { tag: 'docs', keywords: ['docs', 'documentation', 'writeup'] },
  { tag: 'research', keywords: ['research', 'investigate', 'analysis'] },
  { tag: 'frontend', keywords: ['frontend', 'ui', 'ux', 'react', 'tailwind'] },
  { tag: 'backend', keywords: ['backend', 'api', 'server', 'database'] },
  { tag: 'testing', keywords: ['test', 'qa', 'regression', 'smoke'] },
  { tag: 'automation', keywords: ['automation', 'script', 'pipeline', 'ci'] },
  { tag: 'agent', keywords: ['agent', 'openclaw', 'mip-003', 'masumi'] },
  { tag: 'midnight', keywords: ['midnight', 'compact', 'minokawa', 'zk'] },
  { tag: 'cardano', keywords: ['cardano', 'ada'] },
  { tag: 'bridge', keywords: ['bridge', 'sdk', 'provider', 'wallet'] },
  { tag: 'typescript', keywords: ['typescript', 'ts', 'node'] },
  { tag: 'python', keywords: ['python', 'fastapi', 'flask'] },
  { tag: 'devops', keywords: ['docker', 'deploy', 'hetzner', 'caddy', 'ops'] },
];

const STOP_WORDS = new Set([
  'about',
  'after',
  'agent',
  'agents',
  'allow',
  'also',
  'and',
  'any',
  'are',
  'around',
  'before',
  'board',
  'build',
  'bounty',
  'can',
  'clear',
  'completed',
  'create',
  'data',
  'deliver',
  'description',
  'done',
  'each',
  'for',
  'from',
  'full',
  'funded',
  'have',
  'into',
  'job',
  'jobs',
  'just',
  'more',
  'must',
  'need',
  'open',
  'post',
  'public',
  'result',
  'scope',
  'status',
  'task',
  'that',
  'the',
  'their',
  'them',
  'then',
  'there',
  'this',
  'through',
  'with',
  'work',
  'your',
]);

function normalizeTag(raw: string): string {
  return raw.toLowerCase().replace(/[^a-z0-9-]/g, '').trim();
}

function tokenizeQuery(query: string): string[] {
  const tokens: string[] = [];
  query.replace(/"([^"]+)"|(\S+)/g, (_, quoted: string | undefined, plain: string | undefined) => {
    const token = (quoted ?? plain ?? '').trim();
    if (token) tokens.push(token);
    return '';
  });
  return tokens;
}

function parseNightAmount(raw: string): number | undefined {
  const cleaned = raw.toLowerCase().replace(/,/g, '').trim();
  if (!cleaned) return undefined;
  const compact = cleaned.endsWith('night') ? cleaned.slice(0, -5) : cleaned;
  const value = Number(compact);
  if (!Number.isFinite(value) || value < 0) return undefined;
  return value;
}

function isKnownStatus(value: string): value is SearchStatus {
  return KNOWN_STATUSES.includes(value as SearchStatus);
}

function isKnownReadiness(value: string): value is ReadinessBand {
  return KNOWN_READINESS.includes(value as ReadinessBand);
}

export function parseBoardQuery(query: string): ParsedBoardQuery {
  const tokens = tokenizeQuery(query.trim());
  const textTerms: string[] = [];
  const tags = new Set<string>();

  const parsed: ParsedBoardQuery = {
    raw: query.trim(),
    textTerms,
    tags: [],
  };

  for (const tokenRaw of tokens) {
    const token = tokenRaw.trim();
    if (!token) continue;

    if (token.startsWith('#')) {
      const tag = normalizeTag(token.slice(1));
      if (tag) tags.add(tag);
      continue;
    }

    const colonIndex = token.indexOf(':');
    if (colonIndex > 0) {
      const key = token.slice(0, colonIndex).toLowerCase();
      const value = token.slice(colonIndex + 1).trim();
      if (!value) continue;

      if (key === 'tag') {
        const tag = normalizeTag(value);
        if (tag) tags.add(tag);
        continue;
      }

      if (key === 'status') {
        const status = value.toLowerCase();
        if (isKnownStatus(status)) parsed.status = status;
        continue;
      }

      if (key === 'agent') {
        parsed.agentId = value.toLowerCase();
        continue;
      }

      if (key === 'id' || key === 'job') {
        parsed.jobId = value.toLowerCase();
        continue;
      }

      if (key === 'min') {
        const min = parseNightAmount(value);
        if (typeof min === 'number') parsed.minNight = min;
        continue;
      }

      if (key === 'max') {
        const max = parseNightAmount(value);
        if (typeof max === 'number') parsed.maxNight = max;
        continue;
      }

      if (key === 'ready' || key === 'readiness') {
        const readiness = value.toLowerCase();
        if (isKnownReadiness(readiness)) parsed.readiness = readiness;
        continue;
      }
    }

    textTerms.push(token.toLowerCase());
  }

  parsed.tags = Array.from(tags);
  return parsed;
}

export function buildBackendSearch(parsed: ParsedBoardQuery): string {
  const parts = [...parsed.textTerms];
  if (parsed.jobId) parts.push(parsed.jobId);
  if (parsed.agentId) parts.push(parsed.agentId);
  for (const tag of parsed.tags) parts.push(tag);
  return parts.join(' ').trim();
}

function extractRawHashtags(text: string): string[] {
  const tags = new Set<string>();
  const regex = /(^|\s)#([a-z0-9][a-z0-9-]{1,24})/gi;
  let match: RegExpExecArray | null = regex.exec(text);
  while (match) {
    const tag = normalizeTag(match[2]);
    if (tag) tags.add(tag);
    match = regex.exec(text);
  }
  return Array.from(tags);
}

function extractKeywordTags(text: string): string[] {
  const hits = new Set<string>();
  const normalized = text.toLowerCase();
  for (const item of TAG_HINTS) {
    if (item.keywords.some((keyword) => normalized.includes(keyword))) {
      hits.add(item.tag);
    }
  }
  return Array.from(hits);
}

function extractFallbackTags(title: string): string[] {
  const words = title
    .toLowerCase()
    .split(/[^a-z0-9-]+/)
    .map((word) => word.trim())
    .filter((word) => word.length >= 4 && !STOP_WORDS.has(word));
  const tags: string[] = [];
  for (const word of words) {
    const tag = normalizeTag(word);
    if (!tag || tags.includes(tag)) continue;
    tags.push(tag);
    if (tags.length >= 4) break;
  }
  return tags;
}

export function deriveTagsFromBounty(bounty: Bounty): string[] {
  const source = `${bounty.title} ${bounty.description}`.trim();
  const combined = [
    ...extractRawHashtags(source),
    ...extractKeywordTags(source),
    ...extractFallbackTags(bounty.title),
  ];
  const deduped = Array.from(new Set(combined.map(normalizeTag).filter((tag) => tag.length >= 2)));
  return deduped.slice(0, 8);
}

function computeReadinessScore(bounty: Bounty, tags: string[]): number {
  const description = bounty.description.trim();
  const text = `${bounty.title} ${description}`.toLowerCase();
  let score = 0;

  if (description.length >= 200) score += 24;
  else if (description.length >= 120) score += 18;
  else if (description.length >= 80) score += 14;
  else if (description.length >= 40) score += 8;
  else if (description.length > 0) score += 4;

  if (/\b(acceptance|criteria|done when|definition of done|deliverable|success)\b/.test(text)) score += 16;
  if (/\b(deadline|due|before|within \d+|utc|timezone|by \d{4})\b/.test(text)) score += 12;
  if (/\b(test|verify|proof|receipt|validation|checklist)\b/.test(text)) score += 12;
  if (/\b(build|implement|audit|review|write|design|fix|analyze|deploy|integrate|refactor)\b/.test(text)) score += 10;
  if (tags.length >= 3) score += 10;
  else if (tags.length > 0) score += 6;
  if (bounty.amountSpecks > 0) score += 10;
  if (bounty.status === 'open') score += 6;

  return Math.max(0, Math.min(100, score));
}

function scoreToBand(score: number): ReadinessBand {
  if (score >= 70) return 'high';
  if (score >= 40) return 'medium';
  return 'low';
}

export function enrichBounties(input: Bounty[]): EnrichedBounty[] {
  return input.map((bounty) => {
    const tags = deriveTagsFromBounty(bounty);
    const readinessScore = computeReadinessScore(bounty, tags);
    return {
      ...bounty,
      tags,
      readinessScore,
      readinessBand: scoreToBand(readinessScore),
      searchableText: `${bounty.id} ${bounty.title} ${bounty.description} ${bounty.assignedAgentId ?? ''} ${tags.join(' ')}`.toLowerCase(),
    };
  });
}

export function matchesBoardQuery(item: EnrichedBounty, parsed: ParsedBoardQuery): boolean {
  if (parsed.status && parsed.status !== 'all' && item.status !== parsed.status) return false;

  if (parsed.agentId) {
    const assigned = (item.assignedAgentId ?? '').toLowerCase();
    if (!assigned.includes(parsed.agentId)) return false;
  }

  if (parsed.jobId && !item.id.toLowerCase().includes(parsed.jobId)) return false;

  if (parsed.tags.length > 0) {
    const itemTags = new Set(item.tags.map((tag) => tag.toLowerCase()));
    if (!parsed.tags.every((tag) => itemTags.has(tag))) return false;
  }

  const amountNight = item.amountSpecks / 1_000_000;
  if (typeof parsed.minNight === 'number' && amountNight < parsed.minNight) return false;
  if (typeof parsed.maxNight === 'number' && amountNight > parsed.maxNight) return false;

  if (parsed.readiness && item.readinessBand !== parsed.readiness) return false;

  if (parsed.textTerms.length > 0 && !parsed.textTerms.every((term) => item.searchableText.includes(term))) {
    return false;
  }

  return true;
}

function createdAtValue(iso: string | null): number {
  if (!iso) return 0;
  const ts = Date.parse(iso);
  return Number.isNaN(ts) ? 0 : ts;
}

export function sortEnrichedBounties(input: EnrichedBounty[], sortBy: SortKey): EnrichedBounty[] {
  const sorted = [...input];
  sorted.sort((a, b) => {
    if (sortBy === 'newest') return createdAtValue(b.createdAt) - createdAtValue(a.createdAt);
    if (sortBy === 'oldest') return createdAtValue(a.createdAt) - createdAtValue(b.createdAt);
    if (sortBy === 'highest_budget') return b.amountSpecks - a.amountSpecks;
    if (sortBy === 'lowest_budget') return a.amountSpecks - b.amountSpecks;
    if (sortBy === 'most_claims') return b.claimsCount - a.claimsCount;
    if (sortBy === 'most_votes') {
      const va = a.approveVotes + a.rejectVotes;
      const vb = b.approveVotes + b.rejectVotes;
      return vb - va;
    }
    if (sortBy === 'readiness') return b.readinessScore - a.readinessScore;
    return 0;
  });
  return sorted;
}

export function countTopTags(input: EnrichedBounty[], limit = 16): Array<{ tag: string; count: number }> {
  const counts = new Map<string, number>();
  for (const bounty of input) {
    for (const tag of bounty.tags) {
      counts.set(tag, (counts.get(tag) ?? 0) + 1);
    }
  }
  return Array.from(counts.entries())
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit)
    .map(([tag, count]) => ({ tag, count }));
}
