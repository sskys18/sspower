import { queryCallers } from '../queries.mjs';

export const TOOL = {
  name: 'graph_callers',
  description: 'Callers of a function/method/class. Use qualified names to disambiguate.',
  inputSchema: {
    type: 'object',
    properties: {
      name: { type: 'string', minLength: 1, description: 'Symbol name; qualified preferred.' },
      limit: { type: 'integer', minimum: 1, maximum: 200, default: 50 },
      disambiguate: { type: 'boolean', default: false },
      cwd: { type: 'string' },
    },
    required: ['name'],
  },
};

export async function handler(args = {}) {
  if (!args.name) throw new Error('graph_callers: name is required');
  return queryCallers(args.cwd ?? process.cwd(), args.name, {
    limit: Math.min(args.limit ?? 50, 200),
    disambiguate: !!args.disambiguate,
  });
}
