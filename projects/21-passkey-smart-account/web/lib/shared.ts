// SPDX-License-Identifier: MIT
// Dependency-free modules shared with bundler-lite (one implementation, tested there with vitest).
export { classifyDelegationTarget, type Classification, type Verdict } from '../../bundler/src/classifier/index.ts'
export { checkAuthorizationPolicy, type AuthorizationPolicyResult } from '../../bundler/src/policy/authorization.ts'
export {
  assertionFields,
  base64UrlDecode,
  base64UrlEncode,
  p256PublicKeyFromSpki,
  type WebAuthnAssertionFields,
} from '../../bundler/src/webauthn.ts'
