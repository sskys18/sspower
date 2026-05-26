// __tests__/graph-fixtures/ts-js/sample-input.ts
// Minimal fixture for graph extractor: one caller, one callee, one
// ambiguous same-name across two classes.

export function helper(x: number): number {
  return x + 1;
}

function caller(): number {
  return helper(42);
}

class A {
  shared(): string { return 'a'; }
}

class B {
  shared(): string { return 'b'; }
}

function ambiguous(a: A, b: B): string {
  return a.shared() + b.shared();
}

export { caller, ambiguous };
