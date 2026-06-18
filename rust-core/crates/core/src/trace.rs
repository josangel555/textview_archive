//! Hand-rolled, dependency-free instrumentation facade — the `tracing` analog.
//!
//! Why hand-rolled: the PoC's approved-crate list is `serde` / `rmp-serde` /
//! `cbindgen` only. Rather than pull the real `tracing` crate (+ its
//! `tracing-core` / `pin-project-lite` transitive surface), we model the same
//! shape — **spans** (scoped, RAII-closed) and **events** (point-in-time) —
//! behind a pluggable [`Sink`]. This is deliberately the seam the main Swift
//! app would call its `ObservabilitySink`: a host installs ONE sink and every
//! core span/event is delivered to it.
//!
//! NOTE: no FFI forwarding is wired yet. `mdvcore-ffi` exposes no
//! `set_sink`/forwarding entry point, so the only sinks installed today are
//! in-process (the core's own tests). Forwarding span/event records across the
//! C ABI to a Swift closure is the intended next step, not a shipped capability
//! — until then the global sink stays `None` in production and emitting is a
//! near-free fast-path (see [`emit`]).
//!
//! Concurrency: the sink is stored behind a `RwLock<Option<...>>`, fronted by an
//! [`AtomicBool`] presence flag. Installing is rare (once at startup) and flips
//! the flag; emitting does a single relaxed atomic load and only takes the read
//! lock when a sink is actually present — so the no-sink production path pays
//! ~one atomic load, not a lock. A real host would install once at process start
//! and never swap.

use std::sync::RwLock;
use std::sync::atomic::{AtomicBool, Ordering};

/// Severity of an event. Mirrors the common `tracing` levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    /// Verbose diagnostic detail.
    Trace,
    /// Debugging detail.
    Debug,
    /// Normal operational events.
    Info,
    /// Recoverable problems.
    Warn,
    /// Errors.
    Error,
}

impl Level {
    /// Stable lowercase label (what a host would render / forward).
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Level::Trace => "trace",
            Level::Debug => "debug",
            Level::Info => "info",
            Level::Warn => "warn",
            Level::Error => "error",
        }
    }
}

/// A structured record handed to the [`Sink`]. Either a span lifecycle marker
/// or a point event. Kept `Clone` + owned so a sink can buffer/forward freely.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Record {
    /// A span was entered (e.g. `csv.parse`).
    SpanEnter {
        /// The span's static name.
        name: &'static str,
    },
    /// A span exited, with its measured duration in microseconds. The core
    /// itself does not read the clock (determinism); the duration is computed
    /// by the host-injected timer in the span guard, defaulting to `None` when
    /// no timer is installed (keeps the core replayable in tests).
    SpanExit {
        /// The span's static name (matches the corresponding `SpanEnter`).
        name: &'static str,
        /// Elapsed time in microseconds, or `None` when the core read no clock.
        elapsed_micros: Option<u64>,
    },
    /// A point-in-time event with a level, a static message, and optional
    /// structured key/value fields.
    Event {
        /// Severity.
        level: Level,
        /// Static human-readable message.
        message: &'static str,
        /// Structured key/value context fields.
        fields: Vec<(&'static str, String)>,
    },
}

/// A consumer of trace records. The host installs exactly one. `Send + Sync`
/// because the core may emit from whichever thread the FFI caller is on.
pub trait Sink: Send + Sync {
    /// Deliver one record. Must not panic (a panicking sink would surface as a
    /// caught panic at the FFI boundary, but a well-behaved host handles its
    /// own errors here).
    fn record(&self, record: &Record);
}

static SINK: RwLock<Option<Box<dyn Sink>>> = RwLock::new(None);

/// Fast-path presence flag for [`SINK`]. Read on every [`emit`] with a single
/// relaxed load so the no-sink production path never touches the `RwLock`. The
/// flag is only a hint — [`emit`] re-validates under the read lock — so relaxed
/// ordering is sound (the lock provides the real happens-before for the sink).
static SINK_PRESENT: AtomicBool = AtomicBool::new(false);

/// Install the global trace sink, replacing any previous one. Idempotent;
/// passing the same kind of sink twice simply swaps it.
/// TSK-574: a deliberate future host-seam — the host installs a `Sink` to drain
/// trace records. No in-tree consumer yet; intentionally retained, not dead.
pub fn set_sink(sink: Box<dyn Sink>) {
    if let Ok(mut guard) = SINK.write() {
        *guard = Some(sink);
        SINK_PRESENT.store(true, Ordering::Relaxed);
    }
}

