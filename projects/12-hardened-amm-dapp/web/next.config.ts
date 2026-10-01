// SPDX-License-Identifier: MIT
import path from 'node:path'
import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  devIndicators: false,
  // The web app is self-contained; pin the Turbopack / tracing root so a lockfile elsewhere in the monorepo is
  // never mistaken for the workspace root.
  turbopack: { root: path.join(import.meta.dirname) },
  outputFileTracingRoot: path.join(import.meta.dirname),
}

export default nextConfig
