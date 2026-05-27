import { queryTrace } from '../queries.mjs';

export const TOOL = {
  name: 'graph_trace',
  description: 'Shortest call path between two symbols (BFS, max 10 hops).',
  inputSchema: {
    type: 'object',
    properties: {
      from: { type: 'string', minLength: 1 },
      to: { type: 'string', minLength: 1 },
      maxHops: { type: 'integer', minimum: 1, maximum: 10, default: 6 },
      cwd: { type: 'string' },
    },
    required: ['from', 'to'],
  },
};

export async function handler(args = {}) {
  if (!args.from || !args.to) throw new Error('graph_trace: from and to are required');
  return queryTrace(args.cwd ?? process.cwd(), args.from, args.to, { maxHops: Math.min(args.maxHops ?? 6, 10) });
}