/// Remove the global sink (records become no-ops). Useful for test isolation.
pub fn clear_sink() {
    if let Ok(mut guard) = SINK.write() {
        *guard = None;
        SINK_PRESENT.store(false, Ordering::Relaxed);
    }
}

/// Whether a sink is currently installed. A single relaxed atomic load — cheap
/// enough to gate hot-path call sites that would otherwise allocate their
/// `fields` vec (and the `String`s in it) only to drop them when nobody listens.
#[must_use]
pub fn sink_installed() -> bool {
    SINK_PRESENT.load(Ordering::Relaxed)
}

/// Emit a record to the installed sink, if any. Lock-poisoning is treated as
/// "no sink" rather than propagated — instrumentation must never take down the
/// core. The fast-path presence check ([`sink_installed`]) skips the read lock
/// entirely when no sink is installed (the production default).
pub fn emit(record: &Record) {
    if !sink_installed() {
        return;
    }
    if let Ok(guard) = SINK.read()
        && let Some(sink) = guard.as_ref()
    {
        sink.record(record);
    }
}

/// Emit a point event. Convenience over [`emit`].
pub fn event(level: Level, message: &'static str, fields: Vec<(&'static str, String)>) {
    emit(&Record::Event {
        level,
        message,
        fields,
    });
}

/// RAII span guard. Entering emits [`Record::SpanEnter`]; dropping emits
/// [`Record::SpanExit`]. No clock is read inside the core (determinism); the
/// elapsed duration is left `None`. A host that wants timing wraps the call
/// site with its own injected timer.
#[must_use = "a span must be held for its scope; drop it to emit the exit record"]
pub struct Span {
    name: &'static str,
}

impl Span {
    /// Enter a new span, emitting the enter record immediately.
    pub fn enter(name: &'static str) -> Self {
        emit(&Record::SpanEnter { name });
        Self { name }
    }
}

impl Drop for Span {
    fn drop(&mut self) {
        emit(&Record::SpanExit {
            name: self.name,
            elapsed_micros: None,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// The sink is a process-global; `cargo test` runs these in parallel, so
    /// tests that install/clear it must serialize or they clobber each other.
    static STATE_LOCK: Mutex<()> = Mutex::new(());

    #[derive(Default)]
    struct CollectSink(Arc<Mutex<Vec<Record>>>);

    impl Sink for CollectSink {
        fn record(&self, record: &Record) {
            self.0.lock().unwrap().push(record.clone());
        }
    }

    #[test]
    fn span_emits_enter_and_exit() {
        let _state = STATE_LOCK.lock().unwrap();
        let store = Arc::new(Mutex::new(Vec::new()));
        set_sink(Box::new(CollectSink(Arc::clone(&store))));
        {
            let _span = Span::enter("unit.span");
            event(Level::Info, "inside", vec![("k", "v".to_string())]);
        }
        clear_sink();

        let recs = store.lock().unwrap().clone();
        assert_eq!(
            recs,
            vec![
                Record::SpanEnter { name: "unit.span" },
                Record::Event {
                    level: Level::Info,
                    message: "inside",
                    fields: vec![("k", "v".to_string())],
                },
                Record::SpanExit {
                    name: "unit.span",
                    elapsed_micros: None,
                },
            ]
        );
    }

    #[test]
    fn no_sink_is_a_noop() {
        let _state = STATE_LOCK.lock().unwrap();
        clear_sink();
        // Must not panic with no sink installed.
        event(Level::Warn, "no sink", vec![]);
        let _span = Span::enter("orphan");
    }

    #[test]
    fn presence_flag_gates_delivery() {
        let _state = STATE_LOCK.lock().unwrap();

        clear_sink();
        assert!(!sink_installed(), "flag must be false after clear");

        let store = Arc::new(Mutex::new(Vec::new()));
        set_sink(Box::new(CollectSink(Arc::clone(&store))));
        assert!(sink_installed(), "flag must be true after set");
        event(Level::Info, "after-install", vec![]);

        clear_sink();
        assert!(!sink_installed(), "flag must be false after clear");
        event(Level::Info, "after-clear", vec![]);

        // Only the event emitted while a sink was installed reached it. This
        // also pins set_sink's flag-flip: drop the `store(true)` and emit's
        // fast-path early-returns even with a sink installed → zero records.
        let recs = store.lock().unwrap().clone();
        assert_eq!(
            recs,
            vec![Record::Event {
                level: Level::Info,
                message: "after-install",
                fields: vec![],
            }]
        );
    }
}
