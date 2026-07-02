//! FFI-boundary tests: exercise the ACTUAL `extern "C"` symbols (error codes,
//! panic→error, handle lifecycle, single-writer concurrency, wire round-trip).
//! These run under the default `test` profile (`panic = "unwind"`), so the
//! catch_unwind path is genuinely exercised.

// The unsafe-block doc lints are valuable on the LIBRARY surface but pure
// noise inside the test harness, where every `unsafe` is a call to one of our
// own already-contract-documented extern fns with locally-obvious arguments.
#![allow(
    clippy::undocumented_unsafe_blocks,
    reason = "test calls into our own documented extern fns; per-call SAFETY comments add no signal"
)]
#![allow(
    clippy::multiple_unsafe_ops_per_block,
    reason = "test convenience; library surface still enforces one-op-per-block"
)]
#![allow(
    clippy::panic,
    reason = "test assertions: a contention status outside {Ok,Busy} is a genuine test failure"
)]

use super::*;
use mdvcore_core::wire::{Snapshot, Table};

const CSV: &[u8] = b"name,city\nAlice,Paris\nBob,Parma\nCarol,Berlin\n";

/// Open a session for a test, returning the raw handle (caller frees).
fn open(bytes: &[u8]) -> *mut SessionHandle {
    let mut h: *mut SessionHandle = core::ptr::null_mut();
    let st = unsafe { mdvcore_session_open(bytes.as_ptr(), bytes.len(), &mut h) };
    assert_eq!(st, MdvStatus::Ok);
    assert!(!h.is_null());
    h
}

/// Decode the framed table out of an out-buf call.
fn table_of(h: *mut SessionHandle) -> Table {
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_session_table(h, &mut buf) };
    assert_eq!(st, MdvStatus::Ok);
    let frame = unsafe { buf.as_slice() }.to_vec();
    let table: Table = mdvcore_core::wire::decode_frame(&frame).unwrap();
    unsafe { mdvcore_buf_free(&mut buf) };
    table
}

fn snapshot_of(h: *mut SessionHandle) -> Snapshot {
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_session_snapshot(h, &mut buf) };
    assert_eq!(st, MdvStatus::Ok);
    let frame = unsafe { buf.as_slice() }.to_vec();
    let snap: Snapshot = mdvcore_core::wire::decode_frame(&frame).unwrap();
    unsafe { mdvcore_buf_free(&mut buf) };
    snap
}

/// TSK-559 — decode a windowed snapshot (length of the returned frame too, so
/// tests can assert O(window) sizing).
fn snapshot_window_of(h: *mut SessionHandle, offset: u64, limit: u64) -> (Snapshot, usize) {
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_session_snapshot_window(h, offset, limit, &mut buf) };
    assert_eq!(st, MdvStatus::Ok);
    let frame = unsafe { buf.as_slice() }.to_vec();
    let snap: Snapshot = mdvcore_core::wire::decode_frame(&frame).unwrap();
    unsafe { mdvcore_buf_free(&mut buf) };
    (snap, frame.len())
}

fn filtered_count_of(h: *mut SessionHandle) -> u64 {
    let mut n: u64 = u64::MAX; // poison so a no-write export is caught
    let st = unsafe { mdvcore_session_filtered_count(h, &mut n) };
    assert_eq!(st, MdvStatus::Ok);
    n
}

/// Build an `id,name` CSV with `n` data rows: row i = `i,rowI`.
fn big_csv(n: usize) -> String {
    let mut s = String::from("id,name\n");
    for i in 0..n {
        s.push_str(&i.to_string());
        s.push_str(",row");
        s.push_str(&i.to_string());
        s.push('\n');
    }
    s
}

#[test]
fn stage0_add_smoke() {
    assert_eq!(mdvcore_add(2, 3), 5);
    // wrapping add doesn't panic on overflow.
    assert_eq!(mdvcore_add(i32::MAX, 1), i32::MIN);
}

#[test]
fn abi_version_reports_the_wire_const() {
    // The runtime fn and the cbindgen-emitted const MUST agree — Swift compiles
    // against the header const and compares it to this fn's return at startup;
    // the pair is the skew detector (TSK-579). 0 is reserved for "guard
    // tripped", so the const itself must never be 0.
    assert_eq!(mdvcore_abi_version(), MDV_WIRE_VERSION);
    assert_ne!(MDV_WIRE_VERSION, 0);
}

#[test]
fn capabilities_reports_the_compiled_mask() {
    // Same skew-detector pairing as the ABI version: the runtime fn and the
    // cbindgen-emitted const must agree (TSK-634). 0 means "guard tripped /
    // nothing available", so the compiled mask must never be 0.
    assert_eq!(mdvcore_capabilities(), MDV_CAPABILITIES);
    assert_ne!(MDV_CAPABILITIES, 0);
}

#[test]
fn capability_bits_are_abi_and_never_renumber() {
    // Bits are ABI: assigned once, never renumbered, never reused. A failure
    // here means someone reshuffled the bit table — that silently flips
    // remote/skewed clients' feature gates. Add NEW bits; never edit these.
    assert_eq!(MDV_CAP_CSV_SESSION, 1 << 0);
    assert_eq!(MDV_CAP_DIFF, 1 << 1);
    assert_eq!(MDV_CAP_HEX, 1 << 2);
    assert_eq!(MDV_CAP_INDENT, 1 << 3);
    assert_eq!(MDV_CAP_CM_APPLY, 1 << 4);
    assert_eq!(MDV_CAP_FIND, 1 << 5);
    assert_eq!(MDV_CAP_MARKDOWN, 1 << 6);
    assert_eq!(MDV_CAP_TRANSCRIPT, 1 << 7);
    assert_eq!(MDV_CAP_FUZZY, 1 << 8);
    assert_eq!(MDV_CAP_FS, 1 << 9);
    assert_eq!(MDV_CAP_GIT, 1 << 10);
    assert_eq!(MDV_CAP_TRANSCRIPT_LIST, 1 << 11);
    assert_eq!(MDV_CAP_LSP_PIPE, 1 << 12);
    assert_eq!(MDV_CAP_SEARCH, 1 << 13);
    assert_eq!(MDV_CAP_HIGHLIGHT, 1 << 14);
    assert_eq!(MDV_CAP_CM_APPLY_DELTA, 1 << 15);
}

#[test]
fn reserved_capability_bits_stay_off_until_their_exports_land() {
    // Turning a reserved bit ON is part of LANDING the engine's exports —
    // flipping it early advertises a capability that calls into nothing.
    // This test is edited in the SAME commit as each port. With the
    // TSK-631 markdown port landed, NO reserved bits remain (the TSK-630..633
    // engine-port wave is complete); the next reserved bit gets pre-assigned
    // here when its port is approved. Every shipped family must be ON:
    let mask = mdvcore_capabilities();
    // SERVER-ONLY bits never appear in the in-process mask: there is no fs
    // FFI export (mdv-serve adds the bit itself when a root is served).
    assert_eq!(
        mask & MDV_CAP_FS,
        0,
        "fs is a server-only capability (TSK-654)"
    );
    assert_eq!(
        mask & MDV_CAP_GIT,
        0,
        "git is a server-only capability (TSK-657)"
    );
    assert_eq!(
        mask & MDV_CAP_TRANSCRIPT_LIST,
        0,
        "transcript.list is a server-only capability (TSK-658)"
    );
    assert_eq!(mask & MDV_CAP_LSP_PIPE, 0, "lsp pipe is reserved (TSK-659)");
    assert_eq!(
        mask & MDV_CAP_SEARCH,
        0,
        "search is a server-only capability (TSK-656)"
    );
    for (bit, name) in [
        (MDV_CAP_CSV_SESSION, "csv"),
        (MDV_CAP_DIFF, "diff"),
        (MDV_CAP_HEX, "hex"),
        (MDV_CAP_INDENT, "indent"),
        (MDV_CAP_CM_APPLY, "cm_apply"),
        (MDV_CAP_FUZZY, "fuzzy"),
        (MDV_CAP_FIND, "find"),
        (MDV_CAP_TRANSCRIPT, "transcript"),
        (MDV_CAP_MARKDOWN, "markdown"),
        (MDV_CAP_HIGHLIGHT, "highlight"),
        (MDV_CAP_CM_APPLY_DELTA, "cm_apply_delta"),
    ] {
        assert_ne!(
            mask & bit,
            0,
            "shipped family '{name}' must advertise its bit"
        );
    }
}

