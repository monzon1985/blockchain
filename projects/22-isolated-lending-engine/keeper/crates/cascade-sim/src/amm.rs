// SPDX-License-Identifier: MIT
//! Constant-product pool where liquidators sell seized collateral, with arbitrage toward the external price.
//!
//! The pool is the market's price-setting venue: its mid price feeds the oracle. Liquidation sales push it down
//! and arbitrage closes a fixed share of the gap to the external price each block. When liquidations arrive
//! faster than arbitrage repairs the price, they trigger further liquidations: the cascade the simulator measures.

/// Pool reserves (collateral `x`, loan token `y`).
#[derive(Debug, Clone, PartialEq)]
pub struct Pool {
    x: f64,
    y: f64,
    fee: f64,
}

impl Pool {
    /// A pool quoting `price` with `loan_reserve` of loan token.
    pub fn new(price: f64, loan_reserve: f64, fee: f64) -> Self {
        Self { x: loan_reserve / price, y: loan_reserve, fee }
    }

    /// Mid price (loan per collateral).
    pub fn price(&self) -> f64 {
        self.y / self.x
    }

    /// Loan tokens received for selling `amount_in` collateral (after the fee).
    pub fn quote_sell(&self, amount_in: f64) -> f64 {
        let effective = amount_in * (1.0 - self.fee);
        self.y * effective / (self.x + effective)
    }

    /// Sells `amount_in` collateral into the pool and returns the loan tokens received.
    pub fn sell(&mut self, amount_in: f64) -> f64 {
        let out = self.quote_sell(amount_in);
        self.x += amount_in;
        self.y -= out;
        out
    }

    /// Moves the pool price `speed` of the way toward `external_price`, keeping `x * y` constant.
    pub fn arbitrage(&mut self, external_price: f64, speed: f64) {
        let current = self.price();
        let target = current + speed * (external_price - current);
        let k = self.x * self.y;
        self.x = libm::sqrt(k / target);
        self.y = libm::sqrt(k * target);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selling_moves_price_down_and_charges_fee() {
        let mut pool = Pool::new(2_000.0, 10_000_000.0, 0.003);
        let quote = pool.quote_sell(10.0);
        assert!(quote < 20_000.0 * 0.997);
        let out = pool.sell(10.0);
        assert_eq!(out.to_bits(), quote.to_bits());
        assert!(pool.price() < 2_000.0);
    }

    #[test]
    fn arbitrage_closes_the_gap() {
        let mut pool = Pool::new(2_000.0, 10_000_000.0, 0.003);
        pool.arbitrage(1_000.0, 1.0);
        assert!((pool.price() - 1_000.0).abs() < 1e-6);
        pool.arbitrage(2_000.0, 0.5);
        assert!((pool.price() - 1_500.0).abs() < 1e-6);
    }
}
