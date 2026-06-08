//! Pure most-recently-used (MRU) list management for the front-ends'
//! recently-opened / history features.
//!
//! Sans-IO and sans-time: the front-end decides WHEN to record an open and
//! WHERE (if at all) to persist the list; the core only maintains the ordered,
//! de-duplicated, capped sequence. Keeping it here means the TUI and web tiers
//! share one definition of "recent" (newest-first, no duplicates, bounded).

/// Record `item` as the most-recent entry of `list`: drop any prior occurrence
/// (so the list stays de-duplicated), put `item` at the FRONT, then bound the
/// result to `cap` entries. A re-opened item is thus *bumped* to the front
/// rather than duplicated. `cap == 0` yields an empty list. Returns the new list.
#[must_use]
pub fn push<T: PartialEq>(mut list: Vec<T>, item: T, cap: usize) -> Vec<T> {
    list.retain(|x| x != &item);
    list.insert(0, item);
    list.truncate(cap);
    list
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newest_goes_to_the_front_in_order() {
        let mut l: Vec<String> = Vec::new();
        l = push(l, "a".into(), 10);
        l = push(l, "b".into(), 10);
        l = push(l, "c".into(), 10);
        assert_eq!(l, vec!["c", "b", "a"], "most-recent first");
    }

    #[test]
    fn reopening_bumps_to_front_without_duplicating() {
        let l = vec!["a".to_string(), "b".into(), "c".into()];
        let l = push(l, "c".into(), 10);
        assert_eq!(l, vec!["c", "a", "b"], "c moved to front, no dup");
        assert_eq!(l.iter().filter(|x| *x == "c").count(), 1, "exactly one c");
    }

    #[test]
    fn cap_evicts_the_oldest() {
        let mut l: Vec<i32> = Vec::new();
        for n in 0..5 {
            l = push(l, n, 3);
        }
        assert_eq!(l, vec![4, 3, 2], "only the 3 newest survive, newest first");
    }

    #[test]
    fn cap_zero_is_always_empty() {
        let l = push(Vec::new(), "x".to_string(), 0);
        assert!(l.is_empty(), "cap 0 keeps nothing");
    }

    #[test]
    fn bumping_an_existing_item_does_not_grow_past_cap() {
        let l = vec!["a".to_string(), "b".into(), "c".into()];
        let l = push(l, "b".into(), 3);
        assert_eq!(l, vec!["b", "a", "c"], "bump within a full list stays at cap");
    }
}
