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
    updated_seq INTEGER NOT NULL,
    claimed_by  TEXT
);
CREATE TABLE IF NOT EXISTS wi_edge (
    from_id TEXT NOT NULL,
    to_id   TEXT NOT NULL,
    kind    INTEGER NOT NULL,
    PRIMARY KEY (from_id, to_id, kind),
    CHECK (from_id <> to_id)
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
    /// A relationship edge was added — so edges are event-sourced + replayable (a
    /// projection of the log, per v2 §2.4), not a silent direct mutation.
    EdgeAdded {
        /// The dependent / source end.
        from: String,
        /// The dependency / target end.
        to: String,
        /// The `EdgeKind` code (0 depends_on / 1 consumes / 2 touches).
        kind: i64,
    },
}

/// A materialized work item — one row of the current-state projection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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
    /// The actor that last claimed it (set on entry to `Active`) — the doer, for
    /// the doer≠verifier guard (v2 §1.4). `None` until first claimed.
    pub claimed_by: Option<String>,
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
    /// The verifier of `ClaimedDone → VerifiedDone` is the same actor that claimed
    /// the item — an actor can never certify its own work (v2 §1.4).
    SelfVerify {
        /// The work item.
        id: String,
        /// The actor that both claimed and tried to verify.
        actor: String,
    },
    /// A `DependsOn` edge would create a cycle (rejected transactionally, v2 §1.7).
    DependencyCycle {
        /// The dependent end of the rejected edge.
        from: String,
        /// The dependency end of the rejected edge.
        to: String,
    },
    /// A wire `AddEdge` request carried an unrecognized edge-kind code.
    UnknownEdgeKind(i64),
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
            PmError::SelfVerify { id, actor } => {
                write!(f, "actor {actor} may not verify its own claimed work item {id}")
            }
            PmError::DependencyCycle { from, to } => {
                write!(f, "depends_on {from} -> {to} would create a cycle")
            }
            PmError::UnknownEdgeKind(k) => write!(f, "unknown edge kind: {k}"),
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
            // §1.4: the verifier must not be the actor that claimed the item.
            if to_state == State::VerifiedDone && current.claimed_by.as_deref() == Some(actor_id) {
                return Err(PmError::SelfVerify {
                    id: id.clone(),
                    actor: actor_id.to_owned(),
                });
            }
        }
        // Structural; validated by add_edge's cycle/existence checks before append.
        WorkItemEvent::EdgeAdded { .. } => {}
    }
    let payload = rmp_serde::to_vec(event)
        .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    let (event_type, subject_id, reason): (&str, &str, Option<&str>) = match event {
        WorkItemEvent::Created { id, .. } => ("work_item.created", id, None),
        WorkItemEvent::StateChanged { id, reason, .. } => {
            ("work_item.state_changed", id, Some(reason))
        }
        WorkItemEvent::EdgeAdded { from, .. } => ("edge.added", from, None),
    };
    let tx = conn.transaction()?;
    tx.execute(
        "INSERT INTO event_log (ts, actor_id, actor_kind, event_type, subject_id, reason, payload)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![ts, actor_id, actor_kind, event_type, subject_id, reason, payload],
    )?;
    let seq = tx.last_insert_rowid();
    apply_to_projection(&tx, seq, actor_id, event)?;
    // §1.7 reverse-ripple: invalidating an item cascades to its VerifiedDone
    // consumers (logged system events, same tx → replay-deterministic).
    if let WorkItemEvent::StateChanged { id, state, .. } = event
        && State::from_class(state) == Some(State::AssumptionsInvalidated)
    {
        cascade_invalidation(&tx, id, ts)?;
    }
    tx.commit()?;
    Ok(seq)
}

/// Fold one event into the current-state projection (used by both `append` and
/// `replay`, so the projection logic lives in exactly one place).
fn apply_to_projection(
    tx: &rusqlite::Transaction<'_>,
    seq: i64,
    actor_id: &str,
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
            // Record the claimer on entry to Active (the doer, for the §1.4 guard).
            if State::from_class(state) == Some(State::Active) {
                tx.execute(
                    "UPDATE work_item SET state = ?2, updated_seq = ?3, claimed_by = ?4 WHERE id = ?1",
                    rusqlite::params![id, state, seq, actor_id],
                )?;
            } else {
                tx.execute(
                    "UPDATE work_item SET state = ?2, updated_seq = ?3 WHERE id = ?1",
                    rusqlite::params![id, state, seq],
                )?;
            }
        }
        WorkItemEvent::EdgeAdded { from, to, kind } => {
            tx.execute(
                "INSERT OR IGNORE INTO wi_edge (from_id, to_id, kind) VALUES (?1, ?2, ?3)",
                rusqlite::params![from, to, kind],
            )?;
        }
    }
    Ok(())
}

