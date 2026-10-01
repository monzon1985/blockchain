// SPDX-License-Identifier: MIT
// Type-aware lint for bundler-lite and the modules the wallet imports from it (classifier, signing policy, WebAuthn).
import js from '@eslint/js'
import { defineConfig, globalIgnores } from 'eslint/config'
import tseslint from 'typescript-eslint'

export default defineConfig([
  globalIgnores(['node_modules/**']),
  js.configs.recommended,
  tseslint.configs.strictTypeChecked,
  tseslint.configs.stylisticTypeChecked,
  {
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      // Gas values, nonces and block numbers (numbers and bigints) are printed in messages on purpose.
      '@typescript-eslint/restrict-template-expressions': ['error', { allowNumber: true, allowBoolean: true }],
      // JSON-RPC payloads are `Record<string, unknown>`: bracket access marks keys that come from the wire.
      '@typescript-eslint/dot-notation': ['error', { allowIndexSignaturePropertyAccess: true }],
      // `(x) => resolve(x)` style callbacks are idiomatic; only block bodies must not return void expressions.
      '@typescript-eslint/no-confusing-void-expression': ['error', { ignoreArrowShorthand: true }],
      // strictTypeChecked bans `!` (no-non-null-assertion); explicit `as T` casts are the project's style instead.
      '@typescript-eslint/non-nullable-type-assertion-style': 'off',
      'no-console': 'error',
    },
  },
  {
    files: ['**/*.mjs'],
    extends: [tseslint.configs.disableTypeChecked],
  },
])
