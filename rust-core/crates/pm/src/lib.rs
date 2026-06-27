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

/// An error from a PM store mutation (slice 4d — lifecycle enforcement). The
/// `append` write path rejects an illegal/unauthorized transition with one of
/// these BEFORE touching the log or the projection.
#[derive(Debug)]
pub enum PmError {
    /// An underlying rusqlite/IO error.
    Sqlite(rusqlite::Error),
    /// A `StateChanged` targeted an id with no projection row.
    UnknownItem(String),
    /// A state string is not a recognized lifecycle class.
    UnknownState(String),
    /// `actor_kind` is not a recognized code (0 human / 1 agent / 2 system).
    UnknownActorKind(i64),
    /// The `from → to` transition is not a legal shape (v2 §2.2).
    IllegalTransition {
        /// Current state class.
        from: String,
        /// Attempted target class.
        to: String,
    },
    /// The actor kind may not perform this transition (the §2.2 safety boundary).
    Unauthorized {
        /// The rejected actor-kind code.
        actor_kind: i64,
        /// Current state class.
        from: String,
        /// Attempted target class.
        to: String,
    },
}

impl std::fmt::Display for PmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PmError::Sqlite(e) => write!(f, "sqlite: {e}"),
            PmError::UnknownItem(id) => write!(f, "unknown work item: {id}"),
            PmError::UnknownState(s) => write!(f, "unknown state class: {s}"),
            PmError::UnknownActorKind(k) => write!(f, "unknown actor kind: {k}"),
            PmError::IllegalTransition { from, to } => {
                write!(f, "illegal transition: {from} -> {to}")
            }
            PmError::Unauthorized {
                actor_kind,
                from,
                to,
            } => write!(f, "actor kind {actor_kind} may not transition {from} -> {to}"),
        }
    }
}

impl std::error::Error for PmError {}