#[test]
fn force_panic_returns_error_not_crash() {
    // The whole point: a panicking core path returns MdvStatus::Panic and the
    // test process keeps running (proves catch_unwind under panic=unwind).
    assert_eq!(mdvcore_force_panic(), MdvStatus::Panic);
    // Still alive afterwards:
    assert_eq!(mdvcore_add(1, 1), 2);
}

#[test]
fn open_and_table_round_trip() {
    let h = open(CSV);
    let table = table_of(h);
    assert_eq!(table.delimiter, ",");
    assert_eq!(table.header, vec!["name", "city"]);
    assert_eq!(table.rows.len(), 3);
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn open_null_out_handle_is_nullarg() {
    let st = unsafe { mdvcore_session_open(CSV.as_ptr(), CSV.len(), core::ptr::null_mut()) };
    assert_eq!(st, MdvStatus::NullArg);
}

#[test]
fn open_null_bytes_with_nonzero_len_is_nullarg() {
    let mut h: *mut SessionHandle = core::ptr::null_mut();
    let st = unsafe { mdvcore_session_open(core::ptr::null(), 5, &mut h) };
    assert_eq!(st, MdvStatus::NullArg);
    assert!(h.is_null());
}

#[test]
fn open_empty_input_succeeds() {
    let mut h: *mut SessionHandle = core::ptr::null_mut();
    let st = unsafe { mdvcore_session_open(core::ptr::null(), 0, &mut h) };
    assert_eq!(st, MdvStatus::Ok);
    assert!(!h.is_null());
    let table = table_of(h);
    assert!(table.header.is_empty());
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn open_bad_utf8_is_baddutf8() {
    let bad = [0x61u8, 0xFF, 0x62];
    let mut h: *mut SessionHandle = core::ptr::null_mut();
    let st = unsafe { mdvcore_session_open(bad.as_ptr(), bad.len(), &mut h) };
    assert_eq!(st, MdvStatus::BadUtf8);
    assert!(h.is_null());
}

#[test]
fn set_filter_and_snapshot() {
    let h = open(CSV);
    // Unfiltered snapshot: all 3 rows.
    let snap0 = snapshot_of(h);
    assert_eq!(snap0.total_rows, 3);
    assert_eq!(snap0.rows.len(), 3);
    assert_eq!(snap0.version, 1);

    // Filter to "par" (Paris, Parma).
    let q = b"par";
    let st = unsafe { mdvcore_session_set_filter(h, q.as_ptr(), q.len(), -1) };
    assert_eq!(st, MdvStatus::Ok);

    let snap1 = snapshot_of(h);
    assert_eq!(snap1.rows.len(), 2);
    assert_eq!(snap1.indices, vec![0, 1]);
    assert_eq!(snap1.total_rows, 3);
    assert_eq!(snap1.version, 2);
    assert_eq!(snap1.query, "par");

    unsafe { mdvcore_session_free(h) };
}

#[test]
fn set_filter_column_scope() {
    let h = open(CSV);
    // Column 0 (name) contains 'a': Alice, Carol → 2 rows.
    let q = b"a";
    let st = unsafe { mdvcore_session_set_filter(h, q.as_ptr(), q.len(), 0) };
    assert_eq!(st, MdvStatus::Ok);
    let snap = snapshot_of(h);
    assert_eq!(snap.indices, vec![0, 2]);
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn set_filter_bad_utf8_query() {
    let h = open(CSV);
    let bad = [0xFFu8, 0xFE];
    let st = unsafe { mdvcore_session_set_filter(h, bad.as_ptr(), bad.len(), -1) };
    assert_eq!(st, MdvStatus::BadUtf8);
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn null_handle_calls_are_nullarg_not_crash() {
    let mut buf = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_session_table(core::ptr::null_mut(), &mut buf) },
        MdvStatus::NullArg
    );
    assert_eq!(
        unsafe { mdvcore_session_snapshot(core::ptr::null_mut(), &mut buf) },
        MdvStatus::NullArg
    );
    let q = b"x";
    assert_eq!(
        unsafe { mdvcore_session_set_filter(core::ptr::null_mut(), q.as_ptr(), q.len(), -1) },
        MdvStatus::NullArg
    );
}

#[test]
fn free_is_null_tolerant_and_idempotent_on_null() {
    // Freeing null is a no-op (matches C free()).
    unsafe { mdvcore_session_free(core::ptr::null_mut()) };
    // Freeing an empty buf and a null buf pointer are both safe.
    let mut buf = MdvBuf::empty();
    unsafe { mdvcore_buf_free(&mut buf) };
    unsafe { mdvcore_buf_free(core::ptr::null_mut()) };
}

#[test]
fn buf_double_free_in_place_is_safe() {
    // Producing a real buffer then freeing twice must not double-free: the
    // first free nulls the fields, the second is a no-op.
    let h = open(CSV);
    let mut buf = MdvBuf::empty();
    assert_eq!(unsafe { mdvcore_session_table(h, &mut buf) }, MdvStatus::Ok);
    assert!(!buf.data.is_null());
    unsafe { mdvcore_buf_free(&mut buf) };
    assert!(buf.data.is_null());
    assert_eq!(buf.cap, 0);
    // Second free: harmless.
    unsafe { mdvcore_buf_free(&mut buf) };
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn wire_status_maps_too_large_distinctly() {
    // TSK-548 stopgap: the encode-side overflow keeps its identity across the
    // boundary; every other wire fault stays the generic WireError.
    use mdvcore_core::wire::WireFault;
    assert_eq!(
        wire_status(&WireFault::TooLarge("x".into())),
        MdvStatus::TooLarge
    );
    assert_eq!(
        wire_status(&WireFault::Framing("x".into())),
        MdvStatus::WireError
    );
    assert_eq!(
        wire_status(&WireFault::Encode("x".into())),
        MdvStatus::WireError
    );
    assert_eq!(
        wire_status(&WireFault::Decode("x".into())),
        MdvStatus::WireError
    );
}

#[test]
fn hex_render_clamps_hostile_width_to_max() {
    // TSK-540: an unclamped width drives a width-proportional row allocation
    // (u32::MAX → ~17 GiB) whose failure ABORTS past the panic guard. The edge
    // clamps to MAX_HEX_WIDTH, so MAX+1 must render exactly like MAX. Uses
    // MAX+1 (not u32::MAX) so the PRE-fix failure mode is a fast wrong-output
    // assert, not an OOM.
    let data = b"hello hex";
    let mut clamped = MdvBuf::empty();
    let st = unsafe {
        mdvcore_hex_render(
            data.as_ptr(),
            data.len(),
            MAX_HEX_WIDTH + 1,
            data.len() as u64,
            false,
            &mut clamped,
        )
    };
    assert_eq!(st, MdvStatus::Ok);
    let expected = mdvcore_core::hex::render_all(data, MAX_HEX_WIDTH as usize, data.len(), false);
    let got = unsafe { core::slice::from_raw_parts(clamped.data, clamped.len) };
    assert_eq!(got, expected.as_bytes());
    unsafe { mdvcore_buf_free(&mut clamped) };
}

#[test]
fn hex_render_width_zero_is_empty_not_underflow() {
    // Companion to the clamp: width 0 keeps the documented empty-dump
    // contract (and rendered_row_length(0) is total, not an underflow panic).
    let data = b"abc";
    let mut buf = MdvBuf::empty();
    let st = unsafe {
        mdvcore_hex_render(
            data.as_ptr(),
            data.len(),
            0,
            data.len() as u64,
            false,
            &mut buf,
        )
    };
    assert_eq!(st, MdvStatus::Ok);
    assert_eq!(buf.len, 0);
    unsafe { mdvcore_buf_free(&mut buf) };
}

#[test]
fn handle_lifecycle_many_open_free_no_leak_smoke() {
    // Open/free many handles; a leak/double-free would surface under Miri /
    // ASan. Here we just prove the loop is stable.
    for _ in 0..1000 {
        let h = open(CSV);
        let _ = snapshot_of(h);
        unsafe { mdvcore_session_free(h) };
    }
}

#[test]
fn single_writer_busy_is_deterministic_under_held_lock() {
    // TSK-582: the old version of this test was a confirmed test-lie — it only
    // sanity-checked the happy path and could never fail on a Busy regression.
    // This one is DETERMINISTIC: a holder thread takes the lock and parks
    // inside `with()` (rendezvous via channels), so the main thread's FFI call
    // is GUARANTEED to hit a held lock → must be Busy, not block, not Ok.
    use std::sync::mpsc;
    use std::thread;

    let h = open(CSV);
    let ptr = h as usize; // move a usize across the boundary (Send-safe)
    let (locked_tx, locked_rx) = mpsc::channel::<()>();
    let (release_tx, release_rx) = mpsc::channel::<()>();

    let holder = thread::spawn(move || {
        let h = ptr as *mut SessionHandle;
        let handle = SessionHandle::lookup(h).unwrap();
        let held = handle.with(|_session| {
            locked_tx.send(()).unwrap(); // signal: lock is held
            release_rx.recv().unwrap(); // park until the Busy assert ran
            MdvStatus::Ok
        });
        assert_eq!(held, Ok(MdvStatus::Ok));
    });

    locked_rx.recv().unwrap(); // the holder definitely owns the lock now
    let needle = b"par";
    assert_eq!(
        unsafe { mdvcore_session_set_filter(h, needle.as_ptr(), needle.len(), -1) },
        MdvStatus::Busy,
        "a concurrently-held single-writer lock must report Busy deterministically"
    );

    release_tx.send(()).unwrap();
    holder.join().unwrap();

    // Lock released: the identical call now succeeds (Busy was transient).
    assert_eq!(
        unsafe { mdvcore_session_set_filter(h, needle.as_ptr(), needle.len(), -1) },
        MdvStatus::Ok
    );
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn poisoned_handle_returns_handle_dead_not_recovered_state() {
    // TSK-581: a panic while holding the session lock poisons it. The old
    // behavior recovered the guard with `into_inner()` and SERVED the possibly
    // half-mutated state; the contract says drop-&-recreate. Pin the tri-state:
    // every subsequent call on the poisoned handle is HandleDead — not Ok with
    // suspect data, not Busy.
    let h = open(CSV);
    let handle = SessionHandle::lookup(h).unwrap();
    let unwound = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = handle.with(|_session| -> MdvStatus { panic!("poison the lock") });
    }));
    assert!(unwound.is_err(), "the panic must unwind out of with()");

    let mut buf = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_session_table(h, &mut buf) },
        MdvStatus::HandleDead
    );
    unsafe { mdvcore_buf_free(&mut buf) };

    let needle = b"par";
    assert_eq!(
        unsafe { mdvcore_session_set_filter(h, needle.as_ptr(), needle.len(), -1) },
        MdvStatus::HandleDead
    );

    let mut snap = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_session_snapshot(h, &mut snap) },
        MdvStatus::HandleDead
    );
    unsafe { mdvcore_buf_free(&mut snap) };

    // Free still works on a poisoned handle — the drop path must not require
    // the lock to be healthy.
    unsafe { mdvcore_session_free(h) };
}

