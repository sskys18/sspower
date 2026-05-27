import { TOOL as statusTool, handler as statusHandler } from './status.mjs';
import { TOOL as callersTool, handler as callersHandler } from './callers.mjs';
import { TOOL as calleesTool, handler as calleesHandler } from './callees.mjs';
import { TOOL as traceTool, handler as traceHandler } from './trace.mjs';
import { TOOL as impactTool, handler as impactHandler } from './impact.mjs';
import { TOOL as nodeTool, handler as nodeHandler } from './node.mjs';
import { TOOL as ctxTool, handler as ctxHandler } from './context.mjs';

export const TOOLS = [statusTool, callersTool, calleesTool, traceTool, impactTool, nodeTool, ctxTool];

const HANDLERS = {
  graph_status: statusHandler,
  graph_callers: callersHandler,
  graph_callees: calleesHandler,
  graph_trace: traceHandler,
  graph_impact: impactHandler,
  graph_node: nodeHandler,
  graph_context: ctxHandler,
};

export async function dispatch(name, args) {
  const fn = HANDLERS[name];
  if (!fn) throw new Error(`unknown tool: ${name}`);
  const a = args ?? {};
  const effectiveCwd = a.cwd ?? process.cwd();
  const payload = await fn(a);
  return {
    content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }],
    _effectiveCwd: effectiveCwd,
  };
}
