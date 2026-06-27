//! `mdvcore-pm` — the project-management store (TSK-345).
//!
//! Isolated from `mdvcore-core` (which stays sans-IO / wasm-buildable) because
//! rusqlite performs file IO. Per the v2 design
//! (`docs/PROJECT_MANAGEMENT_DESIGN_v2.md`) the PM store is an embedded SQLite
//! file, Rust-owned: an append-only event log is the source of truth, and the
//! current-state tables are a deterministic projection of that log. One
//! transaction commits the event AND its projection atomically.
//!
//! Slice 2a (this file) is the event-sourcing MECHANISM: append-and-project
//! atomically, plus `replay` proving the projection is a pure fold over the log.
//! DEFERRED to slice 2b (needs an owner-approved crypto hash): the tamper-evident
//! `prev_hash`/`row_hash` chain and the decision-trace columns (model_fp,
//! input_hash, confidence, …). Also later: the on-disk path, ULID event ids,
//! edges/leases, the lifecycle state-machine, and the FFI exposure.

use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

/// Slice-2a schema. The hash-chain + decision-trace columns and the edge/lease
/// tables land in later slices; this is the minimal log + projection that proves
/// the event-sourcing mechanism.
const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS event_log (
    seq        INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         INTEGER NOT NULL,
    actor_id   TEXT NOT NULL,
    actor_kind INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    subject_id TEXT,
    reason     TEXT,
    payload    BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS work_item (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    state       TEXT NOT NULL,
    created_seq INTEGER NOT NULL,
    updated_seq INTEGER NOT NULL
);
";

/// A typed work-item event — the delta this log entry applies to the projection.
/// Serialized (MessagePack) into `event_log.payload`; `replay` decodes + folds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkItemEvent {
    /// A new work item enters the system.
    Created {
        /// Stable id.
        id: String,
        /// Human title.
        title: String,
        /// Initial state class.
        state: String,
    },
    /// An existing work item transitions to a new state (the WHY is required).
    StateChanged {
        /// Target item id.
        id: String,
        /// New state class.
        state: String,
        /// The reason for the transition — the consumer of history is the next agent.
        reason: String,
    },
}

/// A materialized work item — one row of the current-state projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkItem {
    /// Stable id.
    pub id: String,
    /// Human title.
    pub title: String,
    /// Current state class.
    pub state: String,
    /// `event_log.seq` that created this item.
    pub created_seq: i64,
    /// `event_log.seq` of the most recent event touching it.
    pub updated_seq: i64,
}

/// Open an in-memory store with the slice-2a schema. (The on-disk path is a later slice.)
///
/// # Errors
/// Propagates any rusqlite open / DDL error.
pub fn open_in_memory() -> rusqlite::Result<Connection> {
    let conn = Connection::open_in_memory()?;
    conn.execute_batch(SCHEMA)?;
    Ok(conn)
}

/// Append `event` to the log AND apply it to the projection — atomically, in one
/// transaction (the v2 invariant: the event and its projection commit together).
/// Returns the new event's `seq`. `ts`/`actor_*` are writer-assigned context.
///
/// # Errors
/// Propagates any payload-encode or rusqlite error; on error the transaction
/// rolls back, so neither the event nor the projection change.
pub fn append(
    conn: &mut Connection,
    ts: i64,
    actor_id: &str,
    actor_kind: i64,
    event: &WorkItemEvent,
) -> rusqlite::Result<i64> {
    let payload = rmp_serde::to_vec(event)
        .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    let (event_type, subject_id, reason): (&str, &str, Option<&str>) = match event {
        WorkItemEvent::Created { id, .. } => ("work_item.created", id, None),
        WorkItemEvent::StateChanged { id, reason, .. } => {
            ("work_item.state_changed", id, Some(reason))
        }
    };
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO event_log (ts, actor_id, actor_kind, event_type, subject_id, reason, payload)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![ts, actor_id, actor_kind, event_type, subject_id, reason, payload],
    )?;
    let seq = tx.last_insert_rowid();
    apply_to_projection(&tx, seq, event)?;
    tx.commit()?;
    Ok(seq)
}

/// Fold one event into the current-state projection (used by both `append` and
/// `replay`, so the projection logic lives in exactly one place).
fn apply_to_projection(
    tx: &rusqlite::Transaction<'_>,
    seq: i64,
    event: &WorkItemEvent,
) -> rusqlite::Result<()> {
    match event {
        WorkItemEvent::Created { id, title, state } => {
            tx.execute(
                "INSERT INTO work_item (id, title, state, created_seq, updated_seq)
                 VALUES (?1, ?2, ?3, ?4, ?4) ON CONFLICT(id) DO NOTHING",
                rusqlite::params![id, title, state, seq],
            )?;
        }
        WorkItemEvent::StateChanged { id, state, .. } => {
            tx.execute(
                "UPDATE work_item SET state = ?2, updated_seq = ?3 WHERE id = ?1",
                rusqlite::params![id, state, seq],
            )?;
        }
    }
    Ok(())
}

