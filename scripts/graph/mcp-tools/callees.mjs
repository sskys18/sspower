import { queryCallees } from '../queries.mjs';

export const TOOL = {
  name: 'graph_callees',
  description: 'Functions called by the named symbol.',
  inputSchema: {
    type: 'object',
    properties: {
      name: { type: 'string', minLength: 1 },
      limit: { type: 'integer', minimum: 1, maximum: 200, default: 50 },
      cwd: { type: 'string' },
    },
    required: ['name'],
  },
};

export async function handler(args = {}) {
  if (!args.name) throw new Error('graph_callees: name is required');
  return queryCallees(args.cwd ?? process.cwd(), args.name, { limit: Math.min(args.limit ?? 50, 200) });
}
