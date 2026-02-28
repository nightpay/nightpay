import { useState } from 'react';
import { Link } from 'react-router-dom';
import { type Bounty, formatNight, truncateHash, timeAgo } from '../api.ts';

const STATUS: Record<Bounty['status'], { badge: string; label: string; dot: string }> = {
  open:      { badge: 'badge-open',      label: 'Open',        dot: 'bg-blue-400'  },
  funded:    { badge: 'badge-funded',    label: 'In Progress', dot: 'bg-yellow-400' },
  completed: { badge: 'badge-completed', label: 'Completed',   dot: 'bg-green-400' },
  disputed:  { badge: 'badge-disputed',  label: 'Disputed',    dot: 'bg-red-400'   },
};

interface Props {
  bounty: Bounty;
  compact?: boolean;
  onClaim?: (jobId: string) => void;
  claimBusy?: boolean;
  isMyClaim?: boolean;
}

export default function BountyCard({
  bounty,
  compact = false,
  onClaim,
  claimBusy = false,
  isMyClaim = false,
}: Props) {
  const [copied, setCopied] = useState(false);
  const [copyFailed, setCopyFailed] = useState(false);
  const s = STATUS[bounty.status];
  const totalVotes = Math.max(0, bounty.approveVotes + bounty.rejectVotes);
  
  const timeline = [
    { id: 'open', label: 'posted', title: 'Funded and available for claim' },
    { id: 'funded', label: 'claimed', title: 'An agent is assigned and working on it' },
    { id: 'submitted', label: 'submitted', title: 'Result submitted to Masumi gateway' },
    { id: 'completed', label: 'settled', title: 'Payment finalized on Midnight network' },
  ] as const;
  
  const currentStep = bounty.status === 'open' ? 0 : bounty.status === 'funded' ? 1 : bounty.status === 'completed' ? 3 : 2;
  const claimedLabel = bounty.claimsCount === 0
    ? 'unclaimed'
    : bounty.assignedAgentId
      ? `lead ${truncateHash(bounty.assignedAgentId, 6)}${bounty.claimsCount > 1 ? ` (+${bounty.claimsCount - 1})` : ''}`
      : `${bounty.claimsCount} agents claimed`;
  const description = bounty.description.replace(/\s+/g, ' ').trim();
  const compactDescription = description.length > 120 ? `${description.slice(0, 120).trim()}...` : description;

  async function copyReceipt() {
    if (!bounty.receiptHash) return;
    if (!navigator.clipboard?.writeText) {
      setCopyFailed(true);
      setTimeout(() => setCopyFailed(false), 1800);
      return;
    }
    try {
      await navigator.clipboard.writeText(bounty.receiptHash);
      setCopied(true);
      setCopyFailed(false);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
      setCopyFailed(true);
      setTimeout(() => setCopyFailed(false), 1800);
    }
  }

  return (
    <article className={`card card-elevated group relative ${compact ? 'p-4 sm:p-5' : 'p-5 sm:p-6'} transition-all duration-300 hover:-translate-y-[2px] hover:shadow-[0_15px_30px_-5px_rgba(0,0,0,0.6),0_0_20px_rgba(94,242,255,0.15)] ${isMyClaim ? 'ring-1 ring-neon-cyan/70 shadow-[0_0_15px_rgba(94,242,255,0.1)]' : ''}`}>
      {isMyClaim && (
        <span className="absolute -top-2.5 -right-2.5 bg-neon-cyan text-void-900 text-[10px] font-bold px-2 py-0.5 rounded-full shadow-neon-dot z-10 pointer-events-none">
          My Claim
        </span>
      )}
      
      <div className="mb-4 flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <p className="mb-1.5 text-[10px] font-bold uppercase tracking-widest text-gray-500 flex items-center gap-1.5">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className="text-gray-600"><rect x="2" y="7" width="20" height="14" rx="2" ry="2"></rect><path d="M16 21V5a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"></path></svg>
            job {truncateHash(bounty.id, 5)}
          </p>
          <h2 className={`${compact ? 'text-[15px]' : 'text-[17px]'} truncate font-bold leading-snug text-gray-100 group-hover:text-white transition-colors`} title={bounty.title}>{bounty.title}</h2>
          <p className="mt-1.5 text-[11px] font-medium text-gray-500 flex items-center gap-1.5">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className="text-gray-600"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
            {timeAgo(bounty.createdAt)}
          </p>
        </div>
        <span className={`${s.badge} shrink-0 shadow-sm mt-0.5`}>{s.label}</span>
      </div>

      <p 
        title={compact ? bounty.description : undefined}
        className={`${compact ? 'mb-4 min-h-0 text-[13px] cursor-help' : 'mb-5 min-h-24 text-[14px]'} whitespace-pre-wrap break-words leading-relaxed text-gray-400 group-hover:text-gray-300 transition-colors`}
      >
        {compact ? compactDescription : bounty.description}
      </p>

      <div className={`grid gap-2 rounded-[14px] border border-void-700/60 bg-void-800/40 text-xs text-gray-400 shadow-inner ${compact ? 'p-3 sm:grid-cols-3' : 'p-4 sm:grid-cols-3'}`}>
        <div className="flex flex-col gap-1.5 border-r border-void-700/40 pr-4">
          <p className="text-[10px] uppercase tracking-widest text-gray-500 font-bold flex items-center gap-1">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="text-neon-cyan/70"><line x1="12" y1="1" x2="12" y2="23"></line><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"></path></svg>
            budget
          </p>
          <p className="font-bold text-neon-cyan text-[15px]">{formatNight(bounty.amountSpecks)}</p>
        </div>
        <div className="flex flex-col gap-1.5 border-r border-void-700/40 px-2 sm:px-4">
          <p className="text-[10px] uppercase tracking-widest text-gray-500 font-bold flex items-center gap-1">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="text-gray-400"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path><circle cx="9" cy="7" r="4"></circle><path d="M23 21v-2a4 4 0 0 0-3-3.87"></path><path d="M16 3.13a4 4 0 0 1 0 7.75"></path></svg>
            claims
          </p>
          <p className="font-semibold text-gray-200 text-[13px]">{claimedLabel}</p>
        </div>
        <div className="flex flex-col gap-1.5 pl-2 sm:pl-4">
          <p className="text-[10px] uppercase tracking-widest text-gray-500 font-bold flex items-center gap-1">
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" className="text-gray-400"><path d="M14 9V5a3 3 0 0 0-3-3l-4 9v11h11.28a2 2 0 0 0 2-1.7l1.38-9a2 2 0 0 0-2-2.3zM7 22H4a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2h3"></path></svg>
            votes
          </p>
          <p className="font-semibold text-gray-200 text-[13px]">{totalVotes}</p>
        </div>
      </div>

      {!compact && (
        <div className="mt-4 rounded-xl border border-void-700 bg-void-800/40 p-4 shadow-inner">
          <p className="mb-3 text-[10px] font-medium uppercase tracking-widest text-gray-500">timeline</p>
          <div className="grid grid-cols-4 gap-2">
            {timeline.map((step, idx) => {
              const active = idx <= currentStep;
              const isCurrent = idx === currentStep;
              return (
                <div key={step.id} className="text-center group/step" title={step.title}>
                  <span
                    className={`mb-2 inline-block h-2 w-full rounded-full cursor-help transition-all duration-300 ${
                      active ? 'bg-neon-cyan/90 shadow-[0_0_8px_rgba(94,242,255,0.4)]' : 'bg-void-700'
                    } ${isCurrent ? 'h-2.5 shadow-[0_0_12px_rgba(94,242,255,0.8)]' : 'group-hover/step:h-2.5'}`}
                  />
                  <p className={`text-[10px] uppercase tracking-wider font-medium transition-colors ${active ? 'text-neon-cyan' : 'text-gray-500'}`}>{step.label}</p>
                </div>
              );
            })}
          </div>
        </div>
      )}

      <div className="mt-5 flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2.5">
          <span
            title="Funded anonymously via Midnight ZK — funder identity destroyed"
            className="cursor-help select-none rounded-md border border-neon-cyan/20 bg-neon-cyan/5 px-2 py-1 text-[10px] font-bold tracking-wider text-gray-400 transition-colors hover:border-neon-cyan/50 hover:bg-neon-cyan/10 hover:text-gray-200 uppercase"
          >
            ZK Funded
          </span>
          <span className={`inline-block h-2.5 w-2.5 rounded-full ${s.dot} shadow-[0_0_10px_currentColor] opacity-90`} />
          <span className="text-[11px] font-bold uppercase tracking-widest text-gray-400">{s.label}</span>
        </div>
        <Link to={`/verify`} className="text-[11px] font-bold uppercase tracking-wider text-night-300 transition-colors hover:text-neon-cyan flex items-center gap-1 group/link bg-void-800/50 px-2.5 py-1.5 rounded-md border border-void-700 hover:border-neon-cyan/30">
          Track
          <svg className="w-3.5 h-3.5 transform group-hover/link:translate-x-0.5 transition-transform" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"></polyline></svg>
        </Link>
      </div>

      {totalVotes > 0 && bounty.status !== 'completed' && (
        <div className="mt-3 text-xs text-gray-500">
          review: <span className="text-green-400">{bounty.approveVotes} approve</span> /
          {' '}
          <span className="text-red-400">{bounty.rejectVotes} reject</span>
        </div>
      )}

      {(bounty.status === 'open' || bounty.status === 'funded') && onClaim && (
        <div className="mt-5 border-t border-void-700/80 pt-4">
          <button
            type="button"
            onClick={() => onClaim(bounty.id)}
            disabled={claimBusy}
            className="btn-primary w-full sm:w-auto disabled:opacity-50 disabled:cursor-not-allowed text-sm h-[42px] px-6 font-bold tracking-wide"
          >
            {claimBusy ? 'Claiming...' : bounty.status === 'open' ? 'Claim Job' : 'Join Claim'}
          </button>
        </div>
      )}

      {bounty.receiptHash && (
        <div className="mt-5 border-t border-void-700/80 pt-4">
          <div className="flex items-center gap-3 bg-void-800/80 p-2.5 rounded-lg border border-void-700">
            <span className="text-green-400 text-xs font-bold flex items-center gap-1.5 shrink-0">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg>
              ZK Receipt
            </span>
            <span className="mono flex-1 truncate text-gray-300" title={bounty.receiptHash}>
              {truncateHash(bounty.receiptHash)}
            </span>
            <button
              onClick={copyReceipt}
              title={copied ? "Copied!" : "Copy receipt hash"}
              className={`p-2 rounded-md transition-all focus:outline-none shrink-0 ${copied ? 'text-green-400 bg-green-400/10 shadow-[inset_0_0_0_1px_rgba(74,222,128,0.2)]' : copyFailed ? 'text-red-400 bg-red-400/10 shadow-[inset_0_0_0_1px_rgba(248,113,113,0.2)]' : 'text-gray-400 hover:text-neon-cyan hover:bg-void-700 hover:shadow-[inset_0_0_0_1px_rgba(94,242,255,0.2)] bg-void-900'}`}
            >
              {copied ? (
                <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2.5"><path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" /></svg>
              ) : copyFailed ? (
                <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2.5"><path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" /></svg>
              ) : (
                <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2"><path strokeLinecap="round" strokeLinejoin="round" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z" /></svg>
              )}
            </button>
          </div>
          {!compact && (
            <p className="text-[11px] text-gray-500 mt-2.5 flex items-center justify-center gap-1.5">
              Paste in{' '}
              <Link to="/verify" className="text-neon-cyan font-medium transition-colors hover:text-white hover:underline underline-offset-2">
                Verify tab
              </Link>{' '}
              to confirm on-chain.
            </p>
          )}
        </div>
      )}
    </article>
  );
}