// ===== TSK-559: windowed snapshot (O(window) per pull) =====

#[test]
fn snapshot_window_returns_only_the_requested_window() {
    let csv = big_csv(100);
    let h = open(csv.as_bytes());
    assert_eq!(filtered_count_of(h), 100, "unfiltered → all rows survive");
    // A 10-row window at the top.
    let (w0, _) = snapshot_window_of(h, 0, 10);
    assert_eq!(w0.rows.len(), 10);
    assert_eq!(w0.indices, (0u32..10).collect::<Vec<u32>>());
    assert_eq!(w0.total_rows, 100, "table total is unchanged by windowing");
    assert_eq!(w0.rows[0], vec!["0".to_string(), "row0".to_string()]);
    // A window in the middle carries the ABSOLUTE row ids.
    let (w50, _) = snapshot_window_of(h, 50, 10);
    assert_eq!(w50.rows.len(), 10);
    assert_eq!(w50.indices, (50u32..60).collect::<Vec<u32>>());
    assert_eq!(w50.rows[0], vec!["50".to_string(), "row50".to_string()]);
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn snapshot_window_clamps_offset_and_limit() {
    let csv = big_csv(100);
    let h = open(csv.as_bytes());
    // Limit overruns the end → only the remaining 5 rows.
    let (tail, _) = snapshot_window_of(h, 95, 10);
    assert_eq!(tail.rows.len(), 5);
    assert_eq!(tail.indices, (95u32..100).collect::<Vec<u32>>());
    // Offset past the end → empty window, still Ok (scrolled past the last row).
    let (past, _) = snapshot_window_of(h, 200, 10);
    assert!(past.rows.is_empty());
    assert!(past.indices.is_empty());
    assert_eq!(
        past.total_rows, 100,
        "metadata is still correct on an empty window"
    );
    // A huge limit saturates to the full surviving set.
    let (all, _) = snapshot_window_of(h, 0, 100_000);
    assert_eq!(all.rows.len(), 100);
    // TSK-1012: offset past end + a near-MAX limit must not overflow the
    // `start.saturating_add(limit)` — it saturates and clamps to an empty window.
    let (sat, _) = snapshot_window_of(h, 200, u64::MAX);
    assert!(sat.rows.is_empty(), "offset-past-end + MAX limit stays empty (no overflow)");
    // MAX limit from the top saturates to the full surviving set.
    let (sat_top, _) = snapshot_window_of(h, 0, u64::MAX);
    assert_eq!(sat_top.rows.len(), 100);
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn windowed_snapshot_respects_the_active_filter() {
    let csv = big_csv(100);
    let h = open(csv.as_bytes());
    // Filter the NAME column (scope 1) to "row1" → row1 + row10..row19 = 11.
    let q = b"row1";
    assert_eq!(
        unsafe { mdvcore_session_set_filter(h, q.as_ptr(), q.len(), 1) },
        MdvStatus::Ok
    );
    assert_eq!(filtered_count_of(h), 11, "‘row1’ matches row1 + row10..19");
    let (win, _) = snapshot_window_of(h, 0, 3);
    assert_eq!(win.rows.len(), 3);
    // The window pages the FILTERED set, carrying absolute data-row ids in order.
    assert_eq!(win.indices, vec![1u32, 10, 11]);
    assert_eq!(
        win.total_rows, 100,
        "total is the table size, not the filtered size"
    );
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn windowed_snapshot_is_far_smaller_than_the_full_snapshot() {
    // TEETH for O(window): if the window projected ALL surviving rows instead
    // of the slice, its frame would equal the full snapshot's. A 5-row window
    // over 1000 rows must be dramatically smaller.
    let csv = big_csv(1000);
    let h = open(csv.as_bytes());
    let (_, win_len) = snapshot_window_of(h, 0, 5);
    let full_len = {
        let mut buf = MdvBuf::empty();
        assert_eq!(
            unsafe { mdvcore_session_snapshot(h, &mut buf) },
            MdvStatus::Ok
        );
        let len = unsafe { buf.as_slice() }.len();
        unsafe { mdvcore_buf_free(&mut buf) };
        len
    };
    assert!(
        win_len.saturating_mul(10) < full_len,
        "5-row window ({win_len} B) must be <<< the 1000-row full snapshot ({full_len} B)"
    );
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn windowed_exports_reject_null_handle() {
    let mut buf = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_session_snapshot_window(core::ptr::null_mut(), 0, 10, &mut buf) },
        MdvStatus::NullArg
    );
    let mut n: u64 = 7;
    assert_eq!(
        unsafe { mdvcore_session_filtered_count(core::ptr::null_mut(), &mut n) },
        MdvStatus::NullArg
    );
}

// ===== TSK-580: thin-waist envelope (mdvcore_call dispatch) =====

#[test]
fn envelope_agrees_with_the_direct_export_byte_for_byte() {
    // A hand-built `{text: ""}` request frame (the ffi crate has no serde; the
    // core dispatch test covers rich-frame parity). TEETH: if mdvcore_call
    // routed method 2 to the wrong core fn, these bytes would diverge from the
    // old mdvcore_diff_parse symbol.
    let frame: [u8; 11] = [7, 0, 0, 0, 0x81, 0xa4, b't', b'e', b'x', b't', 0xa0];
    let mut via = MdvBuf::empty();
    let s1 = unsafe { mdvcore_call(2, frame.as_ptr(), frame.len(), core::ptr::null(), 0, &mut via) };
    let via_bytes = unsafe { via.as_slice() }.to_vec();
    let mut direct = MdvBuf::empty();
    let s2 = unsafe { mdvcore_diff_parse(frame.as_ptr(), frame.len(), &mut direct) };
    let direct_bytes = unsafe { direct.as_slice() }.to_vec();
    assert_eq!(s1, MdvStatus::Ok, "an empty diff parses cleanly");
    assert_eq!(s1, s2, "envelope and old symbol return the same status");
    assert_eq!(via_bytes, direct_bytes, "byte-identical result frame");
    unsafe { mdvcore_buf_free(&mut via) };
    unsafe { mdvcore_buf_free(&mut direct) };
}

#[test]
fn method_id_consts_match_the_dispatch_enum() {
    // The C/Swift-visible #defines MUST equal the safe-Rust dispatch enum, or a
    // Swift caller routes to the wrong method. Pins every id + the count.
    use mdvcore_core::dispatch::Method;
    assert_eq!(MDV_METHOD_CM_APPLY, Method::CmApply as u16);
    assert_eq!(MDV_METHOD_DIFF_PARSE, Method::DiffParse as u16);
    assert_eq!(MDV_METHOD_DIFF_HUNK_MARKS, Method::DiffHunkMarks as u16);
    assert_eq!(MDV_METHOD_FUZZY_RANK, Method::FuzzyRank as u16);
    assert_eq!(MDV_METHOD_FIND_SEARCH, Method::FindSearch as u16);
    assert_eq!(MDV_METHOD_MARKDOWN_RENDER, Method::MarkdownRender as u16);
    assert_eq!(MDV_METHOD_TRANSCRIPT_PARSE, Method::TranscriptParse as u16);
    assert_eq!(
        MDV_METHOD_TRANSCRIPT_PARSE_FORCED_REDACTION,
        Method::TranscriptParseForcedRedaction as u16
    );
    assert_eq!(MDV_METHOD_HIGHLIGHT_RUNS, Method::HighlightRuns as u16);
    assert_eq!(MDV_METHOD_HEX_SEARCH, Method::HexSearch as u16);
    assert_eq!(MDV_METHOD_INDENT_DETECT, Method::IndentDetect as u16);
    assert_eq!(MDV_METHOD_HEX_RENDER, Method::HexRender as u16);
    assert_eq!(MDV_METHOD_FORMULA_EVALUATE, Method::FormulaEvaluate as u16);
    assert_eq!(MDV_METHOD_FORMULA_RECALC, Method::FormulaRecalc as u16);
    assert_eq!(MDV_METHOD_FOLD_REGIONS, Method::FoldRegions as u16);
    assert_eq!(MDV_METHOD_CM_APPLY_DELTA, Method::CmApplyDelta as u16);
    assert_eq!(MDV_METHOD_HTML_BLOCK_PATCH, Method::HtmlBlockPatch as u16);
    // Every const is a live method, and there are exactly (NEXT_FREE_ID - 1).
    for id in [
        MDV_METHOD_CM_APPLY, MDV_METHOD_DIFF_PARSE, MDV_METHOD_DIFF_HUNK_MARKS,
        MDV_METHOD_FUZZY_RANK, MDV_METHOD_FIND_SEARCH, MDV_METHOD_MARKDOWN_RENDER,
        MDV_METHOD_TRANSCRIPT_PARSE, MDV_METHOD_TRANSCRIPT_PARSE_FORCED_REDACTION,
        MDV_METHOD_HIGHLIGHT_RUNS, MDV_METHOD_HEX_SEARCH,
        MDV_METHOD_INDENT_DETECT, MDV_METHOD_HEX_RENDER,
        MDV_METHOD_FORMULA_EVALUATE, MDV_METHOD_FORMULA_RECALC,
        MDV_METHOD_FOLD_REGIONS, MDV_METHOD_CM_APPLY_DELTA,
        MDV_METHOD_HTML_BLOCK_PATCH,
    ] {
        assert!(Method::from_u16(id).is_some(), "const {id} must be a live method");
    }
    assert_eq!(Method::NEXT_FREE_ID, 18, "17 methods defined; next free id is 18");
}

#[test]
fn envelope_routes_highlight_to_the_same_result_as_its_symbol() {
    // Highlight is the one method whose impl lives in a separate crate
    // (mdvcore-highlight); the FFI envelope must route id 9 to it, byte-
    // identically to the old mdvcore_highlight_runs symbol. TEETH: a mis-route
    // to dispatch::call hits the defensive Err → status diverges from Ok.
    let frame = mdvcore_core::wire::encode_frame(&highlight_runs::RunsRequest {
        text: "fn main() { let x = 7; }".into(),
        lang: "rust".into(),
    })
    .unwrap();
    let mut via = MdvBuf::empty();
    let s1 = unsafe {
        mdvcore_call(9, frame.as_ptr(), frame.len(), core::ptr::null(), 0, &mut via)
    };
    let via_bytes = unsafe { via.as_slice() }.to_vec();
    let mut direct = MdvBuf::empty();
    let s2 = unsafe { mdvcore_highlight_runs(frame.as_ptr(), frame.len(), &mut direct) };
    let direct_bytes = unsafe { direct.as_slice() }.to_vec();
    assert_eq!(s1, MdvStatus::Ok, "a real highlight request succeeds via the envelope");
    assert_eq!(s1, s2, "envelope and the highlight symbol return the same status");
    assert_eq!(via_bytes, direct_bytes, "byte-identical highlight result");
    unsafe { mdvcore_buf_free(&mut via) };
    unsafe { mdvcore_buf_free(&mut direct) };
}

#[test]
fn envelope_routes_fold_regions() {
    // Folds, like highlight, live in mdvcore-highlight — the envelope must route
    // id 15 to fold_regions_wire. TEETH: a mis-route to dispatch::call hits the
    // defensive Err → status would diverge from Ok.
    let frame = mdvcore_core::wire::encode_frame(&folds::FoldsRequest {
        text: "{\n  \"a\": 1,\n  \"b\": 2\n}".into(),
        lang: "json".into(),
    })
    .unwrap();
    let mut buf = MdvBuf::empty();
    let st = unsafe {
        mdvcore_call(
            MDV_METHOD_FOLD_REGIONS,
            frame.as_ptr(),
            frame.len(),
            core::ptr::null(),
            0,
            &mut buf,
        )
    };
    assert_eq!(st, MdvStatus::Ok, "a real fold request succeeds via the envelope");
    let out = unsafe { buf.as_slice() }.to_vec();
    unsafe { mdvcore_buf_free(&mut buf) };
    let resp: folds::FoldsResponse = mdvcore_core::wire::decode_frame(&out).unwrap();
    assert!(resp.supported);
    assert!(
        resp.regions.iter().any(|r| r.kind == folds::FoldKind::Object),
        "round-tripped object fold, got {:?}",
        resp.regions
    );
}

#[test]
fn envelope_routes_hex_search_over_the_aux_channel() {
    // Hex search is the FIRST method to use the `aux` bulk side-channel: the
    // buffer to search rides `aux` (frame-cap-exempt — a multi-MiB file would
    // overflow a `req` frame), `req` carries only {query, mode}. The envelope
    // result must match the dedicated mdvcore_hex_search symbol byte-for-byte.
    // TEETH: if the envelope dropped aux (passed empty), there would be no
    // matches and the offsets frame would diverge from the symbol's.
    let data: [u8; 5] = [0xDE, 0xAD, 0x00, 0xDE, 0xAD]; // 0xDEAD at offsets 0 and 3
    let req = mdvcore_core::wire::encode_frame(&mdvcore_core::hex::SearchAuxRequest {
        query: "dead",
        mode: 0,
    })
    .unwrap();
    let mut via = MdvBuf::empty();
    let s1 = unsafe {
        mdvcore_call(
            MDV_METHOD_HEX_SEARCH,
            req.as_ptr(),
            req.len(),
            data.as_ptr(),
            data.len(),
            &mut via,
        )
    };
    let via_bytes = unsafe { via.as_slice() }.to_vec();
    let mut direct = MdvBuf::empty();
    let s2 = unsafe {
        mdvcore_hex_search(data.as_ptr(), data.len(), "dead".as_ptr(), 4, 0, &mut direct)
    };
    let direct_bytes = unsafe { direct.as_slice() }.to_vec();
    assert_eq!(s1, MdvStatus::Ok, "hex search via the envelope succeeds");
    assert_eq!(s1, s2, "envelope and the hex_search symbol return the same status");
    assert_eq!(via_bytes, direct_bytes, "byte-identical offsets frame — aux carried the data");
    assert!(!via_bytes.is_empty(), "two matches were found, not zero");
    unsafe { mdvcore_buf_free(&mut via) };
    unsafe { mdvcore_buf_free(&mut direct) };
}

#[test]
fn envelope_routes_indent_detect_raw_output() {
    // RAW-OUTPUT method (TSK-580 slice 3): the source text rides `aux`,
    // {sample_lines} rides `req`, and the result is the raw string bytes — NOT
    // a frame. The envelope result must match the dedicated mdvcore_indent_detect
    // symbol byte-for-byte. TEETH: if the envelope dropped aux, detect would see
    // empty text → "—", diverging from the symbol's "Spaces (4)".
    let text = "    a\n    b\n";
    let req = mdvcore_core::wire::encode_frame(&mdvcore_core::indent::DetectAuxRequest {
        sample_lines: 50,
    })
    .unwrap();
    let mut via = MdvBuf::empty();
    let s1 = unsafe {
        mdvcore_call(
            MDV_METHOD_INDENT_DETECT,
            req.as_ptr(),
            req.len(),
            text.as_ptr(),
            text.len(),
            &mut via,
        )
    };
    let via_bytes = unsafe { via.as_slice() }.to_vec();
    let mut direct = MdvBuf::empty();
    let s2 = unsafe { mdvcore_indent_detect(text.as_ptr(), text.len(), 50, &mut direct) };
    let direct_bytes = unsafe { direct.as_slice() }.to_vec();
    assert_eq!(s1, MdvStatus::Ok, "indent detect via the envelope succeeds");
    assert_eq!(s1, s2, "envelope and the indent_detect symbol return the same status");
    assert_eq!(via_bytes, direct_bytes, "byte-identical raw result — aux carried the text");
    assert_eq!(via_bytes, b"Spaces (4)", "raw bytes, not a MessagePack frame");
    unsafe { mdvcore_buf_free(&mut via) };
    unsafe { mdvcore_buf_free(&mut direct) };
}

#[test]
fn envelope_routes_hex_render_raw_bulk_output() {
    // RAW-OUTPUT method (TSK-580 slice 3, the bulk case): the bytes to dump ride
    // `aux` (a real file → ~18 MB dump, far past the 16 MiB frame cap), the
    // {width, total_byte_count, is_truncated} scalars ride `req`, and the dump
    // returns as raw bytes. Byte-identical to the dedicated mdvcore_hex_render
    // symbol. TEETH: dropping aux → empty dump diverges from the symbol's.
    let data: [u8; 5] = [0x00, 0x41, 0x7f, 0xff, 0x42];
    let req = mdvcore_core::wire::encode_frame(&mdvcore_core::hex::RenderAuxRequest {
        width: 4,
        total_byte_count: data.len() as u64,
        is_truncated: false,
    })
    .unwrap();
    let mut via = MdvBuf::empty();
    let s1 = unsafe {
        mdvcore_call(
            MDV_METHOD_HEX_RENDER,
            req.as_ptr(),
            req.len(),
            data.as_ptr(),
            data.len(),
            &mut via,
        )
    };
    let via_bytes = unsafe { via.as_slice() }.to_vec();
    let mut direct = MdvBuf::empty();
    let s2 = unsafe { mdvcore_hex_render(data.as_ptr(), data.len(), 4, data.len() as u64, false, &mut direct) };
    let direct_bytes = unsafe { direct.as_slice() }.to_vec();
    assert_eq!(s1, MdvStatus::Ok, "hex render via the envelope succeeds");
    assert_eq!(s1, s2, "envelope and the hex_render symbol return the same status");
    assert_eq!(via_bytes, direct_bytes, "byte-identical raw dump — aux carried the bytes");
    assert!(!via_bytes.is_empty(), "a non-empty buffer renders a non-empty dump");
    // Also pin the over-cap width clamp agrees across the two entry points
    // (the core MAX_HEX_WIDTH mirrors the FFI ABI constant).
    let req_big = mdvcore_core::wire::encode_frame(&mdvcore_core::hex::RenderAuxRequest {
        width: MAX_HEX_WIDTH + 1,
        total_byte_count: data.len() as u64,
        is_truncated: false,
    })
    .unwrap();
    let mut via_big = MdvBuf::empty();
    unsafe {
        mdvcore_call(MDV_METHOD_HEX_RENDER, req_big.as_ptr(), req_big.len(), data.as_ptr(), data.len(), &mut via_big);
    }
    let via_big_bytes = unsafe { via_big.as_slice() }.to_vec();
    let mut direct_big = MdvBuf::empty();
    unsafe {
        mdvcore_hex_render(data.as_ptr(), data.len(), MAX_HEX_WIDTH + 1, data.len() as u64, false, &mut direct_big);
    }
    let direct_big_bytes = unsafe { direct_big.as_slice() }.to_vec();
    assert_eq!(via_big_bytes, direct_big_bytes, "over-cap width clamps identically on both entry points");
    unsafe { mdvcore_buf_free(&mut via) };
    unsafe { mdvcore_buf_free(&mut direct) };
    unsafe { mdvcore_buf_free(&mut via_big) };
    unsafe { mdvcore_buf_free(&mut direct_big) };
}

#[test]
fn envelope_unknown_method_is_unknown_method_not_internal() {
    // TSK-982: a method id this build doesn't know is a method-space SKEW, not a
    // fault — it must return the dedicated `UnknownMethod`, NOT `Internal`, so a
    // version/capability skew is distinguishable from a genuine core crash.
    // TEETH: pre-fix both arms returned `Internal`, so the `assert_ne!`s fail red.
    let mut buf = MdvBuf::empty();

    let reserved = unsafe { mdvcore_call(0, core::ptr::null(), 0, core::ptr::null(), 0, &mut buf) };
    assert_eq!(reserved, MdvStatus::UnknownMethod, "id 0 is reserved (no method)");
    assert_ne!(reserved, MdvStatus::Internal, "must NOT collapse to the fault catch-all");

    let future = unsafe { mdvcore_call(9999, core::ptr::null(), 0, core::ptr::null(), 0, &mut buf) };
    assert_eq!(
        future,
        MdvStatus::UnknownMethod,
        "an id from a newer ABI is UnknownMethod (forward-compat skew), not UB"
    );
    assert_ne!(future, MdvStatus::Internal, "must NOT collapse to the fault catch-all");

    // The skew status carries its own stable discriminant (7), never the
    // Internal=99 / Panic=98 catch-alls.
    assert_eq!(MdvStatus::UnknownMethod as i32, 7);

    unsafe { mdvcore_buf_free(&mut buf) };
}

#[test]
fn envelope_null_out_buf_is_nullarg() {
    assert_eq!(
        unsafe {
            mdvcore_call(2, core::ptr::null(), 0, core::ptr::null(), 0, core::ptr::null_mut())
        },
        MdvStatus::NullArg
    );
}

#[test]
fn envelope_malformed_request_emits_wire_error() {
    // Garbage body reaches diff::parse_wire through the envelope → WireError +
    // (TSK-577) a rich WireError frame in out_buf. Proves the request bytes are
    // routed to the method, not dropped.
    let bad: [u8; 6] = [2, 0, 0, 0, 0xC1, 0xC1];
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_call(2, bad.as_ptr(), bad.len(), core::ptr::null(), 0, &mut buf) };
    assert_eq!(st, MdvStatus::WireError);
    let frame = unsafe { buf.as_slice() }.to_vec();
    let err: mdvcore_core::wire::WireError =
        mdvcore_core::wire::decode_frame(&frame).expect("envelope emits the WireError frame too");
    assert_eq!(err.code, MdvStatus::WireError as i32);
    unsafe { mdvcore_buf_free(&mut buf) };
}

// ===== TSK-577: the rich WireError channel is actually emitted =====

#[test]
fn wire_error_frame_is_emitted_on_a_malformed_request() {
    // A frame with a valid 4-byte LE length prefix (2) but a non-MessagePack-map
    // body → the stateless export's decode fails → WireFault::Decode. TEETH:
    // revert write_wire_error → wire_status (leaving out_buf empty) and the
    // non-empty assertion below reds.
    let req: [u8; 6] = [2, 0, 0, 0, 0xC1, 0xC1]; // 0xC1 is the reserved/never-used msgpack marker
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_diff_parse(req.as_ptr(), req.len(), &mut buf) };
    assert_eq!(st, MdvStatus::WireError);
    let frame = unsafe { buf.as_slice() }.to_vec();
    assert!(
        !frame.is_empty(),
        "the error path must emit a WireError frame, not leave out_buf empty"
    );
    let err: mdvcore_core::wire::WireError =
        mdvcore_core::wire::decode_frame(&frame).expect("out_buf decodes as a WireError");
    assert_eq!(
        err.code,
        MdvStatus::WireError as i32,
        "code matches the C status"
    );
    assert!(
        !err.message.is_empty(),
        "the message carries diagnostic context"
    );
    assert!(
        err.data.iter().any(|(k, v)| k == "kind" && !v.is_empty()),
        "a kind tag classifies the fault: {:?}",
        err.data
    );
    unsafe { mdvcore_buf_free(&mut buf) };
}

