// SPDX-License-Identifier: MIT
// Wallet-side signing policy for EIP-7702 authorizations. Dependency-free; shared with the Next.js wallet.
import { classifyDelegationTarget, type Classification } from '../classifier/index.ts'

export interface AuthorizationRequest {
  /** Chain id the authorization would carry. 0 means "valid on every chain". */
  readonly chainId: number
  /** Delegation target. */
  readonly address: string
  readonly nonce: number
}

export interface AuthorizationPolicyContext {
  /** Chain the wallet is connected to. */
  readonly currentChainId: number
  /** Runtime code currently deployed at the target, as returned by `eth_getCode`. */
  readonly targetCode: string
  /** Optional allowlist of known-good implementations (lower-case addresses). */
  readonly trustedImplementations?: ReadonlySet<string>
  /**
   * Callers the classifier may treat as owner-controlled besides the EOA itself, typically the wallet's EntryPoint
   * (canonical EntryPoints are always trusted). A local EntryPoint compiled from source lives elsewhere.
   */
  readonly trustedCallers?: readonly string[]
}

export interface AuthorizationPolicyResult {
  readonly allowed: boolean
  readonly reasons: readonly string[]
  readonly classification: Classification
}

/**
 * Decides whether the wallet may sign an EIP-7702 authorization.
 *
 * Refuses: chain id 0 (replayable on every chain, where the same address may hold different code: hazard H03), a
 * chain id other than the connected one, and any target the classifier does not rate `safe`, unless the target is
 * explicitly trusted and at least not `malicious`.
 */
export function checkAuthorizationPolicy(
  request: AuthorizationRequest,
  context: AuthorizationPolicyContext,
): AuthorizationPolicyResult {
  const reasons: string[] = []
  if (request.chainId === 0) {
    reasons.push('chainId 0 authorizations are valid on every chain and are never signed')
  } else if (request.chainId !== context.currentChainId) {
    reasons.push(`authorization chainId ${request.chainId} differs from the connected chain ${context.currentChainId}`)
  }
  if (!Number.isInteger(request.nonce) || request.nonce < 0) reasons.push('invalid authorization nonce')

  const classification = classifyDelegationTarget(
    context.targetCode,
    context.trustedCallers === undefined ? {} : { trustedCallers: context.trustedCallers },
  )
  const trusted = context.trustedImplementations?.has(request.address.toLowerCase()) === true
  if (classification.verdict === 'malicious') {
    const worst = classification.findings.find((f) => f.severity === 'critical')
    reasons.push(`delegation target looks like a sweeper: ${worst?.description ?? 'critical finding'}`)
  } else if (classification.verdict === 'review' && !trusted) {
    reasons.push('delegation target needs manual review: ' + classification.findings.map((f) => f.kind).join(', '))
  }
  return { allowed: reasons.length === 0, reasons, classification }
}
