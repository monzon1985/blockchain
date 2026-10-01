// SPDX-License-Identifier: MIT
'use client'

import { createContext, useContext } from 'react'

import type { RuntimeConfig } from '@/lib/types'

export const RuntimeContext = createContext<RuntimeConfig | null>(null)

/** Chain endpoint and deployment manifest resolved by the server for this request. */
export function useRuntime(): RuntimeConfig {
  const runtime = useContext(RuntimeContext)
  if (!runtime) throw new Error('useRuntime must be used inside <Providers>')
  return runtime
}