#[test]
fn wire_error_frame_carries_the_framing_kind_on_a_bad_prefix() {
    // A length prefix that exceeds the body → WireFault::Framing → kind=framing.
    let req: [u8; 4] = [0xFF, 0xFF, 0xFF, 0xFF]; // declared 4 GiB, zero body
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_diff_parse(req.as_ptr(), req.len(), &mut buf) };
    assert_eq!(st, MdvStatus::WireError);
    let frame = unsafe { buf.as_slice() }.to_vec();
    let err: mdvcore_core::wire::WireError =
        mdvcore_core::wire::decode_frame(&frame).expect("out_buf decodes as a WireError");
    assert!(
        err.data.iter().any(|(k, v)| k == "kind" && v == "framing"),
        "framing fault tagged: {:?}",
        err.data
    );
    unsafe { mdvcore_buf_free(&mut buf) };
}

#[test]
fn wire_fault_kind_tags_every_variant() {
    use mdvcore_core::wire::WireFault;
    assert_eq!(
        crate::wire_fault_kind(&WireFault::Encode("x".into())),
        "encode"
    );
    assert_eq!(
        crate::wire_fault_kind(&WireFault::Decode("x".into())),
        "decode"
    );
    assert_eq!(
        crate::wire_fault_kind(&WireFault::Framing("x".into())),
        "framing"
    );
    assert_eq!(
        crate::wire_fault_kind(&WireFault::TooLarge("x".into())),
        "too_large"
    );
}

