// SPDX-License-Identifier: MIT
import { Wallet } from '@/components/Wallet'

import { Providers } from './providers'

export default function Page() {
  return (
    <Providers>
      <Wallet />
    </Providers>
  )
}
