// SPDX-License-Identifier: MIT
// @ts-check
import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: ['node_modules/', 'coverage/', 'build/', 'demo/', 'fixtures/', 'sources/', 'tests/', 'traces/'],
  },
  js.configs.recommended,
  ...tseslint.configs.strictTypeChecked,
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      '@typescript-eslint/restrict-template-expressions': [
        'error',
        { allowNumber: true, allow: [{ from: 'lib', name: 'BigInt' }] },
      ],
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      'no-console': ['error', { allow: ['error'] }],
      // tsc (checkJs included) already rejects undefined identifiers.
      'no-undef': 'off',
    },
  },
  {
    // Node scripts report progress on stdout.
    files: ['scripts/**/*.mjs', 'scripts/**/*.ts', 'sdk/e2e/**/*.ts'],
    rules: { 'no-console': 'off' },
  },
  {
    files: ['sdk/test/**/*.ts', 'sdk/e2e/**/*.ts'],
    rules: {
      '@typescript-eslint/no-non-null-assertion': 'off',
    },
  },
  {
    files: ['eslint.config.js'],
    ...tseslint.configs.disableTypeChecked,
  },
);
