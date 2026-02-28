import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { ADMIN_TOKEN_STORAGE_KEY } from '../api.ts';

export default function OpsPage() {
  const navigate = useNavigate();
  const [token, setToken] = useState('');
  const [reveal, setReveal] = useState(false);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const value = token.trim();
    if (!value) return;
    try {
      sessionStorage.setItem(ADMIN_TOKEN_STORAGE_KEY, value);
      setToken('');
      navigate('/board', { replace: true });
    } catch {
      // ignore
    }
  }

  return (
    <div className="min-h-[60vh] flex items-center justify-center px-4">
      <form onSubmit={handleSubmit} className="w-full max-w-sm">
        <div className="rounded-xl border border-void-700 bg-void-800/50 p-6 shadow-lg">
          <label htmlFor="ops-token" className="mb-2 block text-[11px] font-medium uppercase tracking-widest text-gray-500">
            Token
          </label>
          <input
            id="ops-token"
            type={reveal ? 'text' : 'password'}
            className="input-field mb-4 w-full h-11 bg-void-900/80 border-void-600 focus:border-void-500"
            placeholder=""
            value={token}
            onChange={(e) => setToken(e.target.value)}
            autoComplete="off"
          />
          <div className="flex items-center gap-2">
            <button
              type="submit"
              disabled={!token.trim()}
              className="rounded-lg border border-void-600 bg-void-700 px-5 py-2.5 text-sm font-medium text-gray-200 hover:bg-void-600 hover:text-white disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
            >
              Go
            </button>
            <button
              type="button"
              onClick={() => setReveal((r) => !r)}
              className="rounded-lg border border-void-600 px-3 py-2.5 text-xs text-gray-500 hover:text-gray-300"
            >
              {reveal ? 'Hide' : 'Show'}
            </button>
          </div>
        </div>
      </form>
    </div>
  );
}
