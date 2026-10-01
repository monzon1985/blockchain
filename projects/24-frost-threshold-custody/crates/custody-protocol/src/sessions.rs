// SPDX-License-Identifier: MIT
//! A bounded table of in-flight sessions that hold secret state.
//!
//! Sessions are opened by the (untrusted) coordinator, so a participant must
//! not let it accumulate secret polynomials, nonces or repair deltas without
//! limit. The table keeps at most `capacity` sessions, evicting the oldest,
//! and drops sessions older than a time-to-live on request. Dropping a
//! session drops its state, whose secret parts zeroise themselves
//! (`ZeroizeOnDrop` in frost-core, [`zeroize::Zeroizing`] here).

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use crate::ids::SessionId;

/// Bounded, insertion-ordered map from session id to session state.
pub struct SessionTable<T> {
    entries: HashMap<SessionId, (Instant, T)>,
    order: VecDeque<SessionId>,
    capacity: usize,
}

impl<T> SessionTable<T> {
    /// An empty table holding at most `capacity` sessions.
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            entries: HashMap::new(),
            order: VecDeque::new(),
            capacity: capacity.max(1),
        }
    }

    /// Number of live sessions.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether the table is empty.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Whether `session` is live.
    #[must_use]
    pub fn contains(&self, session: &SessionId) -> bool {
        self.entries.contains_key(session)
    }

    /// The state of a live session.
    #[must_use]
    pub fn get(&self, session: &SessionId) -> Option<&T> {
        self.entries.get(session).map(|(_, v)| v)
    }

    /// The state of a live session, mutably.
    pub fn get_mut(&mut self, session: &SessionId) -> Option<&mut T> {
        self.entries.get_mut(session).map(|(_, v)| v)
    }

    /// Inserts (or replaces) a session opened now; returns the sessions
    /// evicted to stay within capacity (oldest first).
    pub fn insert(&mut self, session: SessionId, value: T) -> Vec<SessionId> {
        self.insert_at(session, value, Instant::now())
    }

    /// [`Self::insert`] with an explicit opening time.
    pub fn insert_at(&mut self, session: SessionId, value: T, opened: Instant) -> Vec<SessionId> {
        if self.entries.insert(session, (opened, value)).is_some() {
            self.order.retain(|s| *s != session);
        }
        self.order.push_back(session);
        let mut evicted = Vec::new();
        while self.entries.len() > self.capacity {
            let Some(oldest) = self.order.pop_front() else {
                break;
            };
            if self.entries.remove(&oldest).is_some() {
                evicted.push(oldest);
            }
        }
        evicted
    }

    /// Removes a session and returns its state.
    pub fn remove(&mut self, session: &SessionId) -> Option<T> {
        let (_, value) = self.entries.remove(session)?;
        self.order.retain(|s| s != session);
        Some(value)
    }

    /// Drops every session opened more than `max_age` before `now`; returns
    /// their ids.
    pub fn expire(&mut self, now: Instant, max_age: Duration) -> Vec<SessionId> {
        let mut expired = Vec::new();
        while let Some(oldest) = self.order.front().copied() {
            let stale = self
                .entries
                .get(&oldest)
                .is_none_or(|(opened, _)| now.saturating_duration_since(*opened) > max_age);
            if !stale {
                break;
            }
            self.order.pop_front();
            if self.entries.remove(&oldest).is_some() {
                expired.push(oldest);
            }
        }
        expired
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(i: u8) -> SessionId {
        SessionId([i; 16])
    }

    #[test]
    fn capacity_evicts_the_oldest_and_expiry_drops_stale_sessions() {
        let t0 = Instant::now();
        let mut table = SessionTable::new(2);
        assert!(table.insert_at(id(1), "a", t0).is_empty());
        assert!(
            table
                .insert_at(id(2), "b", t0 + Duration::from_secs(5))
                .is_empty()
        );
        assert_eq!(
            table.insert_at(id(3), "c", t0 + Duration::from_secs(10)),
            vec![id(1)]
        );
        assert_eq!(table.len(), 2);
        assert!(!table.contains(&id(1)));
        // Replacing a live session keeps a single entry.
        assert!(
            table
                .insert_at(id(3), "c2", t0 + Duration::from_secs(10))
                .is_empty()
        );
        assert_eq!(table.get(&id(3)), Some(&"c2"));
        if let Some(v) = table.get_mut(&id(2)) {
            *v = "b2";
        }
        assert_eq!(
            table.expire(t0 + Duration::from_secs(11), Duration::from_secs(5)),
            vec![id(2)]
        );
        assert_eq!(table.remove(&id(3)), Some("c2"));
        assert!(table.is_empty());
        assert_eq!(table.remove(&id(3)), None);
        assert!(
            table
                .expire(t0 + Duration::from_secs(99), Duration::ZERO)
                .is_empty()
        );
    }
}
