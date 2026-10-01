// SPDX-License-Identifier: MIT

/// LP marker types of the three e2e pools. Each pool registers its own LP coin,
/// `flash_kiosk::pool::LpCoin<marker>`, in the `CoinRegistry`; a marker only
/// names that coin, and since a marker backs exactly one pool, it also makes
/// every pool's LP coin a different type. Never instantiated.
module demo_coins::markers;

/// Marker of the lender pool L.
public struct LP_L {}

/// Marker of arbitrage pool X.
public struct LP_X {}

/// Marker of arbitrage pool Y.
public struct LP_Y {}
