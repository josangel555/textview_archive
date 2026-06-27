//! `mdvcore-pm` — the project-management store (TSK-345).
//!
//! Isolated from `mdvcore-core` (which stays sans-IO / wasm-buildable) because
//! rusqlite performs file IO. Per the v2 design
//! (`docs/PROJECT_MANAGEMENT_DESIGN_v2.md`) the PM store is an embedded SQLite
//! file, Rust-owned, as an event-log + materialized projection.
//!
//! THIS is slice 1 — the dep-establish probe: it proves rusqlite-against-the
//! -SYSTEM-libsqlite3 builds + links in the workspace and that a minimal
//! event-log schema round-trips. The full event-sourcing + projection model,
//! the on-disk path, the lifecycle state-machine, and the FFI exposure follow in
//! later slices.

use rusqlite::Connection;

/// Open an in-memory PM store with the provisional event-log table.
///
/// The on-disk path and the full schema (the materialized projection tables, the
/// lifecycle/actor columns) land in the next slice; this establishes the append
/// log's shape.
///
/// # Errors
/// Propagates any rusqlite open / DDL error.
pub fn open_in_memory() -> rusqlite::Result<Connection> {
    let conn = Connection::open_in_memory()?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS events (
             seq     INTEGER PRIMARY KEY AUTOINCREMENT,
             kind    TEXT NOT NULL,
             payload TEXT NOT NULL
         );",
    )?;
    Ok(conn)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Proves the full round-trip works against the system libsqlite3: open →
    /// DDL → insert → read back. The test returns `Result` and uses `?` rather
    /// than `unwrap`/`expect` (the workspace's no-panic deny lints apply to
    /// `--all-targets`, tests included).
    #[test]
    fn open_create_insert_read_roundtrip() -> rusqlite::Result<()> {
        let conn = open_in_memory()?;
        conn.execute(
            "INSERT INTO events (kind, payload) VALUES (?1, ?2)",
            ("task.created", "{}"),
        )?;
        let (kind, payload): (String, String) = conn.query_row(
            "SELECT kind, payload FROM events WHERE seq = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        assert_eq!(kind, "task.created");
        assert_eq!(payload, "{}");
        Ok(())
    }
}
