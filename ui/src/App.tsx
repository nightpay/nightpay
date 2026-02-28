import { Link, Routes, Route } from 'react-router-dom';
import Nav from './components/Nav.tsx';
import BoardPage from './pages/BoardPage.tsx';
import VerifyPage from './pages/VerifyPage.tsx';
import StatsPage from './pages/StatsPage.tsx';
import PostPage from './pages/PostPage.tsx';
import GetStartedPage from './pages/GetStartedPage.tsx';
import AgentShowcasePage from './pages/AgentShowcasePage.tsx';
import SkillDocsPage from './pages/SkillDocsPage.tsx';
import TermsPage from './pages/TermsPage.tsx';
import CookiesPage from './pages/CookiesPage.tsx';
import ToastContainer from './components/ToastContainer.tsx';
import CeoPage from './pages/CeoPage.tsx';

export default function App() {
  const hostname = typeof window !== 'undefined' ? window.location.hostname.toLowerCase() : '';
  const ceoHost = hostname === 'ceo.nightpay.dev' || hostname.startsWith('ceo.');
  const docsHost = hostname === 'docs.nightpay.dev' || hostname.startsWith('docs.');
  const rootPage = ceoHost ? <CeoPage /> : docsHost ? <SkillDocsPage /> : <BoardPage />;

  return (
    <div className="app-shell min-h-screen">
      <div className="app-noise" aria-hidden />
      <div className="app-grid" aria-hidden />
      <div className="app-neon" aria-hidden />
      <ToastContainer />

      <div className="relative min-h-screen flex flex-col">
        <Nav />
        <main className="flex-1 min-w-0 max-w-6xl mx-auto w-full px-3 py-6 sm:px-4 sm:py-8 lg:py-10">
          <Routes>
            <Route path="/" element={rootPage} />
            <Route path="/board" element={<BoardPage />} />
            <Route path="/start" element={<GetStartedPage />} />
            <Route path="/get-started" element={<GetStartedPage />} />
            <Route path="/docs" element={<SkillDocsPage />} />
            <Route path="/docs/skill" element={<SkillDocsPage />} />
            <Route path="/skill" element={<SkillDocsPage />} />
            <Route path="/post" element={<PostPage />} />
            <Route path="/agents" element={<AgentShowcasePage />} />
            <Route path="/verify" element={<VerifyPage />} />
            <Route path="/stats" element={<StatsPage />} />
            <Route path="/ceo" element={<CeoPage />} />
            <Route path="/terms" element={<TermsPage />} />
            <Route path="/cookies" element={<CookiesPage />} />
          </Routes>
        </main>
        <footer className="border-t border-void-700/90 bg-void-900/70 py-4 sm:py-5 text-center text-xs text-gray-500 backdrop-blur">
          <div className="flex flex-wrap justify-center items-center gap-x-2 gap-y-2 px-3">
            <span>NightPay anonymous bounties</span>
            <span aria-hidden className="text-gray-600">·</span>
            <Link to="/terms" className="hover:text-neon-cyan transition-colors">Terms</Link>
            <span aria-hidden className="text-gray-600">·</span>
            <Link to="/cookies" className="hover:text-neon-cyan transition-colors">Cookies</Link>
            <span aria-hidden className="text-gray-600">·</span>
            <a href="https://midnight.network" target="_blank" rel="noopener noreferrer" className="hover:text-neon-cyan transition-colors">Midnight</a>
            <span aria-hidden className="text-gray-600">·</span>
            <a href="https://docs.masumi.network" target="_blank" rel="noopener noreferrer" className="hover:text-neon-cyan transition-colors">Masumi</a>
            <span aria-hidden className="text-gray-600">·</span>
            <a href="https://github.com/nightpay/nightpay" target="_blank" rel="noopener noreferrer" className="hover:text-neon-cyan transition-colors">GitHub</a>
          </div>
        </footer>
      </div>
    </div>
  );
}
