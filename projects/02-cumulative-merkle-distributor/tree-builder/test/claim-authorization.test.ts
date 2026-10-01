// SPDX-License-Identifier: MIT
import fc from 'fast-check';
import {
  concat,
  encodeAbiParameters,
  keccak256,
  maxUint256,
  recoverTypedDataAddress,
  stringToBytes,
  type Hex,
} from 'viem';
import { privateKeyToAddress } from 'viem/accounts';
import { describe, expect, it } from 'vitest';
import {
  CLAIM_AUTHORIZATION_TYPES,
  claimAuthorizationDomain,
  claimAuthorizationDomainSeparator,
  hashClaimAuthorization,
  signClaimAuthorization,
  type ClaimAuthorization,
} from '../src/claim-authorization.ts';
import { address } from './arbitraries.ts';

const TYPE =
  'ClaimAuthorization(address account,address token,uint256 cumulativeAmount,address recipient,uint256 nonce,uint256 deadline)';

/** The digest computed by hand from the EIP-712 spec, exactly as the contract does it. */
function manualDigest(chainId: number, verifyingContract: Hex, m: ClaimAuthorization): Hex {
  const domain = keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint256' }, { type: 'address' }],
      [
        keccak256(stringToBytes('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')),
        keccak256(stringToBytes('CumulativeMerkleDistributor')),
        keccak256(stringToBytes('1')),
        BigInt(chainId),
        verifyingContract,
      ],
    ),
  );
  const struct = keccak256(
    encodeAbiParameters(
      [
        { type: 'bytes32' },
        { type: 'address' },
        { type: 'address' },
        { type: 'uint256' },
        { type: 'address' },
        { type: 'uint256' },
        { type: 'uint256' },
      ],
      [keccak256(stringToBytes(TYPE)), m.account, m.token, m.cumulativeAmount, m.recipient, m.nonce, m.deadline],
    ),
  );
  return keccak256(concat(['0x1901', domain, struct]));
}

const message: fc.Arbitrary<ClaimAuthorization> = fc.record({
  account: address,
  token: address,
  cumulativeAmount: fc.bigInt({ min: 0n, max: maxUint256 }),
  recipient: address,
  nonce: fc.bigInt({ min: 0n, max: 2n ** 64n }),
  deadline: fc.bigInt({ min: 0n, max: 2n ** 64n }),
});

describe('claim authorization (EIP-712)', () => {
  it('the type definition matches the Solidity type string', () => {
    const fields = CLAIM_AUTHORIZATION_TYPES.ClaimAuthorization.map((f) => `${f.type} ${f.name}`).join(',');
    expect(`ClaimAuthorization(${fields})`).toBe(TYPE);
  });

  it('viem digest == hand-rolled digest', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 2 ** 31 }), address, message, (chainId, verifying, m) => {
        expect(hashClaimAuthorization(claimAuthorizationDomain(chainId, verifying), m)).toBe(
          manualDigest(chainId, verifying, m),
        );
      }),
    );
  });

  it('the domain separator depends on the chain id and the contract', () => {
    fc.assert(
      fc.property(fc.integer({ min: 1, max: 2 ** 31 }), address, address, (chainId, a, b) => {
        fc.pre(a !== b);
        const sep = claimAuthorizationDomainSeparator(claimAuthorizationDomain(chainId, a));
        expect(claimAuthorizationDomainSeparator(claimAuthorizationDomain(chainId + 1, a))).not.toBe(sep);
        expect(claimAuthorizationDomainSeparator(claimAuthorizationDomain(chainId, b))).not.toBe(sep);
      }),
    );
  });

  it('signatures recover to the signer', async () => {
    await fc.assert(
      fc.asyncProperty(fc.string({ minLength: 1, maxLength: 12 }), address, message, async (label, verifying, m) => {
        const key = keccak256(stringToBytes(label));
        const account = privateKeyToAddress(key);
        const domain = claimAuthorizationDomain(31337, verifying);
        const msg = { ...m, account };
        const signature = await signClaimAuthorization(key, domain, msg);
        expect(signature).toMatch(/^0x[0-9a-f]{130}$/);
        const recovered = await recoverTypedDataAddress({
          domain,
          types: CLAIM_AUTHORIZATION_TYPES,
          primaryType: 'ClaimAuthorization',
          message: msg,
          signature,
        });
        expect(recovered).toBe(account);
      }),
      { numRuns: 50 },
    );
  });
});