impl From<rusqlite::Error> for PmError {
    fn from(e: rusqlite::Error) -> Self {
        PmError::Sqlite(e)
    }
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
) -> Result<i64, PmError> {
    // Slice 4d: ENFORCE the lifecycle before mutating. A Created's initial state
    // must be a known class; a StateChanged must be a shape-legal transition the
    // actor's kind is permitted to make (the §2.2 safety boundary). On rejection
    // nothing is written (the early return precedes the transaction).
    match event {
        WorkItemEvent::Created { state, .. } => {
            State::from_class(state).ok_or_else(|| PmError::UnknownState(state.clone()))?;
        }
        WorkItemEvent::StateChanged { id, state: to, .. } => {
            let current =
                get_work_item(conn, id)?.ok_or_else(|| PmError::UnknownItem(id.clone()))?;
            let from = State::from_class(&current.state)
                .ok_or_else(|| PmError::UnknownState(current.state.clone()))?;
            let to_state =
                State::from_class(to).ok_or_else(|| PmError::UnknownState(to.clone()))?;
            let actor =
                ActorKind::from_i64(actor_kind).ok_or(PmError::UnknownActorKind(actor_kind))?;
            if !can_transition(from, to_state) {
                return Err(PmError::IllegalTransition {
                    from: from.as_str().into(),
                    to: to_state.as_str().into(),
                });
            }
            if !can_actor_transition(actor, from, to_state) {
                return Err(PmError::Unauthorized {
                    actor_kind,
                    from: from.as_str().into(),
                    to: to_state.as_str().into(),
                });
            }
        }
    }
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

/// The dispatchable queue: work items in the `Ready` state, FIFO by creation —
/// the v2 "next ready task" primitive. Priority + dependency ordering is a
/// follow-on (needs the edge schema); this returns the Ready set in stable order.
///
/// # Errors
/// Propagates any rusqlite query error.
pub fn work_next(conn: &Connection) -> rusqlite::Result<Vec<WorkItem>> {
    let mut stmt = conn.prepare(
        "SELECT id, title, state, created_seq, updated_seq FROM work_item
         WHERE state = ?1 ORDER BY created_seq",
    )?;
    let rows = stmt.query_map([State::Ready.as_str()], |r| {
        Ok(WorkItem {
            id: r.get(0)?,
            title: r.get(1)?,
            state: r.get(2)?,
            created_seq: r.get(3)?,
            updated_seq: r.get(4)?,
        })
    })?;
    rows.collect()
}

/// Count of work items per state class — the roll-up for a progress dashboard.
/// Ordered by state for a stable result.
///
/// # Errors
/// Propagates any rusqlite query error.
pub fn state_rollup(conn: &Connection) -> rusqlite::Result<Vec<(String, i64)>> {
    let mut stmt =
        conn.prepare("SELECT state, COUNT(*) FROM work_item GROUP BY state ORDER BY state")?;
    let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn created(id: &str, title: &str) -> WorkItemEvent {
        WorkItemEvent::Created {
            id: id.into(),
            title: title.into(),
            state: State::Proposed.as_str().into(),
        }
    }

    /// On-disk: appended state survives closing + reopening the file (the event
    /// log + projection are durable). Uses the per-user temp dir (never
    /// ~/Documents); removes the file at start (clean slate) + end.
    #[test]
    fn on_disk_store_persists_across_reopen() -> Result<(), PmError> {
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
        assert_eq!(wi.map(|w| w.state), Some("proposed".to_string()));
        Ok(())
    }

    /// append() folds an event into the projection atomically; a later
    /// StateChanged updates it (and bumps updated_seq, not created_seq).
    #[test]
    fn append_projects_create_then_state_change() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        let s1 = append(&mut conn, 1, "human:jos", 0, &created("T1", "Task one"))?;
        // Proposed → Ready: the human admission gate.
        let s2 = append(
            &mut conn,
            2,
            "human:jos",
            0,
            &WorkItemEvent::StateChanged {
                id: "T1".into(),
                state: State::Ready.as_str().into(),
                reason: "groomed".into(),
            },
        )?;
        let wi = get_work_item(&conn, "T1")?;
        assert_eq!(
            wi,
            Some(WorkItem {
                id: "T1".into(),
                title: "Task one".into(),
                state: "ready".into(),
                created_seq: s1,
                updated_seq: s2,
            })
        );
        Ok(())
    }

    /// The v2 invariant: replay() rebuilds the projection from the log alone, and
    /// the result is byte-identical to the live-folded projection.
    #[test]
    fn replay_reproduces_projection_exactly() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "human:jos", 0, &created("A", "Alpha"))?;
        append(&mut conn, 2, "human:jos", 0, &created("B", "Beta"))?;
        append(
            &mut conn,
            3,
            "human:jos",
            0,
            &WorkItemEvent::StateChanged {
                id: "A".into(),
                state: State::Ready.as_str().into(),
                reason: "groomed".into(),
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
    fn state_change_unknown_id_is_rejected() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        let err = append(
            &mut conn,
            1,
            "human:jos",
            0,
            &WorkItemEvent::StateChanged {
                id: "ghost".into(),
                state: State::Ready.as_str().into(),
                reason: "n/a".into(),
            },
        );
        assert!(matches!(err, Err(PmError::UnknownItem(ref id)) if id == "ghost"));
        // Enforcement rejects BEFORE writing — nothing is logged.
        let logged: i64 = conn.query_row("SELECT COUNT(*) FROM event_log", [], |r| r.get(0))?;
        assert_eq!(logged, 0, "a rejected event is not logged");
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

    fn created_in(id: &str, state: State) -> WorkItemEvent {
        WorkItemEvent::Created {
            id: id.into(),
            title: id.into(),
            state: state.as_str().into(),
        }
    }

    #[test]
    fn work_next_returns_ready_items_in_fifo() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "h", 0, &created_in("A", State::Ready))?;
        append(&mut conn, 2, "h", 0, &created_in("B", State::Active))?;
        append(&mut conn, 3, "h", 0, &created_in("C", State::Ready))?;
        let ids: Vec<String> = work_next(&conn)?.into_iter().map(|w| w.id).collect();
        assert_eq!(ids, vec!["A", "C"]); // only Ready, FIFO by creation
        Ok(())
    }

    #[test]
    fn state_rollup_counts_by_class() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "h", 0, &created_in("A", State::Ready))?;
        append(&mut conn, 2, "h", 0, &created_in("B", State::Ready))?;
        append(&mut conn, 3, "h", 0, &created_in("C", State::Active))?;
        assert_eq!(
            state_rollup(&conn)?,
            vec![("active".to_string(), 1_i64), ("ready".to_string(), 2_i64)]
        );
        Ok(())
    }

    #[test]
    fn append_rejects_illegal_transition() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "human:jos", 0, &created("T", "t"))?; // Proposed
        // Proposed → Active skips the Ready admission gate (illegal shape).
        let err = append(
            &mut conn,
            2,
            "agent:x",
            1,
            &WorkItemEvent::StateChanged {
                id: "T".into(),
                state: State::Active.as_str().into(),
                reason: "skip".into(),
            },
        );
        assert!(matches!(err, Err(PmError::IllegalTransition { .. })));
        // Rejected → state unchanged.
        assert_eq!(get_work_item(&conn, "T")?.map(|w| w.state), Some("proposed".into()));
        Ok(())
    }

    #[test]
    fn append_rejects_unauthorized_actor() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "human:jos", 0, &created("T", "t"))?; // Proposed
        // Proposed → Ready is shape-legal but HUMAN-only; an agent (kind 1) is unauthorized.
        let err = append(
            &mut conn,
            2,
            "agent:x",
            1,
            &WorkItemEvent::StateChanged {
                id: "T".into(),
                state: State::Ready.as_str().into(),
                reason: "self-admit".into(),
            },
        );
        assert!(matches!(err, Err(PmError::Unauthorized { .. })));
        Ok(())
    }
}
