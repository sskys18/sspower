import { queryContext } from '../queries.mjs';

export const TOOL = {
  name: 'graph_context',
  description: 'Compose search + node + callers for a task description. task is free-form, max 500 chars.',
  inputSchema: {
    type: 'object',
    properties: {
      task: { type: 'string', minLength: 1, maxLength: 500 },
      cwd: { type: 'string' },
    },
    required: ['task'],
  },
};

export async function handler(args = {}) {
  if (!args.task) throw new Error('graph_context: task is required');
  if (args.task.length > 500) throw new Error('graph_context: task length exceeds 500 chars');
  return queryContext(args.cwd ?? process.cwd(), args.task);
}
