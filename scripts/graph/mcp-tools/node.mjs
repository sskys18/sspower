import { queryNode } from '../queries.mjs';

export const TOOL = {
  name: 'graph_node',
  description: 'Full source metadata for one symbol.',
  inputSchema: {
    type: 'object',
    properties: { name: { type: 'string', minLength: 1 }, cwd: { type: 'string' } },
    required: ['name'],
  },
};

export async function handler(args = {}) {
  if (!args.name) throw new Error('graph_node: name is required');
  return queryNode(args.cwd ?? process.cwd(), args.name);
}
