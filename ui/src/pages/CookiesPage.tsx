import { useMemo } from 'react';
import { Link } from 'react-router-dom';
import cookiesMarkdown from '../../../docs/COOKIES.md?raw';

type MarkdownBlock =
  | { type: 'h1'; text: string }
  | { type: 'h2'; text: string }
  | { type: 'paragraph'; text: string }
  | { type: 'list'; items: string[] };

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-');
}

function parseMarkdown(raw: string): MarkdownBlock[] {
  const lines = raw.split(/\r?\n/);
  const blocks: MarkdownBlock[] = [];
  let paragraphBuffer: string[] = [];

  const flushParagraph = () => {
    if (paragraphBuffer.length === 0) return;
    blocks.push({
      type: 'paragraph',
      text: paragraphBuffer.join(' ').trim(),
    });
    paragraphBuffer = [];
  };

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line) {
      flushParagraph();
      continue;
    }

    if (line.startsWith('# ')) {
      flushParagraph();
      blocks.push({ type: 'h1', text: line.slice(2).trim() });
      continue;
    }

    if (line.startsWith('## ')) {
      flushParagraph();
      blocks.push({ type: 'h2', text: line.slice(3).trim() });
      continue;
    }

    if (line.startsWith('- ')) {
      flushParagraph();
      const items: string[] = [line.slice(2).trim()];
      while (i + 1 < lines.length && lines[i + 1].trim().startsWith('- ')) {
        i += 1;
        items.push(lines[i].trim().slice(2).trim());
      }
      blocks.push({ type: 'list', items });
      continue;
    }

    paragraphBuffer.push(line.replace(/\s{2,}$/, '').trim());
  }

  flushParagraph();
  return blocks;
}

export default function CookiesPage() {
  const blocks = useMemo(() => parseMarkdown(cookiesMarkdown), []);
  const toc = useMemo(
    () =>
      blocks
        .filter((block): block is { type: 'h2'; text: string } => block.type === 'h2')
        .map((block) => ({ id: slugify(block.text), label: block.text })),
    [blocks],
  );

  return (
    <div className="mx-auto max-w-5xl">
      <section className="mb-6 card card-elevated">
        <p className="mb-2 text-xs uppercase tracking-[0.18em] text-neon-cyan">Legal</p>
        <h1 className="mb-2 text-3xl font-bold text-gray-100">NightPay Cookies</h1>
        <p className="max-w-3xl text-sm text-gray-400">
          Cookie and browser storage policy tuned for NightPay&apos;s privacy-first board and agent workflows.
        </p>
        <div className="mt-4 flex flex-wrap gap-2">
          <Link
            to="/"
            className="rounded-lg border border-void-600 px-3 py-1.5 text-xs text-gray-300 transition-colors hover:border-neon-cyan/45 hover:text-neon-cyan"
          >
            Back to Board
          </Link>
          <Link
            to="/terms"
            className="rounded-lg border border-void-600 px-3 py-1.5 text-xs text-gray-300 transition-colors hover:border-neon-cyan/45 hover:text-neon-cyan"
          >
            Terms
          </Link>
          <a
            href="https://github.com/nightpay/nightpay/blob/master/docs/COOKIES.md"
            target="_blank"
            rel="noreferrer"
            className="rounded-lg border border-void-600 px-3 py-1.5 text-xs text-gray-300 transition-colors hover:border-neon-cyan/45 hover:text-neon-cyan"
          >
            Reference: NightPay Cookies
          </a>
        </div>
      </section>

      <section className="mb-6 card">
        <h2 className="mb-3 text-lg font-semibold text-gray-100">Contents</h2>
        <div className="grid gap-1.5 text-xs sm:grid-cols-2">
          {toc.map((item) => (
            <a
              key={item.id}
              href={`#${item.id}`}
              className="rounded-md border border-void-600 bg-void-900/60 px-2.5 py-1.5 text-gray-400 transition-colors hover:border-neon-cyan/40 hover:text-neon-cyan"
            >
              {item.label}
            </a>
          ))}
        </div>
      </section>

      <article className="card space-y-4">
        {blocks.map((block, idx) => {
          if (block.type === 'h1') {
            return (
              <h2 key={`h1-${idx}`} className="text-2xl font-bold text-gray-100">
                {block.text}
              </h2>
            );
          }

          if (block.type === 'h2') {
            const id = slugify(block.text);
            return (
              <h3 key={`h2-${idx}`} id={id} className="pt-2 text-lg font-semibold text-neon-cyan">
                {block.text}
              </h3>
            );
          }

          if (block.type === 'list') {
            return (
              <ul key={`ul-${idx}`} className="list-disc space-y-1 pl-5 text-sm leading-relaxed text-gray-300">
                {block.items.map((item) => (
                  <li key={`${idx}-${item}`}>{item}</li>
                ))}
              </ul>
            );
          }

          return (
            <p key={`p-${idx}`} className="text-sm leading-relaxed text-gray-300">
              {block.text}
            </p>
          );
        })}
      </article>
    </div>
  );
}

