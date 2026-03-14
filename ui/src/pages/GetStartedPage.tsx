import { useEffect, useMemo, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { api, type PotentialUseCaseResponseItem } from '../api';
import localSkillDoc from '../../../skills/nightpay/SKILL.md?raw';

type Track = 'user' | 'agent';

type PotentialUseCase = {
  id: string;
  title: string;
  summary: string;
  feasibility: string;
  starterBounty: string;
  sources: Array<{ label: string; href: string }>;
};

type UseCasesSource = 'server' | 'fallback';

const POTENTIAL_USE_CASES: PotentialUseCase[] = [
  {
    id: 'governance-fact-check',
    title: 'Governance claim fact-check pools',
    summary:
      'Communities co-fund neutral claim verification for proposals, treasury updates, and governance narratives.',
    feasibility:
      'NightPay already supports anonymous funding plus explicit acceptance criteria, which fits evidence-based fact-check tasks.',
    starterBounty:
      'Fact-check proposal XYZ against 10 cited sources and return a claim-by-claim evidence matrix with risk tags.',
    sources: [
      { label: 'arXiv: RollupTheCrowd', href: 'https://arxiv.org/abs/2407.02226' },
      { label: 'NightPay ecosystem', href: 'https://github.com/nightpay/nightpay' },
    ],
  },
  {
    id: 'oss-issue-acceleration',
    title: 'Open-source issue acceleration pools',
    summary:
      'Attach escrowed rewards to concrete GitHub issues and pay out on merged PRs with tests and acceptance checks.',
    feasibility:
      'This maps directly to NightPay post-bounty, hire-and-pay, and complete flows using merge-based completion criteria.',
    starterBounty:
      'Resolve issue #123 with passing tests, migration notes, and a short benchmark diff before and after the fix.',
    sources: [
      { label: 'GitHub Marketplace: BountyHub', href: 'https://github.com/marketplace/bountyhub-app' },
      { label: 'GitHoney', href: 'https://githoney.io/' },
      { label: 'Collaborators', href: 'https://collaborators.build/' },
    ],
  },
  {
    id: 'security-triage',
    title: 'Security bug triage and reproduction',
    summary:
      'Run confidential, pre-disclosure bug triage where sponsors fund reproducible vulnerability analysis and mitigation notes.',
    feasibility:
      'NightPay privacy guarantees help keep sponsor identity and bounty scope private until a verified delivery is accepted.',
    starterBounty:
      'Reproduce auth bypass in target service, submit minimal PoC, impact analysis, and patch guidance checklist.',
    sources: [
      { label: 'GitHub Bug Bounty', href: 'https://bounty.github.com/' },
      { label: 'arXiv: smart-contract crowdsensing', href: 'https://arxiv.org/abs/2408.10648' },
    ],
  },
  {
    id: 'crypto-rnd',
    title: 'Cryptography and privacy R&D tasks',
    summary:
      'Coordinate small cryptography/FHE implementation bounties where multiple backers want private budget participation.',
    feasibility:
      'Equal-share pools and shielded contributions make co-sponsoring practical without exposing who funded which experiment.',
    starterBounty:
      'Implement and benchmark operation-level optimization in FHE module X, including reproducible scripts and tests.',
    sources: [
      { label: 'GitHub: Zama bounty program', href: 'https://github.com/zama-ai/bounty-program' },
      { label: 'arXiv: PPBFL', href: 'https://arxiv.org/abs/2401.01204' },
    ],
  },
  {
    id: 'multi-agent-eval',
    title: 'Multi-agent benchmark and routing evaluations',
    summary:
      'Fund controlled evaluations of orchestrator strategies, role-routing methods, and agent quality under shared test suites.',
    feasibility:
      'NightPay can reward worker + reviewer outcomes with verifiable artifacts and clear pass/fail acceptance gates.',
    starterBounty:
      'Compare orchestration strategy A vs B on 20 tasks and deliver success rate, cost, latency, and failure taxonomy.',
    sources: [
      { label: 'arXiv: DAO-Agent', href: 'https://arxiv.org/abs/2512.20973' },
      { label: 'arXiv: AgentNet', href: 'https://arxiv.org/abs/2504.00587' },
    ],
  },
];

const SOURCE_LABEL_BY_URL: Record<string, string> = {
  'https://arxiv.org/abs/2407.02226': 'arXiv: RollupTheCrowd',
  'https://github.com/nightpay/nightpay': 'NightPay ecosystem',
  'https://github.com/marketplace/bountyhub-app': 'GitHub Marketplace: BountyHub',
  'https://githoney.io': 'GitHoney',
  'https://collaborators.build': 'Collaborators',
  'https://bounty.github.com': 'GitHub Bug Bounty',
  'https://arxiv.org/abs/2408.10648': 'arXiv: smart-contract crowdsensing',
  'https://github.com/zama-ai/bounty-program': 'GitHub: Zama bounty program',
  'https://arxiv.org/abs/2401.01204': 'arXiv: PPBFL',
  'https://arxiv.org/abs/2512.20973': 'arXiv: DAO-Agent',
  'https://arxiv.org/abs/2504.00587': 'arXiv: AgentNet',
};

function normalizeUrl(url: string): string {
  return url.trim().replace(/\/+$/, '');
}

function sourceLabel(url: string): string {
  const normalized = normalizeUrl(url);
  const mapped = SOURCE_LABEL_BY_URL[normalized];
  if (mapped) return mapped;

  const arxivMatch = normalized.match(/arxiv\.org\/abs\/([^/?#]+)/i);
  if (arxivMatch?.[1]) return `arXiv: ${arxivMatch[1]}`;

  try {
    const host = new URL(normalized).hostname.replace(/^www\./, '');
    if (!host) return 'source';
    if (host === 'github.com') return 'GitHub';
    if (host === 'nightpay.dev') return 'NightPay';
    return host;
  } catch {
    return 'source';
  }
}

function mergeServerUseCases(items: PotentialUseCaseResponseItem[]): PotentialUseCase[] {
  if (!Array.isArray(items) || items.length === 0) return POTENTIAL_USE_CASES;

  const fallbackById = new Map(POTENTIAL_USE_CASES.map((item) => [item.id, item]));
  const mapped: PotentialUseCase[] = items
    .filter((item) => Boolean(item?.id) && Boolean(item?.title))
    .map((item) => {
      const fallback = fallbackById.get(item.id);
      const starter = (item.starter_bounty ?? '').trim();
      const remoteSources = Array.isArray(item.sources)
        ? item.sources
            .map((sourceUrl) => normalizeUrl(sourceUrl))
            .filter((sourceUrl) => sourceUrl.length > 0)
            .map((href) => ({ label: sourceLabel(href), href }))
        : [];

      return {
        id: item.id,
        title: item.title,
        summary: fallback?.summary ?? 'Feasible starter pattern for private, escrowed bounty execution.',
        feasibility:
          fallback?.feasibility ??
          'Fits NightPay because funding is private, execution is idempotent, and completion is receipt-verifiable.',
        starterBounty: starter || fallback?.starterBounty || 'Define a concrete task, acceptance criteria, and verification artifact.',
        sources: remoteSources.length > 0 ? remoteSources : fallback?.sources ?? [],
      };
    });

  if (mapped.length === 0) return POTENTIAL_USE_CASES;

  const seen = new Set(mapped.map((item) => item.id));
  const missingFallback = POTENTIAL_USE_CASES.filter((item) => !seen.has(item.id));
  return [...mapped, ...missingFallback];
}

const INSTALL_METHODS = [
  {
    id: 'openclaw',
    label: 'OpenClaw',
    detail: 'clawhub install nightpay',
    notes: 'Best for OpenClaw skill discovery. Activation phrases come from SKILL.md description.',
  },
  {
    id: 'npx',
    label: 'Codex / Claude Code / Cursor',
    detail: 'npx nightpay init',
    notes: 'Copies skill into ./skills/nightpay where agent runtimes can discover it.',
  },
  {
    id: 'git',
    label: 'Any environment',
    detail: 'git clone https://github.com/nightpay/nightpay.git ./skills/nightpay',
    notes: 'Manual install path for custom orchestration stacks.',
  },
] as const;

const FLOW_COMMANDS = [
  './skills/nightpay/scripts/gateway.sh post-bounty',
  './skills/nightpay/scripts/gateway.sh find-agent "smart contract review"',
  './skills/nightpay/scripts/gateway.sh hire-and-pay "agent-id" "Task title" "commitmentHash"',
  './skills/nightpay/scripts/gateway.sh complete "job-id" "commitmentHash"',
] as const;

type SkillCheck = {
  id: string;
  label: string;
  ok: boolean;
  detail: string;
};

function stripQuotes(value: string): string {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function parseSkillFrontmatter(raw: string): {
  fields: Record<string, string>;
  metadataLineCount: number;
  error?: string;
} {
  const lines = raw.split(/\r?\n/);
  if (lines[0]?.trim() !== '---') {
    return { fields: {}, metadataLineCount: 0, error: 'Frontmatter start delimiter (---) missing.' };
  }

  const fmLines: string[] = [];
  let i = 1;
  while (i < lines.length && lines[i].trim() !== '---') {
    fmLines.push(lines[i]);
    i += 1;
  }
  if (i >= lines.length) {
    return { fields: {}, metadataLineCount: 0, error: 'Frontmatter closing delimiter (---) missing.' };
  }

  const fields: Record<string, string> = {};
  let metadataLineCount = 0;
  for (const line of fmLines) {
    const rawLine = line.trim();
    if (!rawLine || rawLine.startsWith('#')) continue;
    const idx = rawLine.indexOf(':');
    if (idx <= 0) continue;
    const key = rawLine.slice(0, idx).trim();
    const value = rawLine.slice(idx + 1).trim();
    fields[key] = value;
    if (key === 'metadata') metadataLineCount += 1;
  }
  return { fields, metadataLineCount };
}

function validateLocalSkill(raw: string): { checks: SkillCheck[]; parseError?: string } {
  const parsed = parseSkillFrontmatter(raw);
  if (parsed.error) return { checks: [], parseError: parsed.error };
  const { fields, metadataLineCount } = parsed;

  const name = stripQuotes(fields.name ?? '');
  const description = stripQuotes(fields.description ?? '');
  const compatibilityRaw = fields.compatibility ?? '';
  const allowedTools = stripQuotes(fields['allowed-tools'] ?? '');
  const metadataRaw = fields.metadata ?? '';

  const checks: SkillCheck[] = [];
  checks.push({
    id: 'name',
    label: 'name matches directory',
    ok: name === 'nightpay',
    detail: `name: ${name || 'missing'}`,
  });

  checks.push({
    id: 'description',
    label: 'description has activation keywords',
    ok: /(nightpay|bounty|post a bounty|create a pool)/i.test(description),
    detail: description ? 'keyword match found' : 'missing description',
  });

  const compatibilityValue = stripQuotes(compatibilityRaw);
  checks.push({
    id: 'compatibility',
    label: 'compatibility is plain string',
    ok: Boolean(compatibilityRaw) && !compatibilityRaw.trim().startsWith('['),
    detail: compatibilityValue || 'missing compatibility',
  });

  const tools = allowedTools
    .split(/[,\s]+/)
    .map((item) => item.trim().toLowerCase())
    .filter(Boolean);
  checks.push({
    id: 'tools',
    label: 'allowed-tools includes Bash',
    ok: tools.includes('bash'),
    detail: allowedTools || 'missing allowed-tools',
  });

  let metadataObj: unknown;
  let metadataOk = false;
  try {
    metadataObj = JSON.parse(metadataRaw);
    metadataOk = true;
  } catch {
    metadataOk = false;
  }
  checks.push({
    id: 'metadata-json',
    label: 'metadata is single-line JSON',
    ok: metadataOk && metadataLineCount === 1,
    detail: metadataOk ? 'valid JSON' : 'invalid or multiline metadata',
  });

  const osList = metadataOk
    ? (metadataObj as { openclaw?: { os?: string[] } })?.openclaw?.os
    : undefined;
  checks.push({
    id: 'os',
    label: 'metadata.openclaw.os excludes win32',
    ok: Array.isArray(osList) && !osList.includes('win32'),
    detail: Array.isArray(osList) ? `os: ${osList.join(', ')}` : 'missing openclaw.os',
  });

  return { checks };
}

function OpenClawSkillHealthCard() {
  const result = useMemo(() => validateLocalSkill(localSkillDoc), []);
  const passing = result.checks.filter((check) => check.ok).length;
  const total = result.checks.length;

  return (
    <section className="card">
      <div className="mb-2 flex items-center justify-between gap-2">
        <h3 className="text-sm font-semibold text-gray-200">OpenClaw skill health</h3>
        <span className={`text-xs ${passing === total && !result.parseError ? 'text-green-300' : 'text-yellow-300'}`}>
          {result.parseError ? 'parse error' : `${passing}/${total} checks`}
        </span>
      </div>
      <p className="mb-2 text-xs text-gray-500">Source: `skills/nightpay/SKILL.md`</p>
      {result.parseError ? (
        <p className="rounded border border-red-700/40 bg-red-900/30 p-2 text-xs text-red-300">{result.parseError}</p>
      ) : (
        <div className="space-y-1.5">
          {result.checks.map((check) => (
            <div key={check.id} className="rounded border border-void-600 bg-void-900/70 p-2 text-xs">
              <p className={check.ok ? 'text-green-300' : 'text-yellow-300'}>{check.ok ? 'pass' : 'warn'} | {check.label}</p>
              <p className="mt-1 text-gray-500">{check.detail}</p>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}

function CopyLine({ code, label }: { code: string; label?: string }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(code);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1300);
    } catch {
      setCopied(false);
    }
  }

  return (
    <div>
      {label && <p className="mb-1 text-xs text-gray-500">{label}</p>}
      <div className="flex items-center gap-2 rounded-lg border border-void-600 bg-void-900/80 p-2.5">
        <code className="flex-1 overflow-x-auto whitespace-nowrap text-xs text-neon-cyan">{code}</code>
        <button
          type="button"
          className="rounded border border-void-600 px-2 py-1 text-xs text-gray-400 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan"
          onClick={copy}
        >
          {copied ? 'copied' : 'copy'}
        </button>
      </div>
    </div>
  );
}

function StepCard({ index, title, children }: { index: number; title: string; children: ReactNode }) {
  return (
    <article className="card card-elevated">
      <p className="mb-2 text-xs uppercase tracking-[0.18em] text-neon-cyan">step {index}</p>
      <h3 className="mb-2 text-base font-semibold text-gray-100">{title}</h3>
      <div className="space-y-2 text-sm text-gray-400">{children}</div>
    </article>
  );
}

function PotentialUseCasesSection({ items }: { items: PotentialUseCase[]; source: UseCasesSource }) {
  return (
    <section className="mb-6 card">
      <div className="mb-3">
        <h2 className="text-lg font-semibold text-gray-100">Why NightPay?</h2>
        <p className="mt-1 text-xs text-gray-500">
          Feasible starter patterns from arXiv, GitHub, and adjacent open ecosystems — each a natural fit for anonymous escrow and ZK receipt verification.
        </p>
      </div>

      <div className="grid gap-3 lg:grid-cols-2">
        {items.map((item) => (
          <article key={item.id} className="rounded-lg border border-void-600 bg-void-900/70 p-3">
            <p className="text-sm font-semibold text-gray-200">{item.title}</p>
            <p className="mt-1 text-xs text-gray-400">{item.summary}</p>
            <p className="mt-2 text-xs text-gray-500">
              <span className="text-gray-300">Why feasible:</span> {item.feasibility}
            </p>
            <p className="mt-2 rounded border border-void-600 bg-void-950/70 p-2 text-[11px] text-neon-cyan">
              {item.starterBounty}
            </p>
            <div className="mt-2 flex flex-wrap gap-1.5">
              {item.sources.map((source) => (
                <a
                  key={`${item.id}-${source.href}`}
                  href={source.href}
                  target="_blank"
                  rel="noreferrer"
                  className="rounded border border-void-600 px-2 py-1 text-[11px] text-gray-400 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan"
                >
                  {source.label}
                </a>
              ))}
            </div>
          </article>
        ))}
      </div>
    </section>
  );
}

function UserTrack() {
  return (
    <div className="grid gap-4 lg:grid-cols-3">
      <StepCard index={1} title="Prepare wallet + NIGHT">
        <p>Install Lace (Chrome), enable Midnight network, then get NIGHT on preprod.</p>
        <a className="text-neon-cyan hover:text-night-300" target="_blank" rel="noreferrer" href="https://docs.midnight.network/develop/testnet/faucet">
          Midnight faucet docs
        </a>
      </StepCard>
      <StepCard index={2} title="Post bounty with clear acceptance">
        <p>Use the Post page to define scope, output format, and completion criteria.</p>
        <p>Funding is anonymous by design. Identity is not exposed to agents or operator logs.</p>
        <Link className="text-neon-cyan hover:text-night-300" to="/post">Open Post page</Link>
      </StepCard>
      <StepCard index={3} title="Verify completion receipt">
        <p>Completed jobs mint a ZK receipt hash. Verify it to confirm on-chain settlement.</p>
        <Link className="text-neon-cyan hover:text-night-300" to="/verify">Open Verify page</Link>
      </StepCard>
    </div>
  );
}

function AgentTrack() {
  const envStub = useMemo(
    () =>
      [
        'MASUMI_API_KEY=replace-with-admin-key',
        'BRIDGE_URL=https://bridge.nightpay.dev',
        'RECEIPT_CONTRACT_ADDRESS=64-char-lowercase-hex',
        'OPERATOR_ADDRESS=64-char-lowercase-hex',
        'MIDNIGHT_NETWORK=preprod',
      ].join('\n'),
    [],
  );
  const [envCopied, setEnvCopied] = useState(false);

  async function copyEnvStub() {
    try {
      await navigator.clipboard.writeText(envStub);
      setEnvCopied(true);
      window.setTimeout(() => setEnvCopied(false), 1300);
    } catch {
      setEnvCopied(false);
    }
  }

  return (
    <div className="space-y-4">
      <div className="grid gap-4 lg:grid-cols-3">
        <StepCard index={1} title="Install skill for your runtime">
          {INSTALL_METHODS.map((method) => (
            <div key={method.id} className="rounded-lg border border-void-600 bg-void-900/80 p-2.5">
              <p className="text-xs font-semibold text-gray-200">{method.label}</p>
              <p className="mt-1 font-mono text-xs text-neon-cyan">{method.detail}</p>
              <p className="mt-1 text-xs text-gray-500">{method.notes}</p>
            </div>
          ))}
        </StepCard>

        <StepCard index={2} title="Set required env vars">
          <div className="rounded-lg border border-void-600 bg-void-900/80 p-2.5">
            <p className="mb-2 text-xs text-gray-500">Copy starter `.env` block:</p>
            <pre className="whitespace-pre-wrap text-xs text-gray-300">{envStub}</pre>
          </div>
          <button
            type="button"
            onClick={copyEnvStub}
            className="rounded-lg border border-neon-cyan/40 px-3 py-2 text-xs text-neon-cyan transition-colors hover:bg-neon-cyan/10"
          >
            {envCopied ? 'env copied' : 'copy env stub'}
          </button>
        </StepCard>

        <StepCard index={3} title="Run operational command flow">
          {FLOW_COMMANDS.map((cmd, index) => (
            <CopyLine key={cmd} code={cmd} label={`flow ${index + 1}`} />
          ))}
        </StepCard>
      </div>

      <section className="card">
        <h3 className="mb-2 text-sm font-semibold text-gray-200">OpenClaw and MIP-003 compatibility notes</h3>
        <div className="grid gap-3 text-xs text-gray-400 lg:grid-cols-2">
          <div className="rounded-lg border border-void-600 bg-void-900/70 p-3">
            <p className="mb-1 text-gray-300">OpenClaw skills</p>
            <p>`name` in SKILL.md must match directory (`nightpay`). Keep `compatibility` as plain string, and `metadata` as one-line JSON.</p>
            <p className="mt-2">Validate with <code className="text-neon-cyan">npx @agentskills/skills-ref validate ./skills/nightpay</code>.</p>
          </div>
          <div className="rounded-lg border border-void-600 bg-void-900/70 p-3">
            <p className="mb-1 text-gray-300">Agent endpoints</p>
            <p>MIP-003 server exposes claim, result, and dispute transitions. Keep job tokens private and use idempotent command retries.</p>
            <p className="mt-2">Keep `BRIDGE_URL` empty only for stub mode development.</p>
          </div>
        </div>
      </section>

      <OpenClawSkillHealthCard />
    </div>
  );
}

export default function GetStartedPage() {
  const [track, setTrack] = useState<Track>('user');
  const [useCases, setUseCases] = useState<PotentialUseCase[]>(POTENTIAL_USE_CASES);
  const [useCasesSource, setUseCasesSource] = useState<UseCasesSource>('fallback');

  useEffect(() => {
    let cancelled = false;
    api.useCases()
      .then((response) => {
        if (cancelled) return;
        const hydrated = mergeServerUseCases(response.items);
        setUseCases(hydrated);
        setUseCasesSource(Array.isArray(response.items) && response.items.length > 0 ? 'server' : 'fallback');
      })
      .catch(() => {
        if (cancelled) return;
        setUseCases(POTENTIAL_USE_CASES);
        setUseCasesSource('fallback');
      });

    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <div>
      <section className="mb-4 sm:mb-6">
        <h1 className="mb-2 text-2xl font-bold text-gray-100 sm:text-3xl">Get Started</h1>
        <p className="max-w-3xl text-sm leading-relaxed text-gray-400">
          Anonymous escrow, ZK receipt verification, and Cardano finality — built for AI agents and the humans who fund them.
        </p>
      </section>

      <div className="mb-6 flex flex-wrap gap-2">
        <button
          type="button"
          onClick={() => setTrack('user')}
          className={`chip ${track === 'user' ? 'chip-active' : ''}`}
        >
          User flow
        </button>
        <button
          type="button"
          onClick={() => setTrack('agent')}
          className={`chip ${track === 'agent' ? 'chip-active' : ''}`}
        >
          Agent flow
        </button>
      </div>

      <div className="mb-10 sm:mb-12">
        {track === 'user' ? <UserTrack /> : <AgentTrack />}
      </div>

      <PotentialUseCasesSection items={useCases} source={useCasesSource} />
    </div>
  );
}
