import { useMemo, useState, type DragEvent, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { api, runtimeConfig } from '../api.ts';

/** Bridge URL for copy-paste curl: use env if set, else nightpay.dev in prod, else localhost. */
function bridgeUrlForCurl(): string {
  const base = runtimeConfig.bridgeBase;
  if (base.startsWith('http')) return base.replace(/\/$/, '');
  if (typeof window !== 'undefined' && (window.location.hostname === 'nightpay.dev' || window.location.hostname.endsWith('.nightpay.dev')))
    return 'https://bridge.nightpay.dev';
  return 'http://localhost:4000';
}

/** API URL for copy-paste curl: use env if set, else api.nightpay.dev in prod, else localhost. */
function apiUrlForCurl(): string {
  const base = runtimeConfig.mipBase;
  if (base.startsWith('http')) return base.replace(/\/$/, '');
  if (typeof window !== 'undefined' && (window.location.hostname === 'nightpay.dev' || window.location.hostname.endsWith('.nightpay.dev')))
    return 'https://api.nightpay.dev';
  return 'http://localhost:8090';
}

type State = 'idle' | 'loading' | 'valid' | 'invalid' | 'error';

type ParsedReceipt = {
  hash: string;
  jobId?: string;
  hasProofLikeField: boolean;
};

function extractHash(source: string): ParsedReceipt | null {
  const trimmed = source.trim();
  if (!trimmed) return null;

  if (/^[0-9a-fA-F]{64}$/.test(trimmed)) {
    return { hash: trimmed.toLowerCase(), hasProofLikeField: false };
  }

  try {
    const parsed = JSON.parse(trimmed) as Record<string, unknown>;
    const hashCandidate =
      (typeof parsed.receipt_hash === 'string' && parsed.receipt_hash) ||
      (typeof parsed.receiptHash === 'string' && parsed.receiptHash) ||
      (typeof parsed.output_hash === 'string' && parsed.output_hash) ||
      '';
    const jobId =
      (typeof parsed.job_id === 'string' && parsed.job_id) ||
      (typeof parsed.jobId === 'string' && parsed.jobId) ||
      undefined;
    const hasProofLikeField = Boolean(parsed.proof || parsed.nullifier || parsed.receipt || parsed.receipt_hash);
    if (/^[0-9a-fA-F]{64}$/.test(hashCandidate.trim())) {
      return { hash: hashCandidate.trim().toLowerCase(), jobId, hasProofLikeField };
    }
    return null;
  } catch {
    return null;
  }
}

export default function VerifyPage() {
  const [rawInput, setRawInput] = useState('');
  const [state, setState] = useState<State>('idle');
  const [isStub, setIsStub] = useState(false);
  const [errorMsg, setErrorMsg] = useState('');
  const [dragActive, setDragActive] = useState(false);
  const [copiedCommand, setCopiedCommand] = useState('');

  const parsed = useMemo(() => extractHash(rawInput), [rawInput]);
  const isValidHash = Boolean(parsed?.hash);

  const checklist = useMemo(
    () => ({
      hash: Boolean(parsed?.hash),
      job: Boolean(parsed?.jobId),
      proof: Boolean(parsed?.hasProofLikeField),
    }),
    [parsed],
  );

  async function handleVerify(e: FormEvent) {
    e.preventDefault();
    if (!parsed?.hash) return;

    setState('loading');
    setErrorMsg('');

    try {
      const result = await api.verifyReceipt(parsed.hash);
      setIsStub(result.stub);
      setState(result.valid ? 'valid' : 'invalid');
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : 'Request failed');
      setState('error');
    }
  }

  function handleReset() {
    setRawInput('');
    setState('idle');
    setErrorMsg('');
    setDragActive(false);
  }

  async function onDropFile(e: DragEvent<HTMLDivElement>) {
    e.preventDefault();
    setDragActive(false);
    const file = e.dataTransfer.files?.[0];
    if (!file) return;
    const text = await file.text();
    setRawInput(text);
    setState('idle');
  }

  async function copyCommand(cmd: string, key: string) {
    try {
      await navigator.clipboard.writeText(cmd);
      setCopiedCommand(key);
      window.setTimeout(() => setCopiedCommand(''), 1400);
    } catch {
      setCopiedCommand('');
    }
  }

  async function copyCurl() {
    if (!parsed?.hash) return;
    const cmd = `curl -X POST ${bridgeUrlForCurl()}/verifyReceipt -H "Content-Type: application/json" -d "{\\"receiptHash\\":\\"${parsed.hash}\\"}"`;
    await copyCommand(cmd, 'verify-curl');
  }

  const hashForCommand = parsed?.hash ?? '<receipt_hash>';
  const verifyCliCommand = `bash skills/nightpay/scripts/gateway.sh verify-receipt ${hashForCommand}`;
  const verifyCurlCommand = `curl -sS -X POST "${bridgeUrlForCurl()}/verifyReceipt" -H "Content-Type: application/json" -d '{"receiptHash":"${hashForCommand}"}'`;
  const ontologyCommand = `curl -sS "${apiUrlForCurl()}/ontology" | python3 -m json.tool`;
  const ontologyGuideUrl = 'https://github.com/nightpay/nightpay/blob/master/skills/nightpay/ontology/ontology.md';

  return (
    <div className="max-w-3xl">
      <h1 className="mb-2 text-3xl font-bold text-gray-100">Verify Receipt</h1>
      <p className="mb-6 text-sm text-gray-400">
        Paste a 64-char receipt hash or drop a JSON payload from your agent workflow. Validation confirms settlement without exposing funder identity.
      </p>

      <div className="mb-4 grid gap-3 md:grid-cols-2">
        <section className="rounded-xl border border-void-600 bg-void-900/75 p-4">
          <h2 className="text-sm font-semibold text-gray-100">What this means</h2>
          <p className="mt-2 text-xs text-gray-400">
            Receipt verification answers one question: does this hash map to a completed NightPay settlement record. It does not reveal funder identity or private work data.
          </p>
          <ol className="mt-3 space-y-1 text-xs text-gray-400">
            <li>1. Extract a 64-char receipt hash from raw text or JSON.</li>
            <li>2. Call bridge <code className="text-neon-cyan">/verifyReceipt</code>.</li>
            <li>3. Interpret <code className="text-neon-cyan">valid=true|false</code> as the final check.</li>
          </ol>
        </section>
        <section className="rounded-xl border border-void-600 bg-void-900/75 p-4">
          <h2 className="text-sm font-semibold text-gray-100">Ontology wiring</h2>
          <p className="mt-2 text-xs text-gray-400">
            <code className="text-neon-cyan">Pool -&gt; BountyJob -&gt; Delegation -&gt; Submission -&gt; ReceiptCredential</code>
          </p>
          <p className="mt-2 text-xs text-gray-400">
            Verify reads the final <code className="text-neon-cyan">ReceiptCredential</code> relation and checks the bridge/contract proof path.
          </p>
          <div className="mt-3 flex flex-wrap gap-2 text-xs">
            <a href={`${apiUrlForCurl()}/ontology`} target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">Ontology JSON-LD</a>
            <a href={ontologyGuideUrl} target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">Ontology guide</a>
          </div>
        </section>
      </div>

      <section className="card mb-6 space-y-3 border border-void-700">
        <h2 className="text-sm font-semibold text-gray-100">Quick commands</h2>
        <CommandRow
          label="Gateway CLI verify"
          command={verifyCliCommand}
          onCopy={() => void copyCommand(verifyCliCommand, 'verify-cli')}
          copied={copiedCommand === 'verify-cli'}
        />
        <CommandRow
          label="Bridge API verify"
          command={verifyCurlCommand}
          onCopy={() => void copyCommand(verifyCurlCommand, 'verify-api')}
          copied={copiedCommand === 'verify-api'}
        />
        <CommandRow
          label="Fetch ontology graph"
          command={ontologyCommand}
          onCopy={() => void copyCommand(ontologyCommand, 'ontology')}
          copied={copiedCommand === 'ontology'}
        />
        <div className="flex flex-wrap gap-3 text-xs text-gray-400">
          <Link to="/get-started" className="text-neon-cyan hover:text-night-300">Get Started</Link>
          <Link to="/docs/skill" className="text-neon-cyan hover:text-night-300">Skills</Link>
          <a href="https://github.com/nightpay/nightpay" target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">GitHub</a>
        </div>
      </section>

      <form onSubmit={handleVerify} className="card card-elevated space-y-4">
        <div
          onDrop={onDropFile}
          onDragOver={(e) => {
            e.preventDefault();
            setDragActive(true);
          }}
          onDragLeave={() => setDragActive(false)}
          className={`rounded-xl border p-3 transition-colors ${
            dragActive ? 'border-neon-cyan bg-neon-cyan/10' : 'border-void-600 bg-void-900/70'
          }`}
        >
          <label htmlFor="receipt-input" className="mb-1.5 block text-sm font-medium text-gray-300">
            Receipt hash or JSON payload
          </label>
          <textarea
            id="receipt-input"
            className="input-field min-h-28 font-mono text-xs"
            value={rawInput}
            onChange={(e) => {
              setRawInput(e.target.value);
              setState('idle');
            }}
            placeholder='{"receipt_hash":"<64hex>","job_id":"..."}'
            spellCheck={false}
          />
          <p className="mt-2 text-xs text-gray-500">Drag and drop `.json` here, or paste directly.</p>
        </div>

        <div className="grid gap-2 rounded-lg border border-void-600 bg-void-900/70 p-3 text-xs text-gray-400 sm:grid-cols-3">
          <CheckItem ok={checklist.hash} label="hash format" />
          <CheckItem ok={checklist.job} label="job id present" />
          <CheckItem ok={checklist.proof} label="proof-ish fields" />
        </div>

        {!isValidHash && rawInput.trim().length > 0 && (
          <p className="text-xs text-red-400">Could not extract a valid 64-char receipt hash.</p>
        )}

        <div className="flex flex-wrap items-center gap-2">
          <button type="submit" disabled={!isValidHash || state === 'loading'} className="btn-primary">
            {state === 'loading' ? 'Verifying' : 'Verify Receipt'}
          </button>
          <button
            type="button"
            onClick={copyCurl}
            disabled={!isValidHash}
            className="rounded-lg border border-void-600 px-3 py-2 text-xs text-gray-300 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan disabled:opacity-50"
          >
            {copiedCommand === 'verify-curl' ? 'curl copied' : 'Copy curl verify'}
          </button>
          {state !== 'idle' && (
            <button
              type="button"
              onClick={handleReset}
              className="rounded-lg border border-void-600 px-3 py-2 text-xs text-gray-400 transition-colors hover:text-gray-200"
            >
              Reset
            </button>
          )}
        </div>

        {parsed?.hash && (
          <p className="text-xs text-gray-500">
            extracted hash: <code className="text-neon-cyan">{parsed.hash}</code>
            {parsed.jobId && <> | job: <code className="text-gray-300">{parsed.jobId}</code></>}
          </p>
        )}

        {state === 'valid' && (
          <ResultBox
            title="Receipt is valid"
            text="Settlement and receipt mint were confirmed."
            positive
            stub={isStub}
          />
        )}
        {state === 'invalid' && (
          <ResultBox
            title="Receipt not found"
            text="No matching on-chain receipt was found for this hash."
            positive={false}
            stub={isStub}
          />
        )}
        {state === 'error' && (
          <div className="rounded-lg border border-yellow-700/40 bg-yellow-900/20 p-3">
            <p className="text-sm font-semibold text-yellow-300">Verification unavailable</p>
            <p className="mt-1 text-xs text-yellow-400/80">{errorMsg || 'Try again in a moment.'}</p>
          </div>
        )}
      </form>
    </div>
  );
}

