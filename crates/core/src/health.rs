use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct ServerHealth {
    pub latency_ms: Option<u32>,
    pub consecutive_failures: u32,
    pub successful_connects: u64,
}

impl ServerHealth {
    pub fn score(&self) -> u64 {
        let latency = self.latency_ms.unwrap_or(10_000) as u64;
        let failure_penalty = self.consecutive_failures as u64 * 5_000;
        let success_bonus = self.successful_connects.min(100) * 10;
        latency.saturating_add(failure_penalty).saturating_sub(success_bonus)
    }
}

#[derive(Debug, Default)]
pub struct HealthBook {
    entries: HashMap<String, ServerHealth>,
}

impl HealthBook {
    pub fn report_latency(&mut self, server_id: impl Into<String>, latency_ms: u32) {
        self.entries.entry(server_id.into()).or_default().latency_ms = Some(latency_ms);
    }

    pub fn report_success(&mut self, server_id: impl Into<String>) {
        let health = self.entries.entry(server_id.into()).or_default();
        health.consecutive_failures = 0;
        health.successful_connects = health.successful_connects.saturating_add(1);
    }

    pub fn report_failure(&mut self, server_id: impl Into<String>) {
        let health = self.entries.entry(server_id.into()).or_default();
        health.consecutive_failures = health.consecutive_failures.saturating_add(1);
    }

    pub fn get(&self, server_id: &str) -> ServerHealth {
        self.entries.get(server_id).copied().unwrap_or_default()
    }

    pub fn ranked_ids<'a>(&self, ids: impl IntoIterator<Item = &'a str>) -> Vec<String> {
        let mut ranked: Vec<String> = ids.into_iter().map(ToOwned::to_owned).collect();
        ranked.sort_by_key(|id| self.get(id).score());
        ranked
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lower_latency_and_fewer_failures_rank_first() {
        let mut book = HealthBook::default();
        book.report_latency("a", 80);
        book.report_latency("b", 30);
        book.report_failure("b");
        assert_eq!(book.ranked_ids(["a", "b"]), vec!["a", "b"]);
    }
}
