import { queryRoutes } from '../queries.mjs';

export const TOOL = {
  name: 'graph_routes',
  description: 'List HTTP routes discovered by the symbol graph (framework-tagged).',
  inputSchema: {
    type: 'object',
    properties: {
      cwd: { type: 'string', description: 'project root; defaults to server cwd' },
      framework: { type: 'string', description: 'optional framework filter (e.g. "express")' },
      limit: { type: 'integer', minimum: 1, maximum: 1000, default: 200 },
    },
    required: [],
  },
};

export async function handler(args = {}) {
  return queryRoutes(args.cwd ?? process.cwd(), {
    framework: args.framework ?? null,
    limit: Math.min(args.limit ?? 200, 1000),
  });
}
