import { queryImpact } from '../queries.mjs';

export const TOOL = {
  name: 'graph_impact',
  description: 'Symbol-level + transitive impact for a file (reverse-import closure).',
  inputSchema: {
    type: 'object',
    properties: {
      file: { type: 'string', minLength: 1, description: 'Path relative to project cwd.' },
      cwd: { type: 'string' },
    },
    required: ['file'],
  },
};

export async function handler(args = {}) {
  if (!args.file) throw new Error('graph_impact: file is required');
  return queryImpact(args.cwd ?? process.cwd(), args.file);
}
