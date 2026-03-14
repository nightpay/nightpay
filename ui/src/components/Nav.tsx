import { NavLink, useLocation, useNavigate } from 'react-router-dom';
import { useEffect, useMemo, useRef, useState } from 'react';
import CommandPalette, { type PaletteCommand } from './CommandPalette.tsx';
import { api, runtimeConfig, type HealthResponse, type Job } from '../api.ts';

const LOGO_URL = '/assets/logo.svg';

export default function Nav() {
  const navigate = useNavigate();
  const location = useLocation();
  const [health, setHealth] = useState<HealthResponse | null>(null);
  const [availability, setAvailability] = useState<{ status: string; active_jobs: number } | null>(null);
  const [recentJobs, setRecentJobs] = useState<Array<{ id: string; status: string; summary: string }>>([]);
  const [logoOk, setLogoOk] = useState(true);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const headerRef = useRef<HTMLElement | null>(null);
  const [mobileMenuTop, setMobileMenuTop] = useState(64);

  useEffect(() => {
    let active = true;
    const loadStatus = async () => {
      const [healthRes, availabilityRes] = await Promise.allSettled([api.health(), api.availability()]);

      if (!active) return;

      if (healthRes.status === 'fulfilled') {
        setHealth(healthRes.value);
      } else {
        setHealth(null);
      }

      if (availabilityRes.status === 'fulfilled') {
        setAvailability({ status: availabilityRes.value.status, active_jobs: availabilityRes.value.active_jobs });
      } else {
        setAvailability(null);
      }

    };

    const loadRecentJobs = async () => {
      const jobsRes = await Promise.allSettled([api.jobs({ limit: 8, offset: 0, visibility: 'public' })]);
      if (!active) return;
      const jobsResult = jobsRes[0];
      if (jobsResult.status === 'fulfilled') {
        setRecentJobs(
          jobsResult.value.jobs.map((job: Job) => ({
            id: job.job_id,
            status: job.status,
            summary: summarizeJob(job),
          })),
        );
      } else {
        setRecentJobs([]);
      }
    };

    void loadStatus();
    void loadRecentJobs();
    const timer = window.setInterval(() => void loadStatus(), 60_000);
    return () => {
      active = false;
      window.clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    function onKey(event: KeyboardEvent) {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        setPaletteOpen((prev) => !prev);
      }
      if (event.key === 'Escape') {
        setPaletteOpen(false);
        setMobileMenuOpen(false);
      }
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  useEffect(() => {
    const header = headerRef.current;
    if (!header) return;

    let frameId: number | null = null;
    const updateTop = () => {
      setMobileMenuTop(Math.round(header.getBoundingClientRect().height));
    };
    const scheduleUpdate = () => {
      if (frameId !== null) {
        window.cancelAnimationFrame(frameId);
      }
      frameId = window.requestAnimationFrame(updateTop);
    };

    updateTop();
    window.addEventListener('resize', scheduleUpdate);
    window.addEventListener('orientationchange', scheduleUpdate);

    if (typeof ResizeObserver !== 'undefined') {
      const observer = new ResizeObserver(scheduleUpdate);
      observer.observe(header);
      return () => {
        window.removeEventListener('resize', scheduleUpdate);
        window.removeEventListener('orientationchange', scheduleUpdate);
        observer.disconnect();
        if (frameId !== null) {
          window.cancelAnimationFrame(frameId);
        }
      };
    }

    return () => {
      window.removeEventListener('resize', scheduleUpdate);
      window.removeEventListener('orientationchange', scheduleUpdate);
      if (frameId !== null) {
        window.cancelAnimationFrame(frameId);
      }
    };
  }, []);

  useEffect(() => {
    setMobileMenuOpen(false);
  }, [location.pathname, location.search]);

  // Prevent scrolling when mobile menu is open
  useEffect(() => {
    if (mobileMenuOpen) {
      document.body.style.overflow = 'hidden';
    } else {
      document.body.style.overflow = '';
    }
    return () => {
      document.body.style.overflow = '';
    };
  }, [mobileMenuOpen]);

  async function copyCommand(text: string) {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // intentionally no-op in restricted clipboard environments
    }
  }

  const commands = useMemo<PaletteCommand[]>(
    () => {
      const baseCommands: PaletteCommand[] = [
        {
          id: 'board',
          label: 'Go to Board',
          detail: 'Live open bounties and claim actions',
          keywords: 'board bounties list jobs',
          run: () => navigate('/board'),
        },
        {
          id: 'start',
          label: 'Go to Get Started',
          detail: 'Role-based onboarding for users and agents',
          keywords: 'start onboarding openclaw skills',
          run: () => navigate('/get-started'),
        },
        {
          id: 'skill',
          label: 'Go to Skill Docs',
          detail: 'NightPay SKILL.md and API examples',
          keywords: 'skill docs api install',
          run: () => navigate('/docs/skill'),
        },
        {
          id: 'post',
          label: 'Go to Post',
          detail: 'Fund and post a new bounty',
          keywords: 'post create fund bounty',
          run: () => navigate('/post'),
        },
        {
          id: 'agents',
          label: 'Go to Agent Showcase',
          detail: 'Discover agent profiles and private hire',
          keywords: 'agents showcase profile hire direct',
          run: () => navigate('/agents'),
        },
        {
          id: 'verify',
          label: 'Go to Verify',
          detail: 'Validate a receipt hash',
          keywords: 'verify receipt zk',
          run: () => navigate('/verify'),
        },
        {
          id: 'stats',
          label: 'Go to Stats',
          detail: 'Network counters and activity metrics',
          keywords: 'stats network',
          run: () => navigate('/stats'),
        },
        {
          id: 'ceo',
          label: 'Go to CEO Assistant',
          detail: 'Operator onboarding and troubleshooting chat',
          keywords: 'ceo management support troubleshoot onboarding',
          run: () => navigate('/ceo'),
        },
        {
          id: 'terms',
          label: 'Go to Terms',
          detail: 'NightPay Terms of Service',
          keywords: 'terms legal tos service agreement',
          run: () => navigate('/terms'),
        },
        {
          id: 'cookies',
          label: 'Go to Cookies',
          detail: 'NightPay Cookies Policy',
          keywords: 'cookies cookie policy privacy storage',
          run: () => navigate('/cookies'),
        },
        {
          id: 'cmd-openclaw',
          label: 'Copy OpenClaw Install',
          detail: 'clawhub install nightpay',
          keywords: 'openclaw skill install clawhub',
          run: () => void copyCommand('clawhub install nightpay'),
        },
        {
          id: 'cmd-find',
          label: 'Copy Find Agent Command',
          detail: './skills/nightpay/scripts/gateway.sh find-agent "smart contract audit"',
          keywords: 'find-agent gateway',
          run: () => void copyCommand('./skills/nightpay/scripts/gateway.sh find-agent "smart contract audit"'),
        },
        {
          id: 'cmd-showcase',
          label: 'Copy Agent Showcase Command',
          detail: './skills/nightpay/scripts/gateway.sh agent-showcase "audit"',
          keywords: 'agent showcase credibility profile',
          run: () => void copyCommand('./skills/nightpay/scripts/gateway.sh agent-showcase "audit"'),
        },
        {
          id: 'cmd-hire',
          label: 'Copy Hire and Pay Command',
          detail: './skills/nightpay/scripts/gateway.sh hire-and-pay "agent-id" "Task" "commitment"',
          keywords: 'hire-and-pay claim escrow',
          run: () =>
            void copyCommand('./skills/nightpay/scripts/gateway.sh hire-and-pay "agent-id" "Task" "commitment"'),
        },
        {
          id: 'cmd-hire-direct',
          label: 'Copy Private Hire Command',
          detail: './skills/nightpay/scripts/gateway.sh hire-direct "agent-id" "Task" "amount_specks"',
          keywords: 'hire-direct hidden private',
          run: () =>
            void copyCommand('./skills/nightpay/scripts/gateway.sh hire-direct "agent-id" "Task" "25000000"'),
        },
        {
          id: 'cmd-complete',
          label: 'Copy Complete Command',
          detail: './skills/nightpay/scripts/gateway.sh complete "job-id" "commitment"',
          keywords: 'complete payout receipt',
          run: () => void copyCommand('./skills/nightpay/scripts/gateway.sh complete "job-id" "commitment"'),
        },
      ];

      const jobCommands: PaletteCommand[] = recentJobs.map((job) => ({
        id: `job-${job.id}`,
        label: `Jump to Job ${shortJob(job.id)}`,
        detail: `${job.status} | ${job.summary}`,
        keywords: `${job.id} ${job.status} ${job.summary}`,
        run: () => navigate(`/board?q=${encodeURIComponent(job.id)}`),
      }));

      return [...baseCommands, ...jobCommands];
    },
    [navigate, recentJobs],
  );

  const networkLabel = !health
    ? 'offline'
    : health.network === 'mainnet'
      ? 'mainnet'
      : 'preprod';
  const networkColor = !health
    ? 'text-gray-500'
    : health.network === 'mainnet'
      ? 'text-green-400'
      : 'text-yellow-400';
  const bridgeLabel = runtimeConfig.bridgeBase.startsWith('http') ? runtimeConfig.bridgeBase : 'local proxy';
  const gatewayLive = availability?.status === 'available' || availability?.status === 'ok';

  const navLinks = [
    { to: '/get-started', label: 'Get Started' },
    { to: '/docs/skill', label: 'Skill Docs' },
    { to: '/board', label: 'Board' },
    { to: '/post', label: 'Post' },
    { to: '/agents', label: 'Agents' },
  ];
  const topRightLinks = [
    { to: '/terms', label: 'Terms' },
    { to: '/cookies', label: 'Cookies' },
  ];
  const statusLinks = [
    { to: '/verify', label: 'Verify' },
    { to: '/stats', label: 'Stats' },
  ];

  return (
    <>
      <header ref={headerRef} className="mobile-sticky-header z-30 border-b border-void-700 bg-void-900/75 backdrop-blur-md">
        <div className="status-strip relative z-50 border-b border-void-700/70">
          <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-2 px-4 py-2 text-[11px]">
            <div className="flex min-w-0 flex-1 flex-wrap items-center gap-2">
              <StatusChip
                label={`network: ${networkLabel}`}
                active={Boolean(health)}
                className={networkColor}
                iconSrc="/assets/icons/i-network.png"
              />
              <StatusChip
                label={`gateway: ${gatewayLive ? `online (${availability?.active_jobs ?? 0} active)` : 'offline'}`}
                active={gatewayLive}
                className={gatewayLive ? 'text-neon-cyan' : 'text-gray-500'}
                iconSrc="/assets/icons/i-statuspng.png"
              />
              <StatusChip
                label={`bridge: ${bridgeLabel}`}
                active={Boolean(health)}
                className="text-gray-300"
                iconSrc="/assets/icons/i-share.png"
              />
              <StatusChip
                label={`proof: ${runtimeConfig.proofServer}`}
                active
                className="text-gray-300"
                iconSrc="/assets/icons/i-security.png"
              />
            </div>
            <div className="ml-auto flex flex-wrap items-center justify-end gap-2">
              {health?.stub && (
                <StatusChip
                  label="mode: stub"
                  active={false}
                  className="text-amber-300"
                  iconSrc="/assets/icons/i-upload.png"
                />
              )}
              {statusLinks.map(({ to, label }) => (
                <NavLink
                  key={to}
                  to={to}
                  end
                  className={({ isActive }) =>
                    `rounded-full border border-void-600 bg-void-800/70 px-2 py-1 font-mono uppercase tracking-[0.06em] transition-colors ${isActive
                      ? 'border-neon-cyan/40 text-neon-cyan'
                      : 'text-gray-300 hover:border-neon-cyan/40 hover:text-neon-cyan'
                    }`
                  }
                >
                  {label}
                </NavLink>
              ))}
            </div>
          </div>
        </div>

        <div className="relative z-50 mx-auto flex h-14 max-w-6xl min-w-0 items-center justify-between gap-2 bg-void-900/75 px-3 sm:h-16 sm:gap-4 sm:bg-transparent sm:px-4">
          <NavLink to="/" className="group flex items-center gap-3 font-semibold text-neon-cyan">
            {logoOk ? (
              <img
                src={LOGO_URL}
                alt="NightPay"
                className="h-9 w-auto object-contain"
                onError={() => setLogoOk(false)}
              />
            ) : (
              <span className="text-lg tracking-wide text-neon-cyan">NIGHTPAY</span>
            )}
            <span className="hidden text-xs uppercase tracking-[0.25em] text-gray-500 transition-colors group-hover:text-gray-300 xl:block">
              user + agent ready
            </span>
          </NavLink>

          <nav className="hidden min-w-0 flex-1 items-center justify-center gap-1 text-sm lg:flex">
            {navLinks.map(({ to, label }) => (
              <NavLink
                key={to}
                to={to}
                end
                className={({ isActive }) =>
                  `nav-link ${isActive ? 'nav-link-active' : ''}`
                }
              >
                {label}
              </NavLink>
            ))}
          </nav>

          <div className="ml-auto flex items-center gap-2 sm:gap-3">
            <nav className="hidden items-center gap-1 xl:flex">
              {topRightLinks.map(({ to, label }) => (
                <NavLink
                  key={to}
                  to={to}
                  end
                  className={({ isActive }) =>
                    `rounded-md border p-2 min-w-[44px] min-h-[44px] flex items-center justify-center text-xs transition-colors ${isActive
                      ? 'border-neon-cyan/40 bg-neon-cyan/10 text-neon-cyan'
                      : 'border-void-600 text-gray-400 hover:border-neon-cyan/40 hover:text-neon-cyan'
                    }`
                  }
                >
                  {label}
                </NavLink>
              ))}
            </nav>
            <button
              type="button"
              onClick={() => setPaletteOpen(true)}
              className="rounded-lg border border-void-600 bg-void-800/80 px-3 py-2 min-h-[44px] text-[13px] text-gray-300 transition-colors hover:border-neon-cyan/50 hover:text-neon-cyan shadow-sm active:scale-95"
            >
              <span className="xl:hidden">Cmd</span>
              <span className="hidden xl:inline">Command</span>
              <span className="ml-2 hidden text-gray-500 2xl:inline">Ctrl+K</span>
            </button>
            <span className={`hidden md:inline-block h-2.5 w-2.5 rounded-full ${health ? 'bg-neon-cyan shadow-neon-dot' : 'bg-gray-600'}`} />

            {/* Hamburger Button for Mobile */}
            <button
              type="button"
              onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
              className="relative z-50 flex min-h-[44px] min-w-[44px] items-center justify-center rounded-lg border border-void-600 bg-void-800/80 text-gray-300 transition-colors hover:border-neon-cyan/50 hover:text-neon-cyan active:scale-95 xl:hidden"
              aria-label="Toggle menu"
              aria-expanded={mobileMenuOpen}
              aria-controls="mobile-nav-menu"
            >
              <div className="w-5 h-4 flex flex-col justify-between items-center overflow-hidden">
                <span className={`w-full h-0.5 bg-current transform transition-all duration-300 origin-left ${mobileMenuOpen ? 'rotate-45 translate-x-px' : ''}`} />
                <span className={`w-full h-0.5 bg-current transition-all duration-300 ${mobileMenuOpen ? 'opacity-0 translate-x-4' : ''}`} />
                <span className={`w-full h-0.5 bg-current transform transition-all duration-300 origin-left ${mobileMenuOpen ? '-rotate-45 translate-x-px' : ''}`} />
              </div>
            </button>
          </div>
        </div>

        {/* Mobile Flyout Menu */}
        <div
          id="mobile-nav-menu"
          className={`fixed inset-0 z-40 bg-void-900/95 backdrop-blur-xl transition-all duration-300 xl:hidden ${mobileMenuOpen ? 'opacity-100 visible' : 'opacity-0 invisible pointer-events-none'
            }`}
          style={{ top: `${mobileMenuTop}px`, height: `calc(100dvh - ${mobileMenuTop}px)` }}
          onClick={() => setMobileMenuOpen(false)}
        >
          <div className={`p-4 flex flex-col gap-2 h-full overflow-y-auto pb-24 transition-transform duration-300 ${mobileMenuOpen ? 'translate-y-0' : 'translate-y-8'
            }`}
            style={{
              paddingBottom: 'calc(6rem + env(safe-area-inset-bottom, 0px))',
              WebkitOverflowScrolling: 'touch',
            }}
            onClick={(event) => event.stopPropagation()}
          >
            <div className="mb-2 text-xs font-bold uppercase tracking-widest text-gray-500 pl-2">Navigation</div>
            {[...navLinks].map(({ to, label }) => (
              <NavLink
                key={to}
                to={to}
                end
                onClick={() => setMobileMenuOpen(false)}
                className={({ isActive }) =>
                  `flex items-center min-h-[48px] rounded-xl px-4 text-[15px] font-medium transition-colors ${isActive ? 'bg-neon-cyan/10 text-neon-cyan border border-neon-cyan/30' : 'bg-void-800/50 text-gray-300 border border-void-700/50 hover:bg-void-700 hover:text-white'
                  }`
                }
              >
                {label}
              </NavLink>
            ))}

            <div className="mt-4 mb-2 text-xs font-bold uppercase tracking-widest text-gray-500 pl-2">Legal & Info</div>
            {[...topRightLinks].map(({ to, label }) => (
              <NavLink
                key={to}
                to={to}
                end
                onClick={() => setMobileMenuOpen(false)}
                className={({ isActive }) =>
                  `flex items-center min-h-[48px] rounded-xl px-4 text-[15px] font-medium transition-colors ${isActive ? 'bg-neon-cyan/10 text-neon-cyan border border-neon-cyan/30' : 'bg-void-800/50 text-gray-400 border border-void-700/50 hover:bg-void-700 hover:text-white'
                  }`
                }
              >
                {label}
              </NavLink>
            ))}

            <div className="mt-8 flex items-center justify-center p-4 rounded-xl bg-void-800/30 border border-void-700/30">
              <span className={`inline-block mr-2 h-2.5 w-2.5 rounded-full ${health ? 'bg-neon-cyan shadow-neon-dot' : 'bg-gray-600'}`} />
              <span className="text-sm font-medium text-gray-400">System {health ? 'Online' : 'Offline'}</span>
            </div>
          </div>
        </div>

        {/* Removed horizontal scrolling nav links for mobile since we now have the hamburger menu */}
      </header>

      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        commands={commands}
        onJobLookup={(query) => {
          navigate(`/board?q=${encodeURIComponent(query)}`);
        }}
      />
    </>
  );
}

function StatusChip({
  label,
  active,
  className,
  iconSrc,
}: {
  label: string;
  active: boolean;
  className: string;
  iconSrc?: string;
}) {
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full border px-2 py-1 font-mono ${active ? 'border-neon-cyan/35 bg-void-800/70' : 'border-void-600 bg-void-800/70'} ${className}`}>
      {iconSrc ? (
        <img src={iconSrc} alt="" className="h-3 w-3 rounded object-contain opacity-90" aria-hidden="true" />
      ) : (
        <span className={`inline-block h-1.5 w-1.5 rounded-full ${active ? 'bg-neon-cyan' : 'bg-gray-600'}`} />
      )}
      {label}
    </span>
  );
}

function summarizeJob(job: Job): string {
  const raw = job.input_data?.description?.replace(/\s+/g, ' ').trim() ?? '';
  if (!raw) return 'No description';
  return raw.length > 70 ? `${raw.slice(0, 70).trim()}...` : raw;
}

function shortJob(jobId: string): string {
  return jobId.length > 12 ? `${jobId.slice(0, 8)}...${jobId.slice(-4)}` : jobId;
}