function CommandRow({
  label,
  command,
  onCopy,
  copied,
}: {
  label: string;
  command: string;
  onCopy: () => void;
  copied: boolean;
}) {
  return (
    <div className="rounded-lg border border-void-600 bg-void-900/70 p-3">
      <p className="mb-2 text-[11px] uppercase tracking-widest text-gray-500">{label}</p>
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <code className="block overflow-x-auto rounded bg-void-950 px-2 py-1 text-xs text-neon-cyan">{command}</code>
        <button
          type="button"
          onClick={onCopy}
          className="rounded border border-void-600 px-2 py-1 text-xs text-gray-300 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan"
        >
          {copied ? 'copied' : 'copy'}
        </button>
      </div>
    </div>
  );
}

function CheckItem({ ok, label }: { ok: boolean; label: string }) {
  return (
    <div className="flex items-center gap-2 rounded border border-void-600 bg-void-800/90 px-2 py-1.5">
      <span className={`inline-block h-2 w-2 rounded-full ${ok ? 'bg-green-400' : 'bg-gray-600'}`} />
      <span className={ok ? 'text-gray-200' : 'text-gray-500'}>{label}</span>
    </div>
  );
}

function ResultBox({ title, text, positive, stub }: { title: string; text: string; positive: boolean; stub: boolean }) {
  const colors = positive
    ? 'border-green-700/40 bg-green-900/20 text-green-300'
    : 'border-red-700/40 bg-red-900/20 text-red-300';

  return (
    <div className={`rounded-lg border p-3 ${colors}`}>
      <p className="text-sm font-semibold">{title}</p>
      <p className="mt-1 text-xs opacity-90">{text}</p>
      {stub && <p className="mt-1 text-xs text-yellow-300">Stub mode enabled: no on-chain verification.</p>}
    </div>
  );
}
