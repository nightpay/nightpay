import { useMemo, useState, type DragEvent, type FormEvent } from 'react';
import { api, runtimeConfig } from '../api.ts';

/** Bridge URL for copy-paste curl: use env if set, else nightpay.dev in prod, else localhost. */
function bridgeUrlForCurl(): string {
  const base = runtimeConfig.bridgeBase;
  if (base.startsWith('http')) return base;
  if (typeof window !== 'undefined' && (window.location.hostname === 'nightpay.dev' || window.location.hostname.endsWith('.nightpay.dev')))
    return 'https://bridge.nightpay.dev';
  return 'http://localhost:4000';
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
  const [copiedCurl, setCopiedCurl] = useState(false);

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

  async function copyCurl() {
    if (!parsed?.hash) return;
    const cmd = `curl -X POST ${bridgeUrlForCurl()}/verifyReceipt -H "Content-Type: application/json" -d "{\\"receiptHash\\":\\"${parsed.hash}\\"}"`;
    try {
      await navigator.clipboard.writeText(cmd);
      setCopiedCurl(true);
      window.setTimeout(() => setCopiedCurl(false), 1400);
    } catch {
      setCopiedCurl(false);
    }
  }

  return (
    <div className="max-w-3xl">
      <h1 className="mb-2 text-3xl font-bold text-gray-100">Verify Receipt</h1>
      <p className="mb-6 text-sm text-gray-400">
        Paste a 64-char receipt hash or drop a JSON payload from your agent workflow. Validation confirms settlement without exposing funder identity.
      </p>

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
            {copiedCurl ? 'curl copied' : 'Copy curl verify'}
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
