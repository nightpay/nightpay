import { FormEvent, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, runtimeConfig, type ManagementChatResponse, type ManagementMode } from '../api.ts';
import { toast } from '../utils/toast.ts';

type ChatMessage = {
  id: string;
  role: 'assistant' | 'user';
  content: string;
  data?: ManagementChatResponse;
};

const MODES: Array<{ value: ManagementMode; label: string }> = [
  { value: 'general', label: 'General' },
  { value: 'onboarding', label: 'Onboarding' },
  { value: 'troubleshooting', label: 'Troubleshoot' },
  { value: 'deploy', label: 'Deploy' },
  { value: 'security', label: 'Security' },
];

const QUICK_PROMPTS = [
  'How do I onboard a new external worker agent?',
  'How do I navigate the site using the Knowledge Graph?',
  'How should I route nightpay.dev + api + bridge + docs + ceo in Caddy?',
  'What is the fastest onboarding sequence for a new operator?',
  'A job is stuck in multisig_pending. What should I check first?',
  'What secrets must never be logged or committed?',
];

function makeId(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function apiUrlForCurl(): string {
  const base = runtimeConfig.mipBase;
  if (base.startsWith('http')) return base.replace(/\/$/, '');
  if (typeof window !== 'undefined' && (window.location.hostname === 'nightpay.dev' || window.location.hostname.endsWith('.nightpay.dev')))
    return 'https://api.nightpay.dev';
  return 'http://localhost:8090';
}

export default function CeoPage() {
  const [mode, setMode] = useState<ManagementMode>('general');
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [copiedCommand, setCopiedCommand] = useState('');
  const [messages, setMessages] = useState<ChatMessage[]>([
    {
      id: makeId('assistant'),
      role: 'assistant',
      content:
        'NightPay CEO assistant online. Ask about onboarding external agents, operator deploy, DNS/Caddy, refunds, disputes, or bridge troubleshooting.',
    },
  ]);

  const history = useMemo(
    () =>
      messages.map((m) => ({
        role: m.role,
        content: m.content,
      })),
    [messages],
  );

  async function submitPrompt(raw: string) {
    const prompt = raw.trim();
    if (!prompt || busy) return;

    const userMessage: ChatMessage = { id: makeId('user'), role: 'user', content: prompt };
    setMessages((prev) => [...prev, userMessage]);
    setInput('');
    setBusy(true);

    try {
      const response = await api.managementChat(prompt, { mode, history });
      const assistantMessage: ChatMessage = {
        id: makeId('assistant'),
        role: 'assistant',
        content: response.reply,
        data: response,
      };
      setMessages((prev) => [...prev, assistantMessage]);
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Failed to contact management assistant';
      toast.error(message);
      setMessages((prev) => [
        ...prev,
        {
          id: makeId('assistant'),
          role: 'assistant',
          content: `Request failed: ${message}`,
        },
      ]);
    } finally {
      setBusy(false);
    }
  }

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void submitPrompt(input);
  }

  async function copyCommand(command?: string, key?: string) {
    if (!command) return;
    try {
      await navigator.clipboard.writeText(command);
      if (key) {
        setCopiedCommand(key);
        window.setTimeout(() => setCopiedCommand(''), 1400);
      }
      toast.success('Command copied');
    } catch {
      toast.error('Clipboard unavailable');
    }
  }

  const commands = [
    {
      id: 'stats',
      title: 'Gateway + bridge status',
      command: 'bash skills/nightpay/scripts/gateway.sh stats',
    },
    {
      id: 'find-agent',
      title: 'Find an external worker agent',
      command: 'bash skills/nightpay/scripts/gateway.sh find-agent "smart contract audit"',
    },
    {
      id: 'management-chat',
      title: 'Call management assistant API directly',
      command: `curl -sS -X POST "${apiUrlForCurl()}/management/chat" -H "Content-Type: application/json" -d '{"message":"How do I recover a stuck job?","mode":"troubleshooting"}'`,
    },
    {
      id: 'ontology',
      title: 'Inspect ontology graph',
      command: `curl -sS "${apiUrlForCurl()}/ontology" | python3 -m json.tool`,
    },
  ];

  return (
    <section className="space-y-4">
      <header className="card card-elevated">
        <p className="text-xs uppercase tracking-[0.2em] text-neon-cyan">CEO Support Channel</p>
        <h1 className="mt-2 text-2xl font-semibold text-white sm:text-3xl">Management Assistant</h1>
        <p className="mt-2 text-sm text-gray-300">
          This assistant is focused on operator onboarding, external agent setup, and troubleshooting. It returns direct actions and commands.
        </p>
        <div className="mt-4 grid gap-3 md:grid-cols-2">
          <div className="rounded-lg border border-void-600 bg-void-900/70 p-3">
            <p className="text-xs font-semibold uppercase tracking-wider text-gray-300">What manage means</p>
            <p className="mt-2 text-xs text-gray-400">
              Management is the operator control loop: discover agents, assign and monitor jobs, resolve disputes, and finalize payout conditions.
            </p>
            <ol className="mt-2 space-y-1 text-xs text-gray-400">
              <li>1. Ask a management question in this chat.</li>
              <li>2. Run returned commands in terminal/API.</li>
              <li>3. Verify status and receipt state from Board/Verify.</li>
            </ol>
          </div>
          <div className="rounded-lg border border-void-600 bg-void-900/70 p-3">
            <p className="text-xs font-semibold uppercase tracking-wider text-gray-300">Ontology map</p>
            <p className="mt-2 text-xs text-gray-400">
              <code className="text-neon-cyan">Pool -&gt; BountyJob -&gt; Delegation -&gt; Submission -&gt; VotingSession -&gt; ReceiptCredential</code>
            </p>
            <p className="mt-2 text-xs text-gray-400">
              Every management decision should move one node in this graph without breaking identity/privacy boundaries.
            </p>
            <div className="mt-2 flex flex-wrap gap-3 text-xs">
              <a href={`${apiUrlForCurl()}/ontology`} target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">Ontology JSON-LD</a>
              <a href="https://github.com/nightpay/nightpay/blob/master/skills/nightpay/ontology/ontology.md" target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">Ontology guide</a>
            </div>
          </div>
        </div>
        <div className="mt-3 flex flex-wrap gap-3 text-xs">
          <Link to="/get-started" className="text-neon-cyan hover:text-night-300">Get Started</Link>
          <Link to="/docs/skill" className="text-neon-cyan hover:text-night-300">Skills</Link>
          <a href="https://github.com/nightpay/nightpay" target="_blank" rel="noopener noreferrer" className="text-neon-cyan hover:text-night-300">GitHub</a>
        </div>

        <div className="mt-4 flex flex-wrap items-center gap-2">
          <label htmlFor="ceo-mode" className="text-xs text-gray-400">Mode</label>
          <select
            id="ceo-mode"
            className="rounded-lg border border-void-600 bg-void-800 px-3 py-1.5 text-sm text-gray-200 focus:outline-none focus:ring-1 focus:ring-neon-cyan"
            value={mode}
            onChange={(event) => setMode(event.target.value as ManagementMode)}
          >
            {MODES.map((item) => (
              <option key={item.value} value={item.value}>{item.label}</option>
            ))}
          </select>
        </div>
      </header>

      <div className="grid gap-4 lg:grid-cols-[2fr_1fr]">
        <div className="card card-elevated space-y-3">
          <div className="max-h-[60vh] space-y-3 overflow-y-auto pr-1">
            {messages.map((message) => (
              <article
                key={message.id}
                className={`rounded-xl border p-3 ${message.role === 'assistant' ? 'border-neon-cyan/35 bg-void-800/90' : 'border-void-600 bg-void-900/75'}`}
              >
                <p className="mb-2 text-xs uppercase tracking-[0.15em] text-gray-400">
                  {message.role === 'assistant' ? 'CEO assistant' : 'You'}
                </p>
                <p className="whitespace-pre-wrap text-sm text-gray-100">{message.content}</p>
                {message.data && (
                  <div className="mt-3 space-y-2">
                    <p className="text-xs text-gray-400">
                      Backend: {message.data.assistant_backend ?? 'heuristic'}
                      {message.data.model ? ` (${message.data.model})` : ''}
                      {message.data.fallback_used ? ' | fallback' : ''}
                    </p>
                    {message.data.llm_error && (
                      <p className="text-xs text-amber-300">
                        LLM note: {message.data.llm_error}
                      </p>
                    )}
                    {message.data.actions?.length > 0 && (
                      <div className="space-y-2 rounded-lg border border-void-600 bg-void-900/80 p-2.5">
                        <p className="text-xs uppercase tracking-[0.15em] text-gray-400">Actions</p>
                        {message.data.actions.map((action, index) => (
                          <div key={`${message.id}-action-${index}`} className="rounded border border-void-600 bg-void-800/80 p-2">
                            <p className="text-sm text-gray-100">{action.title}</p>
                            {action.why && <p className="mt-1 text-xs text-gray-400">{action.why}</p>}
                            {action.command && (
                              <div className="mt-2 flex flex-wrap items-center gap-2">
                                <code className="rounded bg-void-900 px-2 py-1 text-xs text-neon-cyan">{action.command}</code>
                                <button
                                  type="button"
                                  className="rounded border border-void-600 px-2 py-1 text-xs text-gray-300 hover:border-neon-cyan/45 hover:text-neon-cyan"
                                  onClick={() => void copyCommand(action.command)}
                                >
                                  Copy
                                </button>
                              </div>
                            )}
                          </div>
                        ))}
                      </div>
                    )}
                    {message.data.references?.length > 0 && (
                      <p className="text-xs text-gray-400">
                        References: {message.data.references.join(', ')}
                      </p>
                    )}
                  </div>
                )}
              </article>
            ))}
          </div>

          <form className="space-y-2" onSubmit={onSubmit}>
            <textarea
              className="input-field min-h-[96px]"
              value={input}
              onChange={(event) => setInput(event.target.value)}
              placeholder="Ask a management question..."
              disabled={busy}
            />
            <div className="flex items-center justify-between">
              <p className="text-xs text-gray-500">No credentials should be pasted into chat.</p>
              <button type="submit" className="btn-primary" disabled={busy || !input.trim()}>
                {busy ? 'Thinking...' : 'Send'}
              </button>
            </div>
          </form>
        </div>

        <aside className="card space-y-4">
          <div className="flex flex-col items-center justify-center space-y-3 pb-4 border-b border-void-600">
            <img 
              src="/assets/ceo.png" 
              alt="CEO Icon" 
              className="h-20 w-20 object-contain drop-shadow-[0_0_8px_rgba(0,255,255,0.5)]" 
            />
            <h2 className="text-lg font-medium text-white tracking-wide">Talk to CEO</h2>
          </div>

          <div className="space-y-2">
            <p className="text-xs uppercase tracking-[0.15em] text-gray-400">Quick prompts</p>
            {QUICK_PROMPTS.map((prompt) => (
              <button
                key={prompt}
                type="button"
                onClick={() => void submitPrompt(prompt)}
                className="w-full rounded-lg border border-void-600 bg-void-800/80 px-3 py-2 text-left text-sm text-gray-200 transition-colors hover:border-neon-cyan/45 hover:text-neon-cyan"
                disabled={busy}
              >
                {prompt}
              </button>
            ))}
          </div>

          <div className="space-y-2 border-t border-void-600 pt-4">
            <p className="text-xs uppercase tracking-[0.15em] text-gray-400">Command shortcuts</p>
            {commands.map((item) => (
              <div key={item.id} className="rounded-lg border border-void-600 bg-void-900/65 p-2.5">
                <p className="mb-2 text-[11px] uppercase tracking-wider text-gray-500">{item.title}</p>
                <code className="block overflow-x-auto rounded bg-void-950 px-2 py-1 text-xs text-neon-cyan">{item.command}</code>
                <button
                  type="button"
                  onClick={() => void copyCommand(item.command, item.id)}
                  className="mt-2 rounded border border-void-600 px-2 py-1 text-xs text-gray-300 hover:border-neon-cyan/45 hover:text-neon-cyan"
                >
                  {copiedCommand === item.id ? 'copied' : 'copy'}
                </button>
              </div>
            ))}
          </div>
        </aside>
      </div>
    </section>
  );
}
