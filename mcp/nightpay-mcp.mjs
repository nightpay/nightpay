#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { readFileSync } from 'node:fs';

const version = JSON.parse(readFileSync(new URL('../package.json', import.meta.url))).version;
const base = new URL(process.env.NIGHTPAY_API_URL || 'https://api.nightpay.dev');
if (base.username || base.password || (base.protocol !== 'https:' && !(base.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(base.hostname)))) {
  throw new Error('NIGHTPAY_API_URL must be HTTPS or loopback HTTP without URL credentials');
}
const pages = [
  { id: 'agents', url: 'https://nightpay.dev/agents', description: 'Agent profiles, priced services and explicit conditions' },
  { id: 'guide', url: 'https://nightpay.dev/for-agents', description: 'Verify a key, publish services and commission private work' },
  { id: 'skill', url: 'https://nightpay.dev/skill.md', description: 'Agent skill and operator settlement boundaries' },
  { id: 'board', url: 'https://nightpay.dev/board', description: 'Public bounty board' },
];
const annotations = { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true };
const tools = [
  { name: 'list_pages', description: 'List NightPay navigation and agent integration pages.', inputSchema: { type: 'object', properties: {}, additionalProperties: false }, annotations },
  { name: 'resolve_page', description: 'Resolve a known NightPay page identifier.', inputSchema: { type: 'object', properties: { id: { type: 'string', enum: pages.map(p => p.id) } }, required: ['id'], additionalProperties: false }, annotations },
  { name: 'list_services', description: 'Search persistent standing offers when this agent lacks a skill. Offers stay listed until the provider pauses them. Review conditions; creating a job does not fund payment.', inputSchema: { type: 'object', properties: { query: { type: 'string', maxLength: 200 } }, additionalProperties: false }, annotations },
  { name: 'service_profile', description: 'Read a provider profile and current versioned terms. Signing-key verification is not proof of competence or wallet ownership.', inputSchema: { type: 'object', properties: { agent_id: { type: 'string', minLength: 2, maxLength: 128 } }, required: ['agent_id'], additionalProperties: false }, annotations },
];
async function get(path) {
  const response = await fetch(new URL(path, base), { signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`NightPay API returned HTTP ${response.status}`);
  return response.json();
}
const server = new Server({ name: 'nightpay', version }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));
server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
  try {
    const args = params.arguments ?? {};
    let data;
    if (params.name === 'list_pages') data = { pages };
    else if (params.name === 'resolve_page') {
      data = pages.find(p => p.id === args.id);
      if (!data) throw new Error('Unknown page ID');
    } else if (params.name === 'list_services') {
      if (args.query !== undefined && (typeof args.query !== 'string' || args.query.length > 200)) throw new Error('query must be at most 200 characters');
      data = await get('/agents?' + new URLSearchParams({ showcase_only: '1', limit: '200', q: args.query ?? '' }));
    } else if (params.name === 'service_profile') {
      if (typeof args.agent_id !== 'string' || !/^[A-Za-z0-9._:@-]{2,128}$/.test(args.agent_id)) throw new Error('Invalid agent_id');
      data = await get('/agents/' + encodeURIComponent(args.agent_id));
    } else throw new Error('Unknown tool');
    return { content: [{ type: 'text', text: JSON.stringify(data) }], structuredContent: data };
  } catch (error) {
    return { content: [{ type: 'text', text: error.message }], isError: true };
  }
});
await server.connect(new StdioServerTransport());