/// The current projected state of one work item, or `None` if unknown.
///
/// # Errors
/// Propagates any rusqlite query error.
pub fn get_work_item(conn: &Connection, id: &str) -> rusqlite::Result<Option<WorkItem>> {
    conn.query_row(
        "SELECT id, title, state, created_seq, updated_seq FROM work_item WHERE id = ?1",
        [id],
        |r| {
            Ok(WorkItem {
                id: r.get(0)?,
                title: r.get(1)?,
                state: r.get(2)?,
                created_seq: r.get(3)?,
                updated_seq: r.get(4)?,
            })
        },
    )
    .optional()
}

/// Rebuild the projection from the event log alone — proving the projection is a
/// pure, deterministic fold over the append-only log (the v2 invariant: the log
/// is the truth, current state is disposable + rebuildable).
///
/// # Errors
/// Propagates any payload-decode or rusqlite error; runs in a transaction so a
/// mid-replay failure leaves the prior projection intact.
pub fn replay(conn: &mut Connection) -> rusqlite::Result<()> {
    let events: Vec<(i64, Vec<u8>)> = {
        let mut stmt = conn.prepare("SELECT seq, payload FROM event_log ORDER BY seq")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let tx = conn.transaction()?;
    tx.execute_batch("DELETE FROM work_item")?;
    for (seq, payload) in events {
        let event: WorkItemEvent = rmp_serde::from_slice(&payload).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Blob, Box::new(e))
        })?;
        apply_to_projection(&tx, seq, &event)?;
    }
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn created(id: &str, title: &str) -> WorkItemEvent {
        WorkItemEvent::Created {
            id: id.into(),
            title: title.into(),
            state: "open".into(),
        }
    }

    /// append() folds an event into the projection atomically; a later
    /// StateChanged updates it (and bumps updated_seq, not created_seq).
    #[test]
    fn append_projects_create_then_state_change() -> rusqlite::Result<()> {
        let mut conn = open_in_memory()?;
        let s1 = append(&mut conn, 1, "human:jos", 0, &created("T1", "Task one"))?;
        let s2 = append(
            &mut conn,
            2,
            "agent:reviewer",
            1,
            &WorkItemEvent::StateChanged {
                id: "T1".into(),
                state: "done".into(),
                reason: "tests pass".into(),
            },
        )?;
        let wi = get_work_item(&conn, "T1")?;
        assert_eq!(
            wi,
            Some(WorkItem {
                id: "T1".into(),
                title: "Task one".into(),
                state: "done".into(),
                created_seq: s1,
                updated_seq: s2,
            })
        );
        Ok(())
    }

    /// The v2 invariant: replay() rebuilds the projection from the log alone, and
    /// the result is byte-identical to the live-folded projection.
    #[test]
    fn replay_reproduces_projection_exactly() -> rusqlite::Result<()> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "human:jos", 0, &created("A", "Alpha"))?;
        append(&mut conn, 2, "human:jos", 0, &created("B", "Beta"))?;
        append(
            &mut conn,
            3,
            "agent:x",
            1,
            &WorkItemEvent::StateChanged {
                id: "A".into(),
                state: "done".into(),
                reason: "shipped".into(),
            },
        )?;
        let before_a = get_work_item(&conn, "A")?;
        let before_b = get_work_item(&conn, "B")?;
        replay(&mut conn)?;
        assert_eq!(get_work_item(&conn, "A")?, before_a, "A survives replay identically");
        assert_eq!(get_work_item(&conn, "B")?, before_b, "B survives replay identically");
        Ok(())
    }

    /// A StateChanged for an unknown id is a no-op on the projection (no row to
    /// update) and does not error — the event is still logged.
    #[test]
    fn state_change_unknown_id_is_logged_noop() -> rusqlite::Result<()> {
        let mut conn = open_in_memory()?;
        append(
            &mut conn,
            1,
            "agent:x",
            1,
            &WorkItemEvent::StateChanged {
                id: "ghost".into(),
                state: "done".into(),
                reason: "n/a".into(),
            },
        )?;
        assert_eq!(get_work_item(&conn, "ghost")?, None);
        let logged: i64 =
            conn.query_row("SELECT COUNT(*) FROM event_log", [], |r| r.get(0))?;
        assert_eq!(logged, 1, "the event is logged even when the projection no-ops");
        Ok(())
    }
}