/// §1.7 reverse-ripple: when `root_id`'s output is invalidated, every transitive
/// VerifiedDone CONSUMER of it auto-transitions to `assumptions_invalidated`. Each
/// is a SYSTEM-actor event appended to the log IN THE SAME TRANSACTION — so the
/// cascade is audited and replay-deterministic (replay re-applies these logged
/// events; it never re-derives the cascade). The affected set is computed once
/// (a recursive CTE over consumes-edges through VerifiedDone items) before any
/// update, so the traversal sees pre-cascade states.
fn cascade_invalidation(
    tx: &rusqlite::Transaction<'_>,
    root_id: &str,
    ts: i64,
) -> rusqlite::Result<()> {
    let affected: Vec<String> = {
        let mut stmt = tx.prepare(
            "WITH RECURSIVE aff(id) AS (
                 SELECT e.from_id FROM wi_edge e JOIN work_item w ON w.id = e.from_id
                  WHERE e.to_id = ?1 AND e.kind = 1 AND w.state = 'verified_done'
                 UNION
                 SELECT e.from_id FROM wi_edge e JOIN work_item w ON w.id = e.from_id
                  JOIN aff a ON e.to_id = a.id
                  WHERE e.kind = 1 AND w.state = 'verified_done'
             )
             SELECT id FROM aff",
        )?;
        let rows = stmt.query_map([root_id], |r| r.get(0))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    for consumer in affected {
        let ev = WorkItemEvent::StateChanged {
            id: consumer.clone(),
            state: State::AssumptionsInvalidated.as_str().to_owned(),
            reason: "upstream output invalidated".to_owned(),
        };
        let payload = rmp_serde::to_vec(&ev)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
        tx.execute(
            "INSERT INTO event_log (ts, actor_id, actor_kind, event_type, subject_id, reason, payload)
             VALUES (?1, 'system', 2, 'work_item.state_changed', ?2, 'upstream output invalidated', ?3)",
            rusqlite::params![ts, consumer, payload],
        )?;
        let cseq = tx.last_insert_rowid();
        apply_to_projection(tx, cseq, "system", &ev)?;
    }
    Ok(())
}