// ===== TSK-541: Arc-backed handle registry (free-vs-call soundness) =====

#[test]
fn into_raw_registers_and_free_unregisters() {
    // Token-specific pin (deterministic under cargo's parallel tests, which
    // share the global registry). Teeth: skip the insert in `into_raw` → the
    // first assert reds; skip the remove in `free` → the second reds.
    let h = open(CSV);
    assert!(
        SessionHandle::lookup(h).is_some(),
        "open must register the token"
    );
    unsafe { mdvcore_session_free(h) };
    assert!(
        SessionHandle::lookup(h).is_none(),
        "free must unregister the token"
    );
}

#[test]
fn free_invalidates_token_but_inflight_clone_survives() {
    // The core TSK-541 guarantee, made deterministic: a call that already holds
    // an Arc clone (mid-`with` in the real race) keeps the session alive even
    // after `free` removed it from the registry — no UAF — while the TOKEN is
    // immediately dead so no NEW call can reach the freed session.
    let h = open(CSV);
    let inflight = SessionHandle::lookup(h).expect("token is live before free");

    unsafe { mdvcore_session_free(h) };

    assert!(
        SessionHandle::lookup(h).is_none(),
        "the token is dead the instant free removes it from the registry"
    );
    // The clone taken BEFORE free still names a live session — the Arc deferred
    // the drop. With the old Box::from_raw this access was a use-after-free.
    let still_alive = inflight.with(|session| session.table_frame().is_ok());
    assert_eq!(
        still_alive,
        Ok(true),
        "the in-flight Arc clone must still serve the session after free"
    );
}

