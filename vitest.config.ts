export default {
  plugins: [
    {
      name: 'shim-node-sqlite',
      enforce: 'pre',
      resolveId(id: string) {
        if (id === 'node:sqlite' || id === 'sqlite') {
          return '\0node-sqlite-shim';
        }
      },
      load(id: string) {
        if (id === '\0node-sqlite-shim') {
          return `
            import { createRequire } from 'node:module';
            const require = createRequire(import.meta.url);
            const sqlite = require('node:sqlite');
            export const DatabaseSync = sqlite.DatabaseSync;
            export default sqlite;
          `;
        }
      },
    },
  ],
  test: {
    include: ['__tests__/**/*.test.ts'],
    testTimeout: 5000,
  },
};
