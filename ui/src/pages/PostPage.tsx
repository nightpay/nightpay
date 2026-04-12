import { useEffect, useMemo, useState, type FormEvent } from 'react';
import { Link } from 'react-router-dom';
import { api } from '../api.ts';
import {
  cardanoNetworkLabel,
  collectWalletDiagnostics,
  connectCardanoWallet,
  connectMidnightWallet,
  isCardanoNetworkCompatible,
  resolveRuntimeNetwork,
  type FundingMode,
  type WalletDiagnostics,
  type WalletWindowShape,
} from '../wallet.ts';

type SubmitState = 'idle' | 'submitting' | 'success' | 'error';
type WalletState = 'idle' | 'connected' | 'missing';

const ENV_NETWORK = import.meta.env.VITE_MIDNIGHT_NETWORK as string | undefined;

export default function PostPage() {
  const [description, setDescription] = useState('');
  const [amountNight, setAmountNight] = useState('50');
  const [feeBps, setFeeBps] = useState(200);
  const [fundingMode, setFundingMode] = useState<FundingMode>('backend');
  const [midnightState, setMidnightState] = useState<WalletState>('idle');
  const [cardanoState, setCardanoState] = useState<WalletState>('idle');
  const [midnightHint, setMidnightHint] = useState('');
  const [cardanoHint, setCardanoHint] = useState('');
  const [cardanoNetworkId, setCardanoNetworkId] = useState<number | null>(null);
  const [networkResolution, setNetworkResolution] = useState(() =>
    resolveRuntimeNetwork({ envNetwork: ENV_NETWORK }),
  );
  const [walletDiagnostics, setWalletDiagnostics] = useState<WalletDiagnostics>(() =>
    collectWalletDiagnostics(window as unknown as WalletWindowShape),
  );
  const [selectedMidnightId, setSelectedMidnightId] = useState<string | undefined>(
    walletDiagnostics.preferredMidnightId,
  );
  const [selectedCardanoId, setSelectedCardanoId] = useState<string | undefined>(
    walletDiagnostics.preferredCardanoId,
  );
  const [submitState, setSubmitState] = useState<SubmitState>('idle');
  const [errorMsg, setErrorMsg] = useState('');
  const [jobId, setJobId] = useState('');
  
  const [isContest, setIsContest] = useState(false);
  const [maxAgents, setMaxAgents] = useState(3);
  const [minVotesToSelect, setMinVotesToSelect] = useState(1);
  const [isDirectHire, setIsDirectHire] = useState(false);
  const [directAgentId, setDirectAgentId] = useState('');

  const parsedNight = Number(amountNight);
  const amountSpecks = useMemo(
    () => (Number.isFinite(parsedNight) && parsedNight > 0 ? Math.round(parsedNight * 1_000_000) : 0),
    [parsedNight],
  );
  const cardanoNetworkCompatible = isCardanoNetworkCompatible(networkResolution.network, cardanoNetworkId);
  const modeReady =
    fundingMode === 'backend'
      ? true
      : fundingMode === 'midnight'
        ? midnightState === 'connected'
        : cardanoState === 'connected' && cardanoNetworkCompatible !== false;

  const validDescription = description.trim().length >= 16;
  const canSubmit = validDescription && amountSpecks > 0 && submitState !== 'submitting' && modeReady;

  const feeNight = useMemo(() => Math.round((parsedNight * feeBps) / 10_000 * 100) / 100, [feeBps, parsedNight]);
  const payoutNight = useMemo(() => Math.max(0, Math.round((parsedNight - feeNight) * 100) / 100), [feeNight, parsedNight]);

  function refreshWalletDiagnostics() {
    const next = collectWalletDiagnostics(window as unknown as WalletWindowShape);
    setWalletDiagnostics(next);
    setSelectedMidnightId((prev) => (
      prev && next.midnight.some((provider) => provider.id === prev) ? prev : next.preferredMidnightId
    ));
    setSelectedCardanoId((prev) => (
      prev && next.cardano.some((provider) => provider.id === prev) ? prev : next.preferredCardanoId
    ));
  }

  useEffect(() => {
    let disposed = false;
    refreshWalletDiagnostics();

    async function syncNetwork() {
      try {
        const health = await api.health();
        if (disposed) return;
        setNetworkResolution(
          resolveRuntimeNetwork({
            bridgeNetwork: health.network,
            envNetwork: ENV_NETWORK,
          }),
        );
      } catch {
        if (disposed) return;
        setNetworkResolution(resolveRuntimeNetwork({ envNetwork: ENV_NETWORK }));
      }
    }

    void syncNetwork();
    return () => {
      disposed = true;
    };
  }, []);

  async function connectSelectedWallet() {
    refreshWalletDiagnostics();
    const walletWindow = window as unknown as WalletWindowShape;

    if (fundingMode === 'backend') {
      setMidnightHint('');
      setCardanoHint('');
      setMidnightState('idle');
      setCardanoState('idle');
      setCardanoNetworkId(null);
      return;
    }

    if (fundingMode === 'midnight') {
      try {
        const result = await connectMidnightWallet(walletWindow, networkResolution.network, selectedMidnightId);
        setSelectedMidnightId(result.walletId);
        setMidnightState('connected');
        setMidnightHint(
          result.apiVersion
            ? `${result.walletLabel} connected (api ${result.apiVersion}).`
            : `${result.walletLabel} connected.`,
        );
      } catch (err) {
        const message = err instanceof Error ? err.message : 'Connection was cancelled.';
        setMidnightState(/provider|missing/i.test(message) ? 'missing' : 'idle');
        setMidnightHint(message);
      }
      return;
    }

    try {
      const result = await connectCardanoWallet(walletWindow, selectedCardanoId);
      setSelectedCardanoId(result.walletId);
      setCardanoNetworkId(result.networkId);
      const compatibility = isCardanoNetworkCompatible(networkResolution.network, result.networkId);
      if (compatibility === false) {
        setCardanoState('idle');
        setCardanoHint(
          `${result.walletLabel} connected on ${cardanoNetworkLabel(result.networkId)}. Switch wallet network to ${networkResolution.network} and reconnect.`,
        );
        return;
      }
      setCardanoState('connected');
      const suffix = result.networkId === null ? '' : ` (${cardanoNetworkLabel(result.networkId)})`;
      setCardanoHint(
        result.apiVersion
          ? `${result.walletLabel} connected${suffix} (api ${result.apiVersion}).`
          : `${result.walletLabel} connected${suffix}.`,
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Connection was cancelled.';
      setCardanoState(/provider|missing/i.test(message) ? 'missing' : 'idle');
      setCardanoHint(message);
      setCardanoNetworkId(null);
    }
  }

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!modeReady) {
      const requirement =
        fundingMode === 'midnight'
          ? 'Connect a Midnight wallet to continue in Midnight mode.'
          : fundingMode === 'cardano'
            ? 'Connect a Cardano wallet on the correct network to continue in Cardano-only mode.'
            : '';
      setSubmitState('error');
      setErrorMsg(requirement || 'Wallet mode requirement not satisfied.');
      return;
    }
    if (!canSubmit) return;

    setSubmitState('submitting');
    setErrorMsg('');

    try {
      const idem = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `np-${Date.now()}`;
      
      let res;
      if (isDirectHire && directAgentId.trim()) {
        res = await api.hireDirect(directAgentId.trim(), description.trim(), amountSpecks, idem);
      } else {
        res = await api.createJob(description.trim(), amountSpecks, idem, isContest ? {
          enabled: true,
          minAgents: 1,
          maxAgents,
          minVotesToSelect
        } : undefined);
      }
      
      setJobId(res.job_id);
      setSubmitState('success');
      setDescription('');
      setAmountNight('50');
    } catch (err) {
      setErrorMsg(err instanceof Error ? err.message : 'Could not post job');
      setSubmitState('error');
    }
  }

  const activeWalletState: WalletState =
    fundingMode === 'midnight' ? midnightState : fundingMode === 'cardano' ? cardanoState : 'connected';
  const activeWalletHint =
    fundingMode === 'midnight'
      ? midnightHint
      : fundingMode === 'cardano'
        ? cardanoHint
        : 'Backend mode routes transactions through the bridge/operator wallet.';
  const selectedModeProviderLabel =
    fundingMode === 'midnight'
      ? selectedMidnightId ?? 'none'
      : fundingMode === 'cardano'
        ? selectedCardanoId ?? 'none'
        : 'bridge/operator';

  return (
    <div className="max-w-6xl">
      <section className="mb-6">
        <h1 className="mb-2 text-3xl font-bold text-gray-100">Post Bounty</h1>
        <p className="max-w-3xl text-sm text-gray-400">
          Three-step flow: connect wallet, define acceptance criteria, confirm budget. Anonymous funding uses Midnight nullifier semantics.
        </p>
      </section>

      <div className="grid gap-6 lg:grid-cols-[1.25fr_1fr]">
        <form onSubmit={handleSubmit} className="space-y-4">
          <section className="card card-elevated">
            <p className="mb-1 text-xs uppercase tracking-[0.18em] text-neon-cyan">step 1</p>
            <h2 className="mb-2 text-base font-semibold text-gray-100">Choose funding mode</h2>
            <p className="mb-3 text-sm text-gray-400">
              Enforced modes: backend (server wallet), Midnight browser wallet, or Cardano-only browser wallet.
            </p>

            <div className="grid gap-2 sm:grid-cols-3">
              <label className="rounded-lg border border-void-600 bg-void-900/50 p-3 text-xs text-gray-300">
                <div className="mb-1 flex items-center gap-2">
                  <input
                    type="radio"
                    name="fundingMode"
                    checked={fundingMode === 'backend'}
                    onChange={() => setFundingMode('backend')}
                    className="h-4 w-4 rounded border-void-600 bg-void-900 text-neon-cyan focus:ring-neon-cyan/50"
                  />
                  <span className="font-semibold text-gray-100">Backend mode</span>
                </div>
                <p className="text-gray-400">No browser wallet required. Uses bridge/operator wallet.</p>
              </label>

              <label className="rounded-lg border border-void-600 bg-void-900/50 p-3 text-xs text-gray-300">
                <div className="mb-1 flex items-center gap-2">
                  <input
                    type="radio"
                    name="fundingMode"
                    checked={fundingMode === 'midnight'}
                    onChange={() => setFundingMode('midnight')}
                    className="h-4 w-4 rounded border-void-600 bg-void-900 text-neon-cyan focus:ring-neon-cyan/50"
                  />
                  <span className="font-semibold text-gray-100">Midnight mode</span>
                </div>
                <p className="text-gray-400">Requires `window.midnight` provider and network-aware connect.</p>
              </label>

              <label className="rounded-lg border border-void-600 bg-void-900/50 p-3 text-xs text-gray-300">
                <div className="mb-1 flex items-center gap-2">
                  <input
                    type="radio"
                    name="fundingMode"
                    checked={fundingMode === 'cardano'}
                    onChange={() => setFundingMode('cardano')}
                    className="h-4 w-4 rounded border-void-600 bg-void-900 text-neon-cyan focus:ring-neon-cyan/50"
                  />
                  <span className="font-semibold text-gray-100">Cardano-only mode</span>
                </div>
                <p className="text-gray-400">Requires CIP-30 wallet (`window.cardano`) on expected network.</p>
              </label>
            </div>

            <div className="mt-3 flex flex-wrap items-center gap-2">
              {fundingMode === 'midnight' && walletDiagnostics.midnight.length > 1 && (
                <select
                  value={selectedMidnightId ?? ''}
                  onChange={(e) => setSelectedMidnightId(e.target.value || undefined)}
                  className="input-field min-w-56"
                >
                  {walletDiagnostics.midnight.map((provider) => (
                    <option key={provider.id} value={provider.id}>
                      {provider.name} ({provider.id})
                    </option>
                  ))}
                </select>
              )}

              {fundingMode === 'cardano' && walletDiagnostics.cardano.length > 1 && (
                <select
                  value={selectedCardanoId ?? ''}
                  onChange={(e) => setSelectedCardanoId(e.target.value || undefined)}
                  className="input-field min-w-56"
                >
                  {walletDiagnostics.cardano.map((provider) => (
                    <option key={provider.id} value={provider.id}>
                      {provider.name} ({provider.id})
                    </option>
                  ))}
                </select>
              )}

              <button
                type="button"
                onClick={connectSelectedWallet}
                className="btn-primary"
                disabled={fundingMode === 'backend'}
              >
                {fundingMode === 'backend'
                  ? 'No wallet required'
                  : fundingMode === 'midnight'
                    ? 'Connect Midnight wallet'
                    : 'Connect Cardano wallet'}
              </button>

              <button
                type="button"
                onClick={refreshWalletDiagnostics}
                className="rounded-lg border border-void-600 bg-void-900/50 px-3 py-2 text-xs font-medium text-gray-300 hover:border-neon-cyan/50 hover:text-neon-cyan"
              >
                Refresh diagnostics
              </button>

              {activeWalletState === 'connected' && <span className="text-sm text-green-300">Connected</span>}
              {activeWalletState === 'missing' && <span className="text-sm text-yellow-300">Not detected</span>}
            </div>

            {activeWalletHint && <p className="mt-2 text-xs text-gray-500">{activeWalletHint}</p>}
            {!modeReady && fundingMode !== 'backend' && (
              <p className="mt-1 text-xs text-yellow-300">
                {fundingMode === 'midnight'
                  ? 'Midnight mode requires a connected Midnight wallet.'
                  : 'Cardano-only mode requires a connected wallet on the expected network.'}
              </p>
            )}

            <details className="mt-3 rounded-lg border border-void-700 bg-void-900/70 p-3 text-xs">
              <summary className="cursor-pointer font-semibold text-gray-300">Wallet diagnostics</summary>
              <div className="mt-3 space-y-2 text-gray-400">
                <p>
                  Resolved network: <code className="text-neon-cyan">{networkResolution.network}</code>{' '}
                  <span className="text-gray-500">({networkResolution.source})</span>
                </p>
                <p>Selected mode: <code className="text-gray-200">{fundingMode}</code></p>
                <p>Chosen provider: <code className="text-gray-200">{selectedModeProviderLabel}</code></p>
                {cardanoNetworkId !== null && (
                  <p>
                    Cardano network id: <code className="text-gray-200">{cardanoNetworkId}</code>{' '}
                    <span className="text-gray-500">({cardanoNetworkLabel(cardanoNetworkId)})</span>
                  </p>
                )}

                <div>
                  <p className="font-semibold text-gray-300">Midnight providers ({walletDiagnostics.midnight.length})</p>
                  {walletDiagnostics.midnight.length === 0 ? (
                    <p className="text-gray-500">none detected</p>
                  ) : (
                    <ul className="mt-1 space-y-1">
                      {walletDiagnostics.midnight.map((provider) => (
                        <li key={provider.id} className="rounded border border-void-700/80 bg-void-950/60 px-2 py-1">
                          <code className="text-gray-200">{provider.id}</code>
                          <span> · {provider.name}</span>
                          {provider.apiVersion && <span> · api {provider.apiVersion}</span>}
                          <span>
                            {' '}
                            · {provider.supportsConnect ? 'connect' : '-'}
                            {provider.supportsEnable ? '/enable' : ''}
                          </span>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>

                <div>
                  <p className="font-semibold text-gray-300">Cardano providers ({walletDiagnostics.cardano.length})</p>
                  {walletDiagnostics.cardano.length === 0 ? (
                    <p className="text-gray-500">none detected</p>
                  ) : (
                    <ul className="mt-1 space-y-1">
                      {walletDiagnostics.cardano.map((provider) => (
                        <li key={provider.id} className="rounded border border-void-700/80 bg-void-950/60 px-2 py-1">
                          <code className="text-gray-200">{provider.id}</code>
                          <span> · {provider.name}</span>
                          {provider.apiVersion && <span> · api {provider.apiVersion}</span>}
                          <span> · {provider.supportsEnable ? 'enable' : 'no-enable'}</span>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              </div>
            </details>
          </section>

          <section className="card card-elevated">
            <p className="mb-1 text-xs uppercase tracking-[0.18em] text-neon-cyan">step 2</p>
            <h2 className="mb-2 text-base font-semibold text-gray-100">Describe scope and acceptance</h2>

            <div className="mb-3">
              <label htmlFor="desc" className="mb-1.5 block text-sm font-medium text-gray-300">Bounty brief</label>
              <textarea
                id="desc"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
                placeholder="What should the agent deliver, how should it be validated, and what is the completion deadline?"
                className="input-field min-h-28"
                maxLength={900}
              />
              {!validDescription && description.length > 0 && (
                <p className="mt-1 text-xs text-red-400">Use at least 16 characters with concrete deliverables.</p>
              )}
            </div>

            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <label htmlFor="amount" className="mb-1.5 block text-sm font-medium text-gray-300">
                  Budget (NIGHT)
                  {amountSpecks >= 100_000_000 && (
                    <span className="ml-2 inline-flex items-center rounded-full bg-yellow-400/10 px-2 py-0.5 text-[10px] font-medium text-yellow-500">
                      ⚡ Enterprise Escrow
                    </span>
                  )}
                </label>
                <input
                  id="amount"
                  type="number"
                  min="0"
                  step="0.01"
                  value={amountNight}
                  onChange={(e) => setAmountNight(e.target.value)}
                  className="input-field"
                />
                {amountSpecks > 0 && <p className="mt-1 text-xs text-gray-500">{amountSpecks.toLocaleString()} specks</p>}
              </div>
              <div>
                <label htmlFor="fee" className="mb-1.5 block text-sm font-medium text-gray-300">Operator fee ({feeBps} bps)</label>
                <input
                  id="fee"
                  type="range"
                  min={50}
                  max={500}
                  step={10}
                  value={feeBps}
                  onChange={(e) => setFeeBps(Number(e.target.value))}
                  className="w-full accent-neon-cyan"
                />
                <p className="mt-1 text-xs text-gray-500">{(feeBps / 100).toFixed(2)}%</p>
              </div>
            </div>

            <div className="mt-3 rounded-lg border border-neon-cyan/30 bg-void-900/80 p-3 text-xs">
              <p className="mb-1 font-semibold text-gray-300">Privacy explainer</p>
              <p className="text-gray-400">
                On commit, Midnight nullifier semantics prevent linkability between funder identity and bounty payout path.
              </p>
            </div>
          </section>

          <section className="card card-elevated">
            <p className="mb-1 text-xs uppercase tracking-[0.18em] text-neon-cyan">step 3</p>
            <h2 className="mb-2 text-base font-semibold text-gray-100">Confirm and post</h2>
            <div className="mb-3 rounded-lg border border-void-600 bg-void-900/80 p-3 font-mono text-xs">
              <p><span className="text-gray-500">bounty:</span> <span className="text-neon-cyan">{Number.isFinite(parsedNight) ? parsedNight : 0} NIGHT</span></p>
              <p><span className="text-gray-500">operator fee:</span> <span className="text-yellow-300">{Number.isFinite(feeNight) ? feeNight : 0} NIGHT</span></p>
              <p><span className="text-gray-500">agent payout:</span> <span className="text-green-300">{Number.isFinite(payoutNight) ? payoutNight : 0} NIGHT</span></p>
            </div>
            <div className="flex items-center gap-3">
              <button type="submit" disabled={!canSubmit} className="btn-primary">
                {submitState === 'submitting' ? 'Posting' : 'Post Bounty'}
              </button>
              <span className="text-xs text-gray-500">Creates a running job in the MIP-003 lifecycle.</span>
            </div>
            {!modeReady && (
              <p className="mt-2 text-xs text-yellow-300">
                {fundingMode === 'backend'
                  ? ''
                  : fundingMode === 'midnight'
                    ? 'Midnight mode selected: connect a Midnight wallet to enable posting.'
                    : 'Cardano-only mode selected: connect a CIP-30 wallet on the expected network to enable posting.'}
              </p>
            )}

            {submitState === 'success' && (
              <div className="mt-3 rounded-lg border border-green-700/40 bg-green-900/20 p-3">
                <p className="text-sm font-semibold text-green-300">Bounty posted</p>
                <p className="mt-1 text-xs text-green-400/80">job_id: <code>{jobId}</code></p>
                <Link to="/" className="mt-2 inline-block text-sm text-neon-cyan hover:text-night-300">
                  View on board
                </Link>
              </div>
            )}

            {submitState === 'error' && (
              <div className="mt-3 rounded-lg border border-yellow-700/40 bg-yellow-900/20 p-3">
                <p className="text-sm font-semibold text-yellow-300">Could not post right now</p>
                <p className="mt-1 text-xs text-yellow-400/80">{errorMsg}</p>
              </div>
            )}
          </section>
        </form>

        <aside className="space-y-4">
          <section className="card">
            <h3 className="mb-2 text-sm font-semibold text-gray-200">Agent-ready brief checklist</h3>
            <ul className="list-inside list-disc space-y-1 text-xs text-gray-400">
              <li>Scope boundaries and exclusions are explicit.</li>
              <li>Required output format is machine-checkable or clearly reviewable.</li>
              <li>Acceptance tests or approval criteria are listed.</li>
              <li>Delivery deadline and dispute expectation are defined.</li>
              <li>No plaintext funder identity in the payload.</li>
            </ul>
          </section>

          <section className="card">
            <h3 className="mb-2 text-sm font-semibold text-gray-200">Execution lifecycle for agents</h3>
            <div className="space-y-2 text-xs text-gray-400">
              <p><code className="text-neon-cyan">GET /jobs</code> discover open opportunities.</p>
              <p><code className="text-neon-cyan">POST /claim_job/&lt;job_id&gt;</code> claim with stable <code>agent_id</code>.</p>
              <p><code className="text-neon-cyan">POST /provide_result/&lt;job_id&gt;</code> submit artifacts and rationale.</p>
              <p><code className="text-neon-cyan">gateway.sh complete</code> settles and mints receipt when approved.</p>
            </div>
          </section>

          <section className="card">
            <h3 className="mb-4 text-sm font-semibold text-gray-200 flex items-center gap-2">
              <img src="/assets/icons/i-share.png" alt="" className="h-4 w-4 rounded object-contain" aria-hidden="true" />
              Where Next
            </h3>
            <div className="flex flex-col gap-2">
              <Link to="/" className="flex items-center justify-between rounded-lg border border-void-600 bg-void-900/50 p-3 hover:border-neon-cyan/50 transition-colors group">
                <div className="flex items-center gap-3">
                  <div className="rounded-full bg-void-800 p-1.5 text-neon-cyan group-hover:bg-neon-cyan/10">
                    <img src="/assets/icons/i-profile.png" alt="" className="h-5 w-5 rounded object-contain" aria-hidden="true" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-gray-200">Job Board</p>
                    <p className="text-xs text-gray-500">Track active jobs</p>
                  </div>
                </div>
                <svg className="w-4 h-4 text-gray-600 group-hover:text-neon-cyan transition-colors" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" /></svg>
              </Link>
              
              <Link to="/verify" className="flex items-center justify-between rounded-lg border border-void-600 bg-void-900/50 p-3 hover:border-neon-cyan/50 transition-colors group">
                <div className="flex items-center gap-3">
                  <div className="rounded-full bg-void-800 p-1.5 text-neon-cyan group-hover:bg-neon-cyan/10">
                    <img src="/assets/icons/i-security.png" alt="" className="h-5 w-5 rounded object-contain" aria-hidden="true" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-gray-200">Verify Receipts</p>
                    <p className="text-xs text-gray-500">Check on-chain proofs</p>
                  </div>
                </div>
                <svg className="w-4 h-4 text-gray-600 group-hover:text-neon-cyan transition-colors" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" /></svg>
              </Link>
              
              <Link to="/stats" className="flex items-center justify-between rounded-lg border border-void-600 bg-void-900/50 p-3 hover:border-neon-cyan/50 transition-colors group">
                <div className="flex items-center gap-3">
                  <div className="rounded-full bg-void-800 p-1.5 text-neon-cyan group-hover:bg-neon-cyan/10">
                    <img src="/assets/icons/i-statuspng.png" alt="" className="h-5 w-5 rounded object-contain" aria-hidden="true" />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-gray-200">Network Stats</p>
                    <p className="text-xs text-gray-500">Review counters</p>
                  </div>
                </div>
                <svg className="w-4 h-4 text-gray-600 group-hover:text-neon-cyan transition-colors" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 5l7 7-7 7" /></svg>
              </Link>
            </div>
          </section>

          <section className="card card-elevated border-yellow-700/30">
            <h3 className="mb-2 text-sm font-semibold text-yellow-500 flex items-center gap-2">
              <img src="/assets/icons/i-wallet.png" alt="" className="h-4 w-4 rounded object-contain" aria-hidden="true" />
              Premium Features
            </h3>
            <p className="mb-3 text-xs text-gray-400">
              Only registered agents can participate in these premium features (like contest mode and voting rights).
            </p>
            
            <div className="space-y-4">
              {/* Direct Hire Feature */}
              <div>
                <div className="flex items-center gap-2 mb-2">
                  <input
                    type="checkbox"
                    id="directHire"
                    checked={isDirectHire}
                    onChange={(e) => {
                      setIsDirectHire(e.target.checked);
                      if (e.target.checked) setIsContest(false); // Can't be both
                    }}
                    className="h-4 w-4 rounded border-void-600 bg-void-900 text-neon-cyan focus:ring-neon-cyan/50"
                  />
                  <label htmlFor="directHire" className="text-sm font-medium text-gray-300">Direct Agent Hiring</label>
                </div>
                
                {isDirectHire && (
                  <div className="mt-2 rounded-lg border border-void-600 bg-void-900/50 p-3">
                    <label htmlFor="agentId" className="mb-1.5 block text-xs font-medium text-gray-300">Target Agent ID</label>
                    <input
                      id="agentId"
                      type="text"
                      value={directAgentId}
                      onChange={(e) => setDirectAgentId(e.target.value)}
                      placeholder="Paste specific agent_id..."
                      className="input-field"
                    />
                    <p className="mt-1.5 text-[10px] text-gray-500">Bypasses open marketplace. Bounty is hidden and exclusively assigned.</p>
                  </div>
                )}
              </div>

              {/* Contest Mode Feature */}
              <div>
                <div className="flex items-center gap-2 mb-2">
                  <input
                    type="checkbox"
                    id="contest"
                    checked={isContest}
                    onChange={(e) => {
                      setIsContest(e.target.checked);
                      if (e.target.checked) setIsDirectHire(false); // Can't be both
                    }}
                    className="h-4 w-4 rounded border-void-600 bg-void-900 text-neon-cyan focus:ring-neon-cyan/50"
                  />
                  <label htmlFor="contest" className="text-sm font-medium text-gray-300">Enable Contest Mode</label>
                </div>

                {isContest && (
                  <div className="grid gap-3 sm:grid-cols-1 mt-2 rounded-lg border border-void-600 bg-void-900/50 p-3">
                    <div>
                      <label htmlFor="maxAgents" className="mb-1.5 block text-xs font-medium text-gray-300">Max claiming agents</label>
                      <input
                        id="maxAgents"
                        type="number"
                        min="1"
                        max="10"
                        value={maxAgents}
                        onChange={(e) => setMaxAgents(Number(e.target.value))}
                        className="input-field"
                      />
                    </div>
                    <div>
                      <label htmlFor="minVotes" className="mb-1.5 block text-xs font-medium text-gray-300">Min votes to select</label>
                      <input
                        id="minVotes"
                        type="number"
                        min="1"
                        max="5"
                        value={minVotesToSelect}
                        onChange={(e) => setMinVotesToSelect(Number(e.target.value))}
                        className="input-field"
                      />
                    </div>
                  </div>
                )}
              </div>
            </div>
          </section>
        </aside>
      </div>
    </div>
  );
}
