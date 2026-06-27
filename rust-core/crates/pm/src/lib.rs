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
use std::path::Path;

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

/// The lifecycle state CLASSES the core understands (v2 design §2.2). The visible
/// labels a UI shows are an open vocabulary layered on top; these fixed classes
/// are what the state machine enforces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// Exists, not yet admitted; scope/intent unconfirmed.
    Proposed,
    /// Admitted, fully specified, dispatchable now.
    Ready,
    /// An agent/human holds a lease and is working it.
    Active,
    /// Durably suspended on a typed ResumeContract (the first-class blocked state).
    Parked,
    /// The doer asserts complete — the agent's ceiling (never self-certifies done).
    ClaimedDone,
    /// An independent verifier passed.
    VerifiedDone,
    /// Integrated/shipped; terminal.
    Closed,
    /// Declined at intake; terminal.
    Rejected,
    /// Stopped without completion (carries the negative knowledge); terminal.
    Abandoned,
    /// Was VerifiedDone; an upstream consumed output changed — routes to re-examine.
    AssumptionsInvalidated,
}

impl State {
    /// The canonical class string persisted in `work_item.state`.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            State::Proposed => "proposed",
            State::Ready => "ready",
            State::Active => "active",
            State::Parked => "parked",
            State::ClaimedDone => "claimed_done",
            State::VerifiedDone => "verified_done",
            State::Closed => "closed",
            State::Rejected => "rejected",
            State::Abandoned => "abandoned",
            State::AssumptionsInvalidated => "assumptions_invalidated",
        }
    }

    /// Parse a canonical class string (the inverse of [`State::as_str`]).
    #[must_use]
    pub fn from_class(s: &str) -> Option<Self> {
        Some(match s {
            "proposed" => State::Proposed,
            "ready" => State::Ready,
            "active" => State::Active,
            "parked" => State::Parked,
            "claimed_done" => State::ClaimedDone,
            "verified_done" => State::VerifiedDone,
            "closed" => State::Closed,
            "rejected" => State::Rejected,
            "abandoned" => State::Abandoned,
            "assumptions_invalidated" => State::AssumptionsInvalidated,
            _ => return None,
        })
    }

    /// Terminal states have no outgoing transitions.
    #[must_use]
    pub fn is_terminal(self) -> bool {
        matches!(self, State::Closed | State::Rejected | State::Abandoned)
    }
}

/// Whether `from → to` is a legal lifecycle transition (v2 §2.2 table). This is
/// state-shape validity only; the per-edge ACTOR gating (who may perform each
/// edge — e.g. `ClaimedDone → VerifiedDone` is never the doer) is a separate
/// layer (slice 4b).
#[must_use]
pub fn can_transition(from: State, to: State) -> bool {
    use State::{
        Active, AssumptionsInvalidated, ClaimedDone, Closed, Parked, Proposed, Ready, Rejected,
        VerifiedDone,
    };
    if from.is_terminal() {
        return false;
    }
    if to == State::Abandoned {
        return true; // `* → Abandoned`: a human can kill in-flight work from any live state.
    }
    matches!(
        (from, to),
        (Proposed, Ready)
            | (Proposed, Rejected)
            | (Ready, Active)
            | (Active, Parked)
            | (Active, ClaimedDone)
            | (Active, Ready)
            | (Parked, Ready)
            | (Parked, Active)
            | (ClaimedDone, VerifiedDone)
            | (ClaimedDone, Active)
            | (VerifiedDone, Closed)
            | (VerifiedDone, AssumptionsInvalidated)
            | (AssumptionsInvalidated, Active)
    )
}

/// The kind of actor performing a transition (v2 §2.2 ownership). Matches the
/// `event_log.actor_kind` code: 0 human, 1 agent, 2 system.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActorKind {
    /// A human operator.
    Human,
    /// An autonomous agent.
    Agent,
    /// The orchestrator / runtime (lease expiry, escalation, routing).
    System,
}