#[test]
fn double_free_and_bogus_token_are_safe_noops() {
    let h = open(CSV);
    unsafe { mdvcore_session_free(h) };
    // Second free of the same (now-dead) token: idempotent no-op, not a
    // double-free. The old Box::from_raw twice was heap corruption.
    unsafe { mdvcore_session_free(h) };
    // A token never produced by into_raw is looked up, never dereferenced.
    assert!(SessionHandle::lookup(0xDEAD_BEEF as *mut SessionHandle).is_none());
    assert!(SessionHandle::lookup(std::ptr::null_mut()).is_none());
    // Freeing garbage / null is a no-op too (no panic, no UB).
    unsafe { mdvcore_session_free(0xDEAD_BEEF as *mut SessionHandle) };
    unsafe { mdvcore_session_free(std::ptr::null_mut()) };
}

#[test]
fn concurrent_calls_are_serialized_or_rejected_never_ub() {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;

    // Share ONE handle across threads (the SessionHandle is Send+Sync because
    // of the internal Mutex). Each thread hammers set_filter + snapshot. The
    // Mutex guarantees no data race; some calls may return Busy (try_lock
    // contention) — both Ok and Busy are acceptable, a crash/UB is not.
    let h = open(CSV);
    let ptr = h as usize; // move a usize across the boundary (Send-safe)
    let ok = Arc::new(AtomicUsize::new(0));
    let busy = Arc::new(AtomicUsize::new(0));

    let mut threads = Vec::new();
    for t in 0..8 {
        let ok = Arc::clone(&ok);
        let busy = Arc::clone(&busy);
        threads.push(thread::spawn(move || {
            let h = ptr as *mut SessionHandle;
            let needle = if t % 2 == 0 {
                b"par".as_slice()
            } else {
                b"a".as_slice()
            };
            for _ in 0..200 {
                let st =
                    unsafe { mdvcore_session_set_filter(h, needle.as_ptr(), needle.len(), -1) };
                match st {
                    MdvStatus::Ok => {
                        ok.fetch_add(1, Ordering::Relaxed);
                    }
                    MdvStatus::Busy => {
                        busy.fetch_add(1, Ordering::Relaxed);
                    }
                    other => panic!("unexpected status under contention: {other:?}"),
                }
                let mut buf = MdvBuf::empty();
                let st2 = unsafe { mdvcore_session_snapshot(h, &mut buf) };
                assert!(matches!(st2, MdvStatus::Ok | MdvStatus::Busy));
                unsafe { mdvcore_buf_free(&mut buf) };
            }
        }));
    }
    for th in threads {
        th.join().unwrap();
    }
    // Every operation resolved to either Ok or Busy — no UB, no crash.
    let total = ok.load(Ordering::Relaxed) + busy.load(Ordering::Relaxed);
    assert_eq!(total, 8 * 200);
    unsafe { mdvcore_session_free(h) };
}

#[test]
fn snapshot_is_level_triggered_full_state() {
    // After several filter changes, the snapshot reflects ONLY the latest
    // query as full current state (not an accumulation of deltas).
    let h = open(CSV);
    let q1 = b"par";
    unsafe { mdvcore_session_set_filter(h, q1.as_ptr(), q1.len(), -1) };
    let q2 = b"berlin";
    unsafe { mdvcore_session_set_filter(h, q2.as_ptr(), q2.len(), -1) };
    let snap = snapshot_of(h);
    assert_eq!(snap.query, "berlin");
    assert_eq!(snap.rows.len(), 1);
    assert_eq!(snap.rows[0][1], "Berlin");
    unsafe { mdvcore_session_free(h) };
}

// ---------------------------------------------------------------------------
// TSK-582 misuse matrix: every stateless export gets direct null-arg /
// zero-len / hostile-input coverage. Each error path must (a) return the
// documented status, (b) leave out_buf safe to free, (c) never crash.
// ---------------------------------------------------------------------------

/// A hostile "frame": the u32 LE length prefix declares ~2 GiB but only two
/// body bytes follow. The unframe step must reject it as a wire error, not
/// trust the declared length.
const HOSTILE_FRAME: &[u8] = &[0xFF, 0xFF, 0xFF, 0x7F, 0x01, 0x02];

