// SPDX-License-Identifier: MIT
'use client'

import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react'
import type { Hex } from 'viem'

import { shortHex } from '@/lib/format'

export type ToastKind = 'pending' | 'success' | 'error'

export interface Toast {
  id: number
  kind: ToastKind
  title: string
  message?: string
  hash?: Hex
  /** Decoded custom error name, exposed as a data attribute for tests and support tickets. */
  errorName?: string
}

interface ToastApi {
  push: (toast: Omit<Toast, 'id'>) => number
  update: (id: number, patch: Partial<Omit<Toast, 'id'>>) => void
  dismiss: (id: number) => void
}

const ToastContext = createContext<ToastApi | null>(null)

export function useToasts(): ToastApi {
  const api = useContext(ToastContext)
  if (!api) throw new Error('useToasts must be used inside <ToastProvider>')
  return api
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const nextId = useRef(1)

  const push = useCallback((toast: Omit<Toast, 'id'>) => {
    const id = nextId.current++
    setToasts((current) => [...current, { ...toast, id }].slice(-5))
    return id
  }, [])
  const update = useCallback((id: number, patch: Partial<Omit<Toast, 'id'>>) => {
    setToasts((current) => current.map((toast) => (toast.id === id ? { ...toast, ...patch } : toast)))
  }, [])
  const dismiss = useCallback((id: number) => {
    setToasts((current) => current.filter((toast) => toast.id !== id))
  }, [])
  const api = useMemo(() => ({ push, update, dismiss }), [push, update, dismiss])

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className="toasts" aria-live="polite">
        {toasts.map((toast) => (
          <div
            key={toast.id}
            className={`toast toast-${toast.kind}`}
            role={toast.kind === 'error' ? 'alert' : 'status'}
            data-testid="toast"
            data-kind={toast.kind}
            data-error={toast.errorName ?? ''}
          >
            <div className="toast-head">
              <strong>{toast.title}</strong>
              <button type="button" className="link" aria-label="Dismiss" onClick={() => dismiss(toast.id)}>
                ×
              </button>
            </div>
            {toast.message ? <p>{toast.message}</p> : null}
            {toast.hash ? <code title={toast.hash}>tx {shortHex(toast.hash, 6)}</code> : null}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  )
}