impl ActorKind {
    /// The integer code stored in `event_log.actor_kind`.
    #[must_use]
    pub fn as_i64(self) -> i64 {
        match self {
            ActorKind::Human => 0,
            ActorKind::Agent => 1,
            ActorKind::System => 2,
        }
    }

    /// Parse an `event_log.actor_kind` code.
    #[must_use]
    pub fn from_i64(n: i64) -> Option<Self> {
        match n {
            0 => Some(ActorKind::Human),
            1 => Some(ActorKind::Agent),
            2 => Some(ActorKind::System),
            _ => None,
        }
    }
}

/// Whether `actor` may perform the `from → to` transition (v2 §2.2 ownership
/// table — the SAFETY boundary, "encoded as data so an autonomous loop cannot
/// skip a human gate even when instructed to"). Requires the transition be
/// shape-legal ([`can_transition`]) AND the actor's kind be permitted for that
/// edge.
///
/// Slice-4b scope: gates by actor KIND. Two finer guards are follow-ons (they
/// need the projection's `claimed_by`/`verified_by` + a policy flag): the
/// doer≠verifier IDENTITY check on `ClaimedDone → VerifiedDone` (here gated to
/// System, the orchestrated verifier), and the `Proposed → Ready` auto-admit
/// policy (here Human-only).
#[must_use]
pub fn can_actor_transition(actor: ActorKind, from: State, to: State) -> bool {
    use ActorKind::{Agent, Human, System};
    use State::{
        Abandoned, Active, AssumptionsInvalidated, ClaimedDone, Closed, Parked, Proposed, Ready,
        Rejected, VerifiedDone,
    };
    if !can_transition(from, to) {
        return false;
    }
    let allowed: &[ActorKind] = match (from, to) {
        (_, Abandoned) => &[Human],        // `* → Abandoned`: a human kill only
        (Proposed, Ready) => &[Human],     // admission gate (auto-admit policy: follow-on)
        (Proposed, Rejected) => &[Human],  // decline
        (Ready, Active) => &[Agent, System],
        (Active, Parked) => &[Agent, System],
        (Active, ClaimedDone) => &[Agent], // the doer's ceiling
        (Active, Ready) => &[System],      // lease-expiry requeue
        (Parked, Ready) | (Parked, Active) => &[System],
        (ClaimedDone, VerifiedDone) => &[System], // verifier (never the doer — identity guard follows)
        (ClaimedDone, Active) => &[Agent, Human], // verifier kickback
        (VerifiedDone, Closed) => &[Human, System],
        (VerifiedDone, AssumptionsInvalidated) => &[System],
        (AssumptionsInvalidated, Active) => &[Agent, System], // re-examine
        _ => &[],
    };
    allowed.contains(&actor)
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

/// Open (creating if absent) the on-disk store at `path`, running the idempotent
/// schema so an existing file is reused as-is and a new one is initialized. The
/// event log + projection persist across reopen (the store IS a file).
///
/// # Errors
/// Propagates any rusqlite open / DDL error.
pub fn open(path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
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

    /// On-disk: appended state survives closing + reopening the file (the event
    /// log + projection are durable). Uses the per-user temp dir (never
    /// ~/Documents); removes the file at start (clean slate) + end.
    #[test]
    fn on_disk_store_persists_across_reopen() -> rusqlite::Result<()> {
        let path = std::env::temp_dir().join("mdvcore-pm-ondisk-roundtrip.db");
        let _ = std::fs::remove_file(&path);
        {
            let mut conn = open(&path)?;
            append(&mut conn, 1, "human:jos", 0, &created("P1", "Persisted"))?;
        } // conn dropped → file closed
        let reopened = open(&path)?;
        let wi = get_work_item(&reopened, "P1")?;
        drop(reopened);
        let _ = std::fs::remove_file(&path);
        assert_eq!(wi.map(|w| w.state), Some("open".to_string()));
        Ok(())
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

    const ALL_STATES: [State; 10] = [
        State::Proposed,
        State::Ready,
        State::Active,
        State::Parked,
        State::ClaimedDone,
        State::VerifiedDone,
        State::Closed,
        State::Rejected,
        State::Abandoned,
        State::AssumptionsInvalidated,
    ];

    #[test]
    fn state_class_string_roundtrips() {
        for s in ALL_STATES {
            assert_eq!(State::from_class(s.as_str()), Some(s), "{s:?}");
        }
        assert_eq!(State::from_class("bogus"), None);
    }

    #[test]
    fn lifecycle_happy_path_is_legal() {
        assert!(can_transition(State::Proposed, State::Ready));
        assert!(can_transition(State::Ready, State::Active));
        assert!(can_transition(State::Active, State::ClaimedDone));
        assert!(can_transition(State::ClaimedDone, State::VerifiedDone));
        assert!(can_transition(State::VerifiedDone, State::Closed));
    }

    #[test]
    fn lifecycle_rejects_skips_and_terminals() {
        // Can't skip the Ready admission gate.
        assert!(!can_transition(State::Proposed, State::Active));
        // The doer never self-certifies: Active → VerifiedDone is illegal (goes via
        // ClaimedDone, then an independent verifier).
        assert!(!can_transition(State::Active, State::VerifiedDone));
        // Terminal states have no exits — not even to Abandoned.
        for t in [State::Closed, State::Rejected, State::Abandoned] {
            assert!(!can_transition(t, State::Active), "{t:?} is terminal");
            assert!(!can_transition(t, State::Abandoned), "{t:?} is terminal");
        }
    }

    #[test]
    fn any_live_state_can_be_abandoned() {
        for s in ALL_STATES.into_iter().filter(|s| !s.is_terminal()) {
            assert!(can_transition(s, State::Abandoned), "{s:?} → Abandoned");
        }
    }

    #[test]
    fn kickback_invalidation_and_requeue_edges() {
        assert!(can_transition(State::ClaimedDone, State::Active)); // verifier kickback
        assert!(can_transition(State::VerifiedDone, State::AssumptionsInvalidated));
        assert!(can_transition(State::AssumptionsInvalidated, State::Active)); // re-examine
        assert!(can_transition(State::Active, State::Ready)); // lease-expiry requeue
        assert!(can_transition(State::Parked, State::Active)); // resume
    }

    #[test]
    fn actor_gating_doer_ceiling_and_human_gates() {
        use ActorKind::{Agent, Human, System};
        // The doer (agent) proposes done — but can NEVER self-certify; the
        // (orchestrated) verifier does ClaimedDone → VerifiedDone.
        assert!(can_actor_transition(Agent, State::Active, State::ClaimedDone));
        assert!(!can_actor_transition(Agent, State::ClaimedDone, State::VerifiedDone));
        assert!(can_actor_transition(System, State::ClaimedDone, State::VerifiedDone));
        // Admission + rejection are human gates (an agent can't self-admit).
        assert!(can_actor_transition(Human, State::Proposed, State::Ready));
        assert!(!can_actor_transition(Agent, State::Proposed, State::Ready));
        assert!(!can_actor_transition(Agent, State::Proposed, State::Rejected));
        // Killing in-flight work is human-only.
        assert!(can_actor_transition(Human, State::Active, State::Abandoned));
        assert!(!can_actor_transition(Agent, State::Active, State::Abandoned));
        assert!(!can_actor_transition(System, State::Active, State::Abandoned));
    }

    #[test]
    fn actor_gating_requires_legal_shape() {
        // Even a human cannot perform a shape-illegal transition.
        assert!(!can_actor_transition(ActorKind::Human, State::Proposed, State::Active));
    }

    #[test]
    fn actor_kind_code_roundtrips() {
        for k in [ActorKind::Human, ActorKind::Agent, ActorKind::System] {
            assert_eq!(ActorKind::from_i64(k.as_i64()), Some(k), "{k:?}");
        }
        assert_eq!(ActorKind::from_i64(9), None);
    }
}