/// TSK-634 stage 2: the shared misuse matrix for every `ffi_frame_body!`
/// export — null out_buf → NullArg; null req + nonzero len → NullArg (never
/// dereferenced); empty input → WireError with out_buf still freeable;
/// hostile length prefix → WireError, not an OOB read. One macro invocation
/// per export keeps the TSK-582 matrix complete as the surface grows —
/// adopting the body macro AND this test macro is the whole ceremony.
macro_rules! frame_export_misuse_matrix {
    ($test_name:ident, $export:ident) => {
        #[test]
        fn $test_name() {
            // null out_buf → NullArg
            assert_eq!(
                unsafe { $export(core::ptr::null(), 0, core::ptr::null_mut()) },
                MdvStatus::NullArg
            );
            // null req with nonzero len → NullArg (never dereferenced)
            let mut buf = MdvBuf::empty();
            assert_eq!(
                unsafe { $export(core::ptr::null(), 4, &mut buf) },
                MdvStatus::NullArg
            );
            // empty input is not a valid frame → WireError, out_buf still freeable
            assert_eq!(
                unsafe { $export(core::ptr::null(), 0, &mut buf) },
                MdvStatus::WireError
            );
            unsafe { mdvcore_buf_free(&mut buf) };
            // hostile prefix (declared len >> body) → WireError, not an OOB read
            let mut buf2 = MdvBuf::empty();
            assert_eq!(
                unsafe { $export(HOSTILE_FRAME.as_ptr(), HOSTILE_FRAME.len(), &mut buf2) },
                MdvStatus::WireError
            );
            unsafe { mdvcore_buf_free(&mut buf2) };
        }
    };
}

frame_export_misuse_matrix!(diff_parse_misuse_matrix, mdvcore_diff_parse);
frame_export_misuse_matrix!(highlight_runs_misuse_matrix, mdvcore_highlight_runs);

#[test]
fn highlight_runs_round_trip_through_the_export() {
    // The full boundary: encode a {text, lang} frame, call the extern fn,
    // decode {supported, runs} — UTF-16 offsets + app TokenKind rawValues.
    let frame = mdvcore_core::wire::encode_frame(&highlight_runs::RunsRequest {
        text: "fn main() { let x = 7; }".into(),
        lang: "rust".into(),
    })
    .unwrap();
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_highlight_runs(frame.as_ptr(), frame.len(), &mut buf) };
    assert_eq!(st, MdvStatus::Ok);
    let out = unsafe { buf.as_slice() }.to_vec();
    unsafe { mdvcore_buf_free(&mut buf) };
    let resp: highlight_runs::RunsResponse = mdvcore_core::wire::decode_frame(&out).unwrap();
    assert!(resp.supported);
    assert!(resp.runs.iter().any(|r| r.kind == "keyword"));

    // Unsupported language: supported=false, NOT an error (the host's
    // fall-back signal rides in-band).
    let frame2 = mdvcore_core::wire::encode_frame(&highlight_runs::RunsRequest {
        text: "anything".into(),
        lang: "plain".into(),
    })
    .unwrap();
    let mut buf2 = MdvBuf::empty();
    let st2 = unsafe { mdvcore_highlight_runs(frame2.as_ptr(), frame2.len(), &mut buf2) };
    assert_eq!(st2, MdvStatus::Ok);
    let out2 = unsafe { buf2.as_slice() }.to_vec();
    unsafe { mdvcore_buf_free(&mut buf2) };
    let resp2: highlight_runs::RunsResponse = mdvcore_core::wire::decode_frame(&out2).unwrap();
    assert!(!resp2.supported);
    assert!(resp2.runs.is_empty());
}

frame_export_misuse_matrix!(diff_hunk_marks_misuse_matrix, mdvcore_diff_hunk_marks);

#[test]
fn hex_render_misuse_matrix() {
    // null out_buf → NullArg
    assert_eq!(
        unsafe { mdvcore_hex_render(core::ptr::null(), 0, 16, 0, false, core::ptr::null_mut()) },
        MdvStatus::NullArg
    );
    // null bytes with nonzero len → NullArg
    let mut buf = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_hex_render(core::ptr::null(), 8, 16, 8, false, &mut buf) },
        MdvStatus::NullArg
    );
    // empty input is a valid (empty) dump → Ok
    assert_eq!(
        unsafe { mdvcore_hex_render(core::ptr::null(), 0, 16, 0, false, &mut buf) },
        MdvStatus::Ok
    );
    unsafe { mdvcore_buf_free(&mut buf) };
}

#[test]
fn hex_search_misuse_matrix() {
    let data = b"deadbeef";
    let q = b"ad";
    // null out_buf → NullArg
    assert_eq!(
        unsafe {
            mdvcore_hex_search(
                data.as_ptr(),
                data.len(),
                q.as_ptr(),
                q.len(),
                1,
                core::ptr::null_mut(),
            )
        },
        MdvStatus::NullArg
    );
    // null data with nonzero len → NullArg
    let mut buf = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_hex_search(core::ptr::null(), 8, q.as_ptr(), q.len(), 1, &mut buf) },
        MdvStatus::NullArg
    );
    // null query with nonzero len → NullArg
    assert_eq!(
        unsafe { mdvcore_hex_search(data.as_ptr(), data.len(), core::ptr::null(), 2, 1, &mut buf) },
        MdvStatus::NullArg
    );
    // non-UTF-8 query → BadUtf8 (documented), not a panic in str::from_utf8
    let bad = [0xFFu8, 0xFE];
    assert_eq!(
        unsafe {
            mdvcore_hex_search(
                data.as_ptr(),
                data.len(),
                bad.as_ptr(),
                bad.len(),
                1,
                &mut buf,
            )
        },
        MdvStatus::BadUtf8
    );
    // empty query → Ok with an (empty) offsets frame, per the docs
    assert_eq!(
        unsafe { mdvcore_hex_search(data.as_ptr(), data.len(), core::ptr::null(), 0, 0, &mut buf) },
        MdvStatus::Ok
    );
    unsafe { mdvcore_buf_free(&mut buf) };
    // hostile mode value (neither 0 nor 1) falls back to hex parsing → total
    let mut buf2 = MdvBuf::empty();
    assert_eq!(
        unsafe {
            mdvcore_hex_search(
                data.as_ptr(),
                data.len(),
                q.as_ptr(),
                q.len(),
                u32::MAX,
                &mut buf2,
            )
        },
        MdvStatus::Ok
    );
    unsafe { mdvcore_buf_free(&mut buf2) };
}

#[test]
fn indent_detect_misuse_matrix() {
    let text = b"\tfoo\n\tbar\n";
    // null out_buf → NullArg
    assert_eq!(
        unsafe { mdvcore_indent_detect(text.as_ptr(), text.len(), 100, core::ptr::null_mut()) },
        MdvStatus::NullArg
    );
    // null text with nonzero len → NullArg
    let mut buf = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_indent_detect(core::ptr::null(), 4, 100, &mut buf) },
        MdvStatus::NullArg
    );
    // non-UTF-8 text → BadUtf8
    let bad = [0xFFu8, 0xFE, 0x00];
    assert_eq!(
        unsafe { mdvcore_indent_detect(bad.as_ptr(), bad.len(), 100, &mut buf) },
        MdvStatus::BadUtf8
    );
    // empty text → Ok (a real "no indentation" answer, not an error)
    assert_eq!(
        unsafe { mdvcore_indent_detect(core::ptr::null(), 0, 100, &mut buf) },
        MdvStatus::Ok
    );
    unsafe { mdvcore_buf_free(&mut buf) };
    // sample_lines == 0 must be total (no division/indexing surprises)
    let mut buf2 = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_indent_detect(text.as_ptr(), text.len(), 0, &mut buf2) },
        MdvStatus::Ok
    );
    unsafe { mdvcore_buf_free(&mut buf2) };
}

