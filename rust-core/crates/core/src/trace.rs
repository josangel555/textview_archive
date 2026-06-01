//! Hand-rolled, dependency-free instrumentation facade — the `tracing` analog.
//!
//! Why hand-rolled: the PoC's approved-crate list is `serde` / `rmp-serde` /
//! `cbindgen` only. Rather than pull the real `tracing` crate (+ its
//! `tracing-core` / `pin-project-lite` transitive surface), we model the same
//! shape — **spans** (scoped, RAII-closed) and **events** (point-in-time) —
//! behind a pluggable [`Sink`]. This is deliberately the seam the main Swift
//! app calls its `ObservabilitySink`: a host installs ONE sink and every core
//! span/event is delivered to it. The FFI layer can forward these across the
//! C ABI to a Swift closure (see `mdvcore-ffi`), exactly how the production app
//! would wire core observability into its existing sink.
//!
//! Concurrency: the sink is stored behind a `RwLock<Option<...>>`. Installing
//! is rare (once at startup); emitting takes a read lock. A real host would
//! likely install at process start and never swap.

use std::sync::RwLock;

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

/// Install the global trace sink, replacing any previous one. Idempotent;
/// passing the same kind of sink twice simply swaps it.
pub fn set_sink(sink: Box<dyn Sink>) {
    if let Ok(mut guard) = SINK.write() {
        *guard = Some(sink);
    }
}

/// Remove the global sink (records become no-ops). Useful for test isolation.
pub fn clear_sink() {
    if let Ok(mut guard) = SINK.write() {
        *guard = None;
    }
}

/// Emit a record to the installed sink, if any. Lock-poisoning is treated as
/// "no sink" rather than propagated — instrumentation must never take down the
/// core.
pub fn emit(record: &Record) {
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

    #[derive(Default)]
    struct CollectSink(Arc<Mutex<Vec<Record>>>);

    impl Sink for CollectSink {
        fn record(&self, record: &Record) {
            self.0.lock().unwrap().push(record.clone());
        }
    }

    #[test]
    fn span_emits_enter_and_exit() {
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
        clear_sink();
        // Must not panic with no sink installed.
        event(Level::Warn, "no sink", vec![]);
        let _span = Span::enter("orphan");
    }
}
