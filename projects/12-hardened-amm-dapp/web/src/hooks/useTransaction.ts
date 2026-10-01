// SPDX-License-Identifier: MIT
'use client'

import { useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import type { Abi, Address, SimulateContractParameters, TransactionReceipt } from 'viem'
import { useConnection, usePublicClient, useWriteContract } from 'wagmi'

import { useRuntime } from '@/components/RuntimeContext'
import { useToasts } from '@/components/Toasts'
import { decodeError, type ErrorContext } from '@/lib/errors'
import { withGasMargin } from '@/lib/gas'

export interface ContractCall {
  address: Address
  abi: Abi
  functionName: string
  args: readonly unknown[]
}

/**
 * Runs a contract write with a full UX loop: simulate (so a revert is explained before anything is signed),
 * sign and send, wait for the receipt, and, if the transaction was mined but reverted (for example because it was
 * front-run past the slippage limit), replay it at the mined block to recover the custom error for the toast.
 *
 * Every step is pinned to the deployment's chain: simulation and receipts go through that chain's RPC, and the write
 * carries its `chainId`, so wagmi asserts the wallet is on that chain before anything is signed. Without it, a wallet
 * on another network would sign the anvil-simulated call for the same addresses on whatever chain it is on.
 */
export function useTransaction() {
  const { deployment } = useRuntime()
  const { address } = useConnection()
  const client = usePublicClient({ chainId: deployment.chainId })
  const { mutateAsync: writeContract } = useWriteContract()
  const queryClient = useQueryClient()
  const toasts = useToasts()
  const [busy, setBusy] = useState(false)

  const execute = useCallback(
    async (title: string, call: ContractCall, ctx: ErrorContext = {}): Promise<TransactionReceipt | null> => {
      if (!address || !client) return null
      setBusy(true)
      const id = toasts.push({ kind: 'pending', title, message: 'Simulating…' })
      // The call shape is validated by viem at runtime; the generic ABI typing cannot follow a dynamic call.
      const parameters = { ...call, account: address } as unknown as SimulateContractParameters
      try {
        const { request } = await client.simulateContract(parameters)
        const gas = withGasMargin(await client.estimateContractGas(parameters as never))
        toasts.update(id, { message: 'Confirm in your wallet…' })
        const hash = await writeContract({
          ...request,
          gas,
          chainId: deployment.chainId,
        } as Parameters<typeof writeContract>[0])
        toasts.update(id, { message: 'Waiting for the transaction to be mined…', hash })
        const receipt = await client.waitForTransactionReceipt({ hash })
        if (receipt.status === 'reverted') {
          // Receipts carry no revert data: re-run the same call against the state of the block that mined it.
          let decoded = { name: 'Reverted', message: 'The transaction reverted on-chain.' }
          try {
            await client.simulateContract({
              ...parameters,
              blockNumber: receipt.blockNumber,
            } as unknown as SimulateContractParameters)
          } catch (replayError) {
            decoded = decodeError(replayError, ctx)
          }
          toasts.update(id, {
            kind: 'error',
            title: `${title} reverted`,
            message: decoded.message,
            errorName: decoded.name,
          })
          return null
        }
        toasts.update(id, { kind: 'success', message: `Confirmed in block ${receipt.blockNumber}` })
        return receipt
      } catch (error) {
        const decoded = decodeError(error, ctx)
        toasts.update(id, {
          kind: 'error',
          title: `${title} failed`,
          message: decoded.message,
          errorName: decoded.name,
        })
        return null
      } finally {
        setBusy(false)
        await queryClient.invalidateQueries()
      }
    },
    [address, client, deployment.chainId, queryClient, toasts, writeContract],
  )

  return { execute, busy }
}