/// TSK-123 perf guard — the session_table FFI path must encode from arena
/// SPANS (`session.table_frame()`), never materialize + clone the whole
/// Table (`session.to_table()`). The original S2 finding was a per-call
/// whole-Table clone; TSK-546's arena store removed the resident Table
/// entirely, so the resident-clone class is structurally gone — but a
/// behavioral test can't catch a revert (a clone produces byte-identical
/// output). This pins the hot path so a regression to materialize-then-
/// encode flips it red.
#[test]
fn session_table_ffi_encodes_from_spans_not_a_clone() {
    let src = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/lib.rs"))
        .expect("ffi lib.rs readable");
    // `split_once`/`split` avoid string-index slicing (the no-panic
    // string_slice lint, TSK-566). Take from the fn's signature, then
    // truncate at the next export so we test THIS fn's body only.
    let from_fn = src
        .split_once("pub unsafe extern \"C\" fn mdvcore_session_table")
        .map(|(_, rest)| rest)
        .expect("mdvcore_session_table present");
    let body = from_fn
        .split("#[unsafe(no_mangle)]")
        .next()
        .unwrap_or(from_fn);
    assert!(
        body.contains("session.table_frame()"),
        "session_table must encode from arena spans (TSK-123/546), not clone"
    );
    assert!(
        !body.contains("to_table()"),
        "session_table must NOT materialize + clone the whole Table"
    );
}

// ---------------------------------------------------------------------------
// Canvas (TSK-1360 M1.S5c) — smoke the REAL engine through the C ABI.
// ---------------------------------------------------------------------------

/// Open an empty canvas doc, returning the raw handle (caller frees).
fn canvas_open() -> *mut canvas_handle::CanvasHandle {
    let mut h: *mut canvas_handle::CanvasHandle = core::ptr::null_mut();
    let st = unsafe { mdvcore_canvas_doc_open(&mut h) };
    assert_eq!(st, MdvStatus::Ok);
    assert!(!h.is_null());
    h
}

/// Build a `{baseRev, ops}` request frame from raw serde values.
fn canvas_req(base_rev: u64, ops: Vec<CanvasWireOp>) -> Vec<u8> {
    #[derive(serde::Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Req {
        base_rev: u64,
        ops: Vec<CanvasWireOp>,
    }
    mdvcore_core::wire::encode_frame(&Req { base_rev, ops }).unwrap()
}

#[derive(serde::Serialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum CanvasWireOp {
    #[serde(rename_all = "camelCase")]
    Insert {
        id: String,
        kind: String,
        parent: String,
        pos: CanvasWirePos,
        props: Vec<(String, String)>,
    },
    #[serde(rename_all = "camelCase")]
    Update {
        id: String,
        set: Vec<(String, String)>,
        unset: Vec<String>,
    },
}

#[derive(serde::Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum CanvasWirePos {
    Last,
}

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanvasResp {
    rev: Option<u64>,
    patches: Option<Vec<CanvasPatchEcho>>,
    rejected: Option<String>,
    lint: Option<Vec<CanvasLintEcho>>,
}
#[derive(Debug, serde::Deserialize)]
struct CanvasLintEcho {
    code: String,
}
#[derive(Debug, serde::Deserialize)]
struct CanvasPatchEcho {
    op: String,
    #[serde(default)]
    html: Option<String>,
}

fn canvas_apply(h: *mut canvas_handle::CanvasHandle, frame: &[u8]) -> (MdvStatus, Vec<u8>) {
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_canvas_apply(h, frame.as_ptr(), frame.len(), &mut buf) };
    let bytes = unsafe { buf.as_slice() }.to_vec();
    unsafe { mdvcore_buf_free(&mut buf) };
    (st, bytes)
}

#[test]
fn canvas_doc_open_apply_html_roundtrip() {
    let h = canvas_open();

    // Empty doc lowers to the root page + theme block.
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_canvas_html(h, &mut buf) };
    assert_eq!(st, MdvStatus::Ok);
    let html0 = String::from_utf8(unsafe { buf.as_slice() }.to_vec()).unwrap();
    unsafe { mdvcore_buf_free(&mut buf) };
    assert!(html0.contains("data-cv-id=\"pg:1\""));
    assert!(html0.contains("--cv-color-accent"));

    // Insert a text node through the REAL wire; expect an insertNode patch.
    let frame = canvas_req(
        0,
        vec![CanvasWireOp::Insert {
            id: "nd:t1".to_owned(),
            kind: "text".to_owned(),
            parent: "pg:1".to_owned(),
            pos: CanvasWirePos::Last,
            props: vec![("text".to_owned(), "from the ABI".to_owned())],
        }],
    );
    let (st, resp) = canvas_apply(h, &frame);
    assert_eq!(st, MdvStatus::Ok);
    let echo: CanvasResp = mdvcore_core::wire::decode_frame(&resp).unwrap();
    assert_eq!(echo.rev, Some(1));
    let patches = echo.patches.unwrap();
    assert_eq!(patches.len(), 1);
    assert_eq!(patches[0].op, "insertNode");
    assert!(patches[0].html.as_deref().unwrap().contains(">from the ABI<"));

    // Lint rides the C-ABI response too (S6).
    let lit = canvas_req(
        1,
        vec![CanvasWireOp::Insert {
            id: "nd:s".to_owned(),
            kind: "shape".to_owned(),
            parent: "pg:1".to_owned(),
            pos: CanvasWirePos::Last,
            props: vec![("fill".to_owned(), "#ff0000".to_owned())],
        }],
    );
    let (st, resp) = canvas_apply(h, &lit);
    assert_eq!(st, MdvStatus::Ok);
    let echo: CanvasResp = mdvcore_core::wire::decode_frame(&resp).unwrap();
    let lint = echo.lint.unwrap_or_default();
    assert!(lint.iter().any(|l| l.code == "raw-literal-themeable"), "got {lint:?}");

    // State stuck: re-lower carries the node.
    let mut buf2 = MdvBuf::empty();
    assert_eq!(unsafe { mdvcore_canvas_html(h, &mut buf2) }, MdvStatus::Ok);
    let html1 = String::from_utf8(unsafe { buf2.as_slice() }.to_vec()).unwrap();
    unsafe { mdvcore_buf_free(&mut buf2) };
    assert!(html1.contains(">from the ABI<"));

    unsafe { mdvcore_canvas_free(h) };
    // Freed handle degrades to NullArg; double free is a no-op.
    unsafe { mdvcore_canvas_free(h) };
    let mut buf3 = MdvBuf::empty();
    assert_eq!(unsafe { mdvcore_canvas_html(h, &mut buf3) }, MdvStatus::NullArg);
    unsafe { mdvcore_buf_free(&mut buf3) };
}

#[test]
fn canvas_rejections_come_back_as_structured_frames_with_ok_status() {
    let h = canvas_open();
    // Stale baseRev → Ok status + {rejected: "conflict"} frame.
    let frame = canvas_req(42, vec![]);
    let (st, resp) = canvas_apply(h, &frame);
    assert_eq!(st, MdvStatus::Ok);
    let echo: CanvasResp = mdvcore_core::wire::decode_frame(&resp).unwrap();
    assert_eq!(echo.rejected.as_deref(), Some("conflict"));
    // Fence violation (text prop on a frame) → structured "fence" rejection.
    let bad = canvas_req(
        0,
        vec![CanvasWireOp::Insert {
            id: "nd:f".to_owned(),
            kind: "frame".to_owned(),
            parent: "pg:1".to_owned(),
            pos: CanvasWirePos::Last,
            props: vec![("text".to_owned(), "nope".to_owned())],
        }],
    );
    let (st, resp) = canvas_apply(h, &bad);
    assert_eq!(st, MdvStatus::Ok);
    let echo: CanvasResp = mdvcore_core::wire::decode_frame(&resp).unwrap();
    assert_eq!(echo.rejected.as_deref(), Some("fence"));
    unsafe { mdvcore_canvas_free(h) };
}

#[test]
fn canvas_malformed_frame_is_wire_error_and_null_args_rejected() {
    let h = canvas_open();
    let junk = [0xFFu8, 0x01, 0x02];
    let mut buf = MdvBuf::empty();
    let st = unsafe { mdvcore_canvas_apply(h, junk.as_ptr(), junk.len(), &mut buf) };
    assert_eq!(st, MdvStatus::WireError);
    unsafe { mdvcore_buf_free(&mut buf) };
    assert_eq!(
        unsafe { mdvcore_canvas_doc_open(core::ptr::null_mut()) },
        MdvStatus::NullArg
    );
    assert_eq!(
        unsafe { mdvcore_canvas_html(h, core::ptr::null_mut()) },
        MdvStatus::NullArg
    );
    let mut buf2 = MdvBuf::empty();
    assert_eq!(
        unsafe { mdvcore_canvas_apply(h, core::ptr::null(), 3, &mut buf2) },
        MdvStatus::NullArg
    );
    unsafe { mdvcore_buf_free(&mut buf2) };
    unsafe { mdvcore_canvas_free(h) };
}
