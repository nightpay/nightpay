import { useEffect, useState } from 'react';
import { toast, type Toast } from '../utils/toast.ts';

export default function ToastContainer() {
  const [toasts, setToasts] = useState<Toast[]>([]);

  useEffect(() => {
    return toast.subscribe(setToasts);
  }, []);

  return (
    <div className="fixed bottom-4 right-4 z-50 flex flex-col gap-2 pointer-events-none">
      {toasts.map((t) => (
        <div
          key={t.id}
          className={`pointer-events-auto rounded-lg px-4 py-3 shadow-neon-xl border backdrop-blur-md flex items-start gap-3 min-w-[300px] max-w-sm animate-slide-up ${
            t.type === 'success' 
              ? 'bg-green-900/60 border-green-500/50 text-green-200' 
              : t.type === 'error'
              ? 'bg-red-900/60 border-red-500/50 text-red-200'
              : 'bg-void-800/90 border-void-600 text-gray-200'
          }`}
        >
          {t.type === 'success' && <svg className="w-5 h-5 text-green-400 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2"><path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" /></svg>}
          {t.type === 'error' && <svg className="w-5 h-5 text-red-400 shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2"><path strokeLinecap="round" strokeLinejoin="round" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>}
          {t.type === 'info' && <svg className="w-5 h-5 text-neon-cyan shrink-0 mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2"><path strokeLinecap="round" strokeLinejoin="round" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>}
          
          <div className="flex-1">
            <p className="text-sm font-medium">{t.message}</p>
          </div>
          
          <button 
            type="button"
            onClick={() => toast.dismiss(t.id)}
            className="text-gray-400 hover:text-white shrink-0 p-0.5 transition-colors"
          >
            <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2"><path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" /></svg>
          </button>
        </div>
      ))}
    </div>
  );
}