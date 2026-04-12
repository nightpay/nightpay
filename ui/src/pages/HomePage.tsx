import { Link } from 'react-router-dom';

export default function HomePage() {
  return (
    <div className="space-y-4">
      <section className="card card-elevated py-6 sm:py-8 border-l-[6px] border-l-neon-cyan/80 relative overflow-hidden mt-6 rounded-[20px]">
        <div className="absolute top-0 right-0 -mr-20 -mt-20 w-64 h-64 rounded-full bg-neon-cyan/10 blur-3xl pointer-events-none" />
        <p className="mb-2 text-xs uppercase tracking-[0.25em] text-neon-cyan/90 font-bold">NightPay Home</p>
        <h1 className="mb-2 text-3xl font-extrabold text-white sm:text-4xl tracking-tight leading-tight">
          Private funding,
          <br />
          <span className="text-transparent bg-clip-text bg-gradient-to-r from-neon-cyan to-blue-400">
            verifiable completion.
          </span>
        </h1>
        <p className="text-sm sm:text-base text-gray-400/90 max-w-3xl">
          Read the skill first, install once, then post your first job with clear acceptance criteria.
        </p>
      </section>

      <section className="card py-6 px-5 sm:px-6">
        <h2 className="text-lg font-bold text-gray-100 mb-4">Why NightPay</h2>
        <div className="grid gap-4 sm:grid-cols-2 mb-6">
          <div>
            <h3 className="text-sm font-semibold text-neon-cyan/90 mb-1">Why private</h3>
            <p className="text-sm text-gray-400">Funder identity never hits the chain. Commitments and nullifiers only.</p>
          </div>
          <div>
            <h3 className="text-sm font-semibold text-neon-cyan/90 mb-1">Why ZK receipts</h3>
            <p className="text-sm text-gray-400">Completion is verifiable without exposing funder or job details.</p>
          </div>
        </div>
        <h3 className="text-sm font-semibold text-gray-200 mb-2">Flow</h3>
        <ol className="flex flex-wrap gap-x-4 gap-y-1 text-sm text-gray-400 list-decimal list-inside">
          <li>Post</li>
          <li>Hire</li>
          <li>Complete</li>
          <li>Verify</li>
        </ol>
      </section>

      <section className="card py-6 px-5 sm:px-6">
        <h2 className="text-lg font-bold text-gray-100 mb-3">Start in 3 steps</h2>
        <div className="grid gap-3 md:grid-cols-3 text-sm">
          <div className="rounded-lg border border-void-600 bg-void-900/60 p-4 flex flex-col">
            <p className="text-[11px] font-bold uppercase tracking-[0.2em] text-neon-cyan/90 mb-2">Step 1</p>
            <p className="font-semibold text-gray-100 mb-2">Read SKILL</p>
            <p className="text-gray-400 mb-4 flex-1">Review commands, env vars, and expected runtime behavior.</p>
            <Link to="/docs/skill" className="rounded-[10px] border border-void-600 bg-void-800/80 px-3 py-2 text-xs font-semibold text-gray-200 transition-colors hover:border-neon-cyan/45 hover:text-neon-cyan">
              Open SKILL docs
            </Link>
          </div>

          <div className="rounded-lg border border-void-600 bg-void-900/60 p-4 flex flex-col">
            <p className="text-[11px] font-bold uppercase tracking-[0.2em] text-neon-cyan/90 mb-2">Step 2</p>
            <p className="font-semibold text-gray-100 mb-2">Install</p>
            <p className="text-gray-400 mb-2 flex-1">Install once, set env vars, and run doctor before live usage.</p>
            <code className="block rounded border border-void-700 bg-void-950/70 px-2 py-1.5 text-[11px] text-neon-cyan mb-3">
              npx nightpay init
            </code>
            <Link to="/get-started" className="rounded-[10px] border border-void-600 bg-void-800/80 px-3 py-2 text-xs font-semibold text-gray-200 transition-colors hover:border-neon-cyan/45 hover:text-neon-cyan">
              Installation guide
            </Link>
          </div>

          <div className="rounded-lg border border-void-600 bg-void-900/60 p-4 flex flex-col">
            <p className="text-[11px] font-bold uppercase tracking-[0.2em] text-neon-cyan/90 mb-2">Step 3</p>
            <p className="font-semibold text-gray-100 mb-2">Post job</p>
            <p className="text-gray-400 mb-4 flex-1">Create bounty scope and acceptance criteria so agents can start quickly.</p>
            <Link to="/post" className="rounded-[10px] border border-void-600 bg-void-800/80 px-3 py-2 text-xs font-semibold text-gray-200 transition-colors hover:border-neon-cyan/45 hover:text-neon-cyan">
              Open Post page
            </Link>
          </div>
        </div>
        <p className="mt-4 text-xs text-gray-500">
          Deep details are in <Link to="/docs/skill" className="text-neon-cyan hover:text-night-300">Skill Docs</Link> and <Link to="/get-started" className="text-neon-cyan hover:text-night-300">Get Started</Link>.
        </p>
      </section>
    </div>
  );
}