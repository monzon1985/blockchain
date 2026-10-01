// SPDX-License-Identifier: MIT
import path from 'node:path'
import type { NextConfig } from 'next'

// The wallet shares dependency-free modules (classifier, 7702 signing policy, WebAuthn helpers) with bundler-lite,
// so the Turbopack root is the project directory that contains both packages.
const projectRoot = path.join(import.meta.dirname, '..')

const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  turbopack: { root: projectRoot },
  outputFileTracingRoot: projectRoot,
}

export default nextConfig
