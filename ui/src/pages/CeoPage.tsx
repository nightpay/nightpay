import { FormEvent, useMemo, useState } from 'react';
import { api, type ManagementChatResponse, type ManagementMode } from '../api.ts';
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

export default function CeoPage() {
  const [mode, setMode] = useState<ManagementMode>('general');
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
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

  async function copyCommand(command?: string) {
    if (!command) return;
    try {
      await navigator.clipboard.writeText(command);
      toast.success('Command copied');
    } catch {
      toast.error('Clipboard unavailable');
    }
  }

  return (
    <section className="space-y-4">
      <header className="card card-elevated">
        <p className="text-xs uppercase tracking-[0.2em] text-neon-cyan">CEO Support Channel</p>
        <h1 className="mt-2 text-2xl font-semibold text-white sm:text-3xl">Management Assistant</h1>
        <p className="mt-2 text-sm text-gray-300">
          This assistant is focused on operator onboarding, external agent setup, and troubleshooting. It returns direct actions and commands.
        </p>

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
        </aside>
      </div>
    </section>
  );
}
