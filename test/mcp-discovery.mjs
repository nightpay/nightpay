import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
const client = new Client({ name: 'nightpay-discovery-test', version: '1.0.0' });
const transport = new StdioClientTransport({ command: process.execPath, args: ['mcp/nightpay-mcp.mjs'] });
try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  assert.deepEqual(tools.map(t => t.name), ['list_pages', 'resolve_page', 'list_services', 'service_profile']);
  const pages = await client.callTool({ name: 'list_pages', arguments: {} });
  assert.equal(pages.structuredContent.pages.length, 4);
  const guide = await client.callTool({ name: 'resolve_page', arguments: { id: 'guide' } });
  assert.equal(guide.structuredContent.url, 'https://nightpay.dev/for-agents');
  const rejected = await client.callTool({ name: 'service_profile', arguments: { agent_id: '../../secrets' } });
  assert.equal(rejected.isError, true);
  console.log('MCP SDK handshake, navigation, tool discovery and invalid-path rejection passed');
} finally { await client.close(); }
