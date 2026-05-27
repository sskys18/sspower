import { queryStatus } from '../queries.mjs';

export const TOOL = {
  name: 'graph_status',
  description: 'Graph index freshness — node/edge counts, dirty queue size, last indexed timestamp.',
  inputSchema: {
    type: 'object',
    properties: { cwd: { type: 'string' } },
    required: [],
  },
};

export async function handler(args = {}) {
  return queryStatus(args.cwd ?? process.cwd());
}