/// The current projected state of one work item, or `None` if unknown.
///
/// # Errors
/// Propagates any rusqlite query error.
pub fn get_work_item(conn: &Connection, id: &str) -> rusqlite::Result<Option<WorkItem>> {
    conn.query_row(
        "SELECT id, title, state, created_seq, updated_seq, claimed_by FROM work_item WHERE id = ?1",
        [id],
        |r| {
            Ok(WorkItem {
                id: r.get(0)?,
                title: r.get(1)?,
                state: r.get(2)?,
                created_seq: r.get(3)?,
                updated_seq: r.get(4)?,
                claimed_by: r.get(5)?,
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
    let events: Vec<(i64, String, Vec<u8>)> = {
        let mut stmt =
            conn.prepare("SELECT seq, actor_id, payload FROM event_log ORDER BY seq")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    let tx = conn.transaction()?;
    tx.execute_batch("DELETE FROM work_item; DELETE FROM wi_edge")?;
    for (seq, actor_id, payload) in events {
        let event: WorkItemEvent = rmp_serde::from_slice(&payload).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Blob, Box::new(e))
        })?;
        apply_to_projection(&tx, seq, &actor_id, &event)?;
    }
    tx.commit()?;
    Ok(())
}

/// The dispatchable queue: `Ready` work items whose depends_on prerequisites are
/// ALL finished (VerifiedDone or Closed), FIFO by creation — the v2 "next ready
/// task" primitive with the §1.7 finish-to-start gate. Priority ordering is a
/// follow-on; this returns the unblocked Ready set in stable order.
///
/// # Errors
/// Propagates any rusqlite query error.
pub fn work_next(conn: &Connection) -> rusqlite::Result<Vec<WorkItem>> {
    // `verified_done`/`closed` are the State::as_str() forms of the finished
    // classes — a depends_on prerequisite in any other state blocks the dependent.
    let mut stmt = conn.prepare(
        "SELECT id, title, state, created_seq, updated_seq, claimed_by FROM work_item w
         WHERE w.state = ?1
           AND NOT EXISTS (
             SELECT 1 FROM wi_edge e JOIN work_item dep ON dep.id = e.to_id
             WHERE e.from_id = w.id AND e.kind = 0
               AND dep.state NOT IN ('verified_done', 'closed')
           )
         ORDER BY w.created_seq",
    )?;
    let rows = stmt.query_map([State::Ready.as_str()], |r| {
        Ok(WorkItem {
            id: r.get(0)?,
            title: r.get(1)?,
            state: r.get(2)?,
            created_seq: r.get(3)?,
            updated_seq: r.get(4)?,
            claimed_by: r.get(5)?,
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

/// A relationship edge kind between work items (v2 §2.4). Only `DependsOn` is
/// kept acyclic; `Consumes`/`Touches` may form any graph.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdgeKind {
    /// Finish-to-start ordering — `from` needs `to` done first.
    DependsOn,
    /// `from` consumes `to`'s output (ripples on change, §1.7).
    Consumes,
    /// `from` and `to` touch the same surface (contention).
    Touches,
}

impl EdgeKind {
    /// The integer code stored in `wi_edge.kind`.
    #[must_use]
    pub fn as_i64(self) -> i64 {
        match self {
            EdgeKind::DependsOn => 0,
            EdgeKind::Consumes => 1,
            EdgeKind::Touches => 2,
        }
    }

    /// Parse a `wi_edge.kind` code.
    #[must_use]
    pub fn from_i64(n: i64) -> Option<Self> {
        match n {
            0 => Some(EdgeKind::DependsOn),
            1 => Some(EdgeKind::Consumes),
            2 => Some(EdgeKind::Touches),
            _ => None,
        }
    }
}

/// Add a relationship edge `from → to`. For `DependsOn`, rejects an edge that
/// would create a cycle (the v2 invariant: a dependency cycle is rejected
/// transactionally, never silently written). Both items must already exist.
/// Idempotent — a duplicate edge is ignored.
///
/// # Errors
/// `UnknownItem` (either id absent), `DependencyCycle` (a self-edge or a
/// closing `DependsOn` cycle), or `Sqlite`.
pub fn add_edge(
    conn: &mut Connection,
    ts: i64,
    actor_id: &str,
    actor_kind: i64,
    from: &str,
    to: &str,
    kind: EdgeKind,
) -> Result<(), PmError> {
    if from == to {
        return Err(PmError::DependencyCycle {
            from: from.to_owned(),
            to: to.to_owned(),
        });
    }
    get_work_item(conn, from)?.ok_or_else(|| PmError::UnknownItem(from.to_owned()))?;
    get_work_item(conn, to)?.ok_or_else(|| PmError::UnknownItem(to.to_owned()))?;
    if kind == EdgeKind::DependsOn {
        // Would from→to close a cycle? I.e. can `to` already reach `from` along
        // existing depends_on edges?
        let closes_cycle: bool = conn.query_row(
            "WITH RECURSIVE reach(id) AS (
                 SELECT to_id FROM wi_edge WHERE from_id = ?1 AND kind = 0
                 UNION
                 SELECT e.to_id FROM wi_edge e JOIN reach r ON e.from_id = r.id WHERE e.kind = 0
             )
             SELECT EXISTS(SELECT 1 FROM reach WHERE id = ?2)",
            rusqlite::params![to, from],
            |r| r.get(0),
        )?;
        if closes_cycle {
            return Err(PmError::DependencyCycle {
                from: from.to_owned(),
                to: to.to_owned(),
            });
        }
    }
    // Event-sourced (slice 4h): the edge is a logged EdgeAdded event applied to
    // the projection — so it rebuilds on replay (was a direct mutation in 4f).
    append(
        conn,
        ts,
        actor_id,
        actor_kind,
        &WorkItemEvent::EdgeAdded {
            from: from.to_owned(),
            to: to.to_owned(),
            kind: kind.as_i64(),
        },
    )?;
    Ok(())
}

/// The ids `id` directly depends_on (its finish-to-start prerequisites).
///
/// # Errors
/// Propagates any rusqlite query error.
pub fn depends_on(conn: &Connection, id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt =
        conn.prepare("SELECT to_id FROM wi_edge WHERE from_id = ?1 AND kind = 0 ORDER BY to_id")?;
    let rows = stmt.query_map([id], |r| r.get(0))?;
    rows.collect()
}

/// The ids that directly depend on `id` (the reverse of [`depends_on`]) — impact
/// analysis: "what is blocked by this?".
///
/// # Errors
/// Propagates any rusqlite query error.
pub fn dependents_of(conn: &Connection, id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt =
        conn.prepare("SELECT from_id FROM wi_edge WHERE to_id = ?1 AND kind = 0 ORDER BY from_id")?;
    let rows = stmt.query_map([id], |r| r.get(0))?;
    rows.collect()
}

/// The ids that consume `id`'s output (the reverse of a `Consumes` edge). When
/// `id`'s output changes these are the items whose assumptions may be invalidated
/// — the §1.7 reverse-ripple set (the auto-cascade transition is a later slice).
///
/// # Errors
/// Propagates any rusqlite query error.
pub fn consumers_of(conn: &Connection, id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt =
        conn.prepare("SELECT from_id FROM wi_edge WHERE to_id = ?1 AND kind = 1 ORDER BY from_id")?;
    let rows = stmt.query_map([id], |r| r.get(0))?;
    rows.collect()
}

/// A wire request to the PM store — the FFI / remote protocol (msgpack),
/// mirroring the typed API. The stateful `Connection` stays the caller's.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PmRequest {
    /// Append a typed event (Created / StateChanged / EdgeAdded) with provenance.
    Append {
        ts: i64,
        actor_id: String,
        actor_kind: i64,
        event: WorkItemEvent,
    },
    /// Add a relationship edge (a depends_on cycle is rejected).
    AddEdge {
        ts: i64,
        actor_id: String,
        actor_kind: i64,
        from: String,
        to: String,
        kind: i64,
    },
    /// Current projected state of one item.
    GetWorkItem { id: String },
    /// The dependency-gated Ready dispatch queue.
    WorkNext,
    /// Count of items per state class.
    StateRollup,
    /// An item's depends_on prerequisites.
    DependsOn { id: String },
    /// Items that depend on an item.
    DependentsOf { id: String },
    /// Items that consume an item's output.
    ConsumersOf { id: String },
}

/// A wire response from [`dispatch`]; `Error` carries a [`PmError`] display string.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum PmResponse {
    /// An append succeeded; the new event `seq`.
    Appended { seq: i64 },
    /// A unit op succeeded.
    Ok,
    /// A single (optional) work item.
    Item(Option<WorkItem>),
    /// A list of work items.
    Items(Vec<WorkItem>),
    /// A state roll-up (class, count).
    Rollup(Vec<(String, i64)>),
    /// A list of ids.
    Ids(Vec<String>),
    /// The operation failed (a `PmError` display string).
    Error(String),
}

/// Execute a [`PmRequest`], mapping any [`PmError`] to [`PmResponse::Error`] so
/// the wire never surfaces a domain error as a panic.
#[must_use]
pub fn dispatch(conn: &mut Connection, req: PmRequest) -> PmResponse {
    dispatch_inner(conn, req).unwrap_or_else(|e| PmResponse::Error(e.to_string()))
}

fn dispatch_inner(conn: &mut Connection, req: PmRequest) -> Result<PmResponse, PmError> {
    Ok(match req {
        PmRequest::Append {
            ts,
            actor_id,
            actor_kind,
            event,
        } => PmResponse::Appended {
            seq: append(conn, ts, &actor_id, actor_kind, &event)?,
        },
        PmRequest::AddEdge {
            ts,
            actor_id,
            actor_kind,
            from,
            to,
            kind,
        } => {
            let k = EdgeKind::from_i64(kind).ok_or(PmError::UnknownEdgeKind(kind))?;
            add_edge(conn, ts, &actor_id, actor_kind, &from, &to, k)?;
            PmResponse::Ok
        }
        PmRequest::GetWorkItem { id } => PmResponse::Item(get_work_item(conn, &id)?),
        PmRequest::WorkNext => PmResponse::Items(work_next(conn)?),
        PmRequest::StateRollup => PmResponse::Rollup(state_rollup(conn)?),
        PmRequest::DependsOn { id } => PmResponse::Ids(depends_on(conn, &id)?),
        PmRequest::DependentsOf { id } => PmResponse::Ids(dependents_of(conn, &id)?),
        PmRequest::ConsumersOf { id } => PmResponse::Ids(consumers_of(conn, &id)?),
    })
}

/// MessagePack wrapper around [`dispatch`] for the FFI / remote boundary: decode a
/// `PmRequest` frame, run it, encode the `PmResponse`. A decode failure becomes a
/// `PmResponse::Error`; the `Result` is only for a hard encode failure.
///
/// # Errors
/// Propagates an rmp-serde ENCODE failure of the response frame.
pub fn dispatch_bytes(
    conn: &mut Connection,
    req_bytes: &[u8],
) -> Result<Vec<u8>, rmp_serde::encode::Error> {
    let resp = match rmp_serde::from_slice::<PmRequest>(req_bytes) {
        Ok(req) => dispatch(conn, req),
        Err(e) => PmResponse::Error(format!("decode: {e}")),
    };
    rmp_serde::to_vec(&resp)
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
                claimed_by: None,
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
    fn actor_gating_subset_of_shape_legality_exhaustive() {
        // The §2.2 SAFETY boundary, exhaustively: NO actor may perform a shape-
        // illegal transition (can_actor_transition ⊆ can_transition over every
        // actor × from × to). Holds by construction today (the fn early-returns on
        // !can_transition), so this GUARDS that construction against a future
        // refactor that drops the shape check — strengthening the single-example
        // `actor_gating_requires_legal_shape` above to the full space.
        for actor in [ActorKind::Human, ActorKind::Agent, ActorKind::System] {
            for from in ALL_STATES {
                for to in ALL_STATES {
                    if can_actor_transition(actor, from, to) {
                        assert!(
                            can_transition(from, to),
                            "{actor:?} permitted shape-ILLEGAL {from:?} -> {to:?}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn every_legal_transition_has_a_permitted_actor() {
        // The two §2.2 tables — `can_transition` (shape) and `can_actor_transition`'s
        // `allowed` set (ownership) — are maintained as SEPARATE matches. A shape-
        // legal edge whose `allowed` set is empty (the `_ => &[]` fall-through) is a
        // DEAD edge: the lifecycle can never traverse it. This guards that drift —
        // every legal transition must have at least one actor who can perform it.
        for from in ALL_STATES {
            for to in ALL_STATES {
                if can_transition(from, to) {
                    let has_actor = [ActorKind::Human, ActorKind::Agent, ActorKind::System]
                        .into_iter()
                        .any(|a| can_actor_transition(a, from, to));
                    assert!(
                        has_actor,
                        "shape-legal {from:?} -> {to:?} has NO permitted actor (dead edge: \
                         can_transition and the allowed-actor table drifted)"
                    );
                }
            }
        }
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

    fn edge(conn: &mut Connection, from: &str, to: &str, kind: EdgeKind) -> Result<(), PmError> {
        add_edge(conn, 0, "tester", 0, from, to, kind)
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

    /// The §1.4 capstone: an actor cannot verify its own work. Drive a full
    /// lifecycle to ClaimedDone (claimed_by recorded on entry to Active), then the
    /// doer's self-verify is rejected while a DISTINCT verifier succeeds.
    #[test]
    fn doer_cannot_self_verify_distinct_verifier_can() -> Result<(), PmError> {
        fn advance(
            c: &mut Connection,
            ts: i64,
            who: &str,
            kind: i64,
            to: State,
        ) -> Result<i64, PmError> {
            append(
                c,
                ts,
                who,
                kind,
                &WorkItemEvent::StateChanged {
                    id: "T".into(),
                    state: to.as_str().into(),
                    reason: "step".into(),
                },
            )
        }
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "human:jos", 0, &created("T", "t"))?; // Proposed
        advance(&mut conn, 2, "human:jos", 0, State::Ready)?; // human admits
        advance(&mut conn, 3, "agent:worker", 1, State::Active)?; // agent claims → claimed_by
        advance(&mut conn, 4, "agent:worker", 1, State::ClaimedDone)?; // doer proposes done
        assert_eq!(
            get_work_item(&conn, "T")?.and_then(|w| w.claimed_by),
            Some("agent:worker".to_string()),
            "claimed_by recorded on entry to Active"
        );
        // The doer cannot certify its own work (even acting as a System verifier).
        let self_v = advance(&mut conn, 5, "agent:worker", 2, State::VerifiedDone);
        assert!(matches!(self_v, Err(PmError::SelfVerify { .. })));
        // A DISTINCT verifier succeeds.
        advance(&mut conn, 6, "system:ci", 2, State::VerifiedDone)?;
        assert_eq!(
            get_work_item(&conn, "T")?.map(|w| w.state),
            Some("verified_done".to_string())
        );
        Ok(())
    }

    #[test]
    fn add_edge_and_query_depends_on() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "h", 0, &created("A", "a"))?;
        append(&mut conn, 2, "h", 0, &created("B", "b"))?;
        edge(&mut conn, "A", "B", EdgeKind::DependsOn)?; // A depends on B
        assert_eq!(depends_on(&conn, "A")?, vec!["B".to_string()]);
        assert!(depends_on(&conn, "B")?.is_empty());
        Ok(())
    }

    #[test]
    fn add_edge_rejects_self_and_dependency_cycle() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        for id in ["A", "B", "C"] {
            append(&mut conn, 1, "h", 0, &created(id, id))?;
        }
        // self-dependency rejected
        assert!(matches!(
            edge(&mut conn, "A", "A", EdgeKind::DependsOn),
            Err(PmError::DependencyCycle { .. })
        ));
        // a chain A→B→C is fine
        edge(&mut conn, "A", "B", EdgeKind::DependsOn)?;
        edge(&mut conn, "B", "C", EdgeKind::DependsOn)?;
        // closing the cycle (C depends_on A) is rejected
        assert!(matches!(
            edge(&mut conn, "C", "A", EdgeKind::DependsOn),
            Err(PmError::DependencyCycle { .. })
        ));
        // a non-depends_on edge closing the same shape is allowed (only depends_on is acyclic)
        edge(&mut conn, "C", "A", EdgeKind::Touches)?;
        Ok(())
    }

    #[test]
    fn add_edge_unknown_item_rejected() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "h", 0, &created("A", "a"))?;
        assert!(matches!(
            edge(&mut conn, "A", "ghost", EdgeKind::DependsOn),
            Err(PmError::UnknownItem(_))
        ));
        Ok(())
    }

    #[test]
    fn work_next_excludes_items_with_unfinished_deps() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "h", 0, &created_in("A", State::Ready))?;
        append(&mut conn, 2, "h", 0, &created_in("B", State::Ready))?;
        edge(&mut conn, "A", "B", EdgeKind::DependsOn)?; // A depends on B (not finished)
        let ids: Vec<String> = work_next(&conn)?.into_iter().map(|w| w.id).collect();
        assert_eq!(ids, vec!["B"], "A is blocked by unfinished B; B is dispatchable");
        Ok(())
    }

    #[test]
    fn work_next_includes_items_with_finished_deps() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "h", 0, &created_in("A", State::Ready))?;
        append(&mut conn, 2, "h", 0, &created_in("B", State::VerifiedDone))?; // dep already finished
        edge(&mut conn, "A", "B", EdgeKind::DependsOn)?;
        let ids: Vec<String> = work_next(&conn)?.into_iter().map(|w| w.id).collect();
        assert_eq!(ids, vec!["A"], "A unblocks once its only dep is verified_done");
        Ok(())
    }

    #[test]
    fn reverse_edge_queries_for_impact_analysis() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        for id in ["A", "B", "C"] {
            append(&mut conn, 1, "h", 0, &created(id, id))?;
        }
        edge(&mut conn, "A", "C", EdgeKind::DependsOn)?; // A depends on C
        edge(&mut conn, "B", "C", EdgeKind::Consumes)?; // B consumes C
        assert_eq!(dependents_of(&conn, "C")?, vec!["A".to_string()]);
        assert_eq!(consumers_of(&conn, "C")?, vec!["B".to_string()]);
        assert!(dependents_of(&conn, "A")?.is_empty());
        assert!(consumers_of(&conn, "A")?.is_empty());
        Ok(())
    }

    #[test]
    fn invalidation_cascades_to_verified_done_consumers() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "h", 0, &created_in("X", State::VerifiedDone))?;
        append(&mut conn, 2, "h", 0, &created_in("B", State::VerifiedDone))?;
        append(&mut conn, 3, "h", 0, &created_in("C", State::Ready))?; // consumes B but not finished
        edge(&mut conn, "B", "X", EdgeKind::Consumes)?; // B consumes X
        edge(&mut conn, "C", "B", EdgeKind::Consumes)?; // C consumes B
        // X's output is invalidated (VerifiedDone → AssumptionsInvalidated, System).
        append(
            &mut conn,
            4,
            "system:ci",
            2,
            &WorkItemEvent::StateChanged {
                id: "X".into(),
                state: State::AssumptionsInvalidated.as_str().into(),
                reason: "edited".into(),
            },
        )?;
        // B (a VerifiedDone consumer of X) is cascaded; C (Ready, not finished) is NOT.
        assert_eq!(
            get_work_item(&conn, "B")?.map(|w| w.state),
            Some("assumptions_invalidated".to_string())
        );
        assert_eq!(get_work_item(&conn, "C")?.map(|w| w.state), Some("ready".to_string()));
        // The cascade emitted a logged system event for B.
        let n: i64 = conn.query_row(
            "SELECT COUNT(*) FROM event_log WHERE subject_id = 'B' AND actor_id = 'system'",
            [],
            |r| r.get(0),
        )?;
        assert_eq!(n, 1, "cascade is logged, not a silent projection edit");
        // Replay reproduces the cascaded state (it's in the log).
        let before_b = get_work_item(&conn, "B")?;
        replay(&mut conn)?;
        assert_eq!(get_work_item(&conn, "B")?, before_b, "cascade survives replay");
        Ok(())
    }

    #[test]
    fn edges_rebuild_on_replay() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        append(&mut conn, 1, "h", 0, &created("A", "a"))?;
        append(&mut conn, 2, "h", 0, &created("B", "b"))?;
        edge(&mut conn, "A", "B", EdgeKind::DependsOn)?;
        assert_eq!(depends_on(&conn, "A")?, vec!["B".to_string()]);
        // replay wipes work_item AND wi_edge, then rebuilds both from the log.
        replay(&mut conn)?;
        assert_eq!(
            depends_on(&conn, "A")?,
            vec!["B".to_string()],
            "edges are event-sourced — they rebuild from EdgeAdded events"
        );
        Ok(())
    }

    #[test]
    fn wire_dispatch_matches_direct_api() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        let appended = dispatch(
            &mut conn,
            PmRequest::Append {
                ts: 1,
                actor_id: "h".into(),
                actor_kind: 0,
                event: created_in("A", State::Ready),
            },
        );
        assert!(matches!(appended, PmResponse::Appended { seq: 1 }));
        // The wire WorkNext equals the direct work_next().
        let wire = dispatch(&mut conn, PmRequest::WorkNext);
        let direct = work_next(&conn)?;
        assert_eq!(wire, PmResponse::Items(direct));
        Ok(())
    }

    #[test]
    fn wire_maps_domain_error_to_error_response() -> Result<(), PmError> {
        let mut conn = open_in_memory()?;
        // A StateChanged on an unknown item → PmError::UnknownItem → Error response.
        let r = dispatch(
            &mut conn,
            PmRequest::Append {
                ts: 1,
                actor_id: "h".into(),
                actor_kind: 0,
                event: WorkItemEvent::StateChanged {
                    id: "ghost".into(),
                    state: State::Ready.as_str().into(),
                    reason: "x".into(),
                },
            },
        );
        assert!(matches!(r, PmResponse::Error(_)));
        // An unknown edge-kind code is mapped too.
        let bad = dispatch(
            &mut conn,
            PmRequest::AddEdge {
                ts: 1,
                actor_id: "h".into(),
                actor_kind: 0,
                from: "a".into(),
                to: "b".into(),
                kind: 99,
            },
        );
        assert!(matches!(bad, PmResponse::Error(_)));
        Ok(())
    }

    #[test]
    fn wire_bytes_roundtrip() -> Result<(), Box<dyn std::error::Error>> {
        let mut conn = open_in_memory()?;
        dispatch(
            &mut conn,
            PmRequest::Append {
                ts: 1,
                actor_id: "h".into(),
                actor_kind: 0,
                event: created_in("A", State::Ready),
            },
        );
        let req_bytes = rmp_serde::to_vec(&PmRequest::WorkNext)?;
        let resp_bytes = dispatch_bytes(&mut conn, &req_bytes)?;
        let resp: PmResponse = rmp_serde::from_slice(&resp_bytes)?;
        assert!(matches!(
            resp,
            PmResponse::Items(ref v) if v.len() == 1 && v.first().map(|w| w.id.as_str()) == Some("A")
        ));
        Ok(())
    }
}
