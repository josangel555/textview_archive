//! Canvas M1.S4 — the design-token store (TSK-1359; 02-CORE-ENGINE §5).
//!
//! DTCG-SHAPED (pinned to the 2025.10 snapshot's semantics, own validator —
//! analysis C1): tokens are `path → value-or-alias`, aliases are token paths
//! (the `{color.primary}` brace form on the wire maps here), renames are
//! DEPRECATE-AND-ALIAS (never hard-delete — the Spectrum lesson), and the
//! runtime output is CSS custom properties (`--cv-*`).
//!
//! Tier convention (research §3: three tiers, agents steered to tier-2):
//! `base.*` = tier-1 primitives; every other namespace (`color.*`, `space.*`,
//! `font.*`, `radius.*`, `shadow.*`, `type.*`) = tier-2 semantic. The S6 lint
//! nags literals-in-themeable-slots and tier-1 references by agents; this
//! module provides the store, resolution, and validation they hook into.

use std::collections::HashMap;

/// Alias-chain depth cap — a cycle detector backstop and a DoS bound.
const MAX_ALIAS_DEPTH: usize = 16;

/// A token's stored value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenValue {
    /// A concrete CSS value (`"#0a84ff"`, `"12px"`, `"600 14px system-ui"`).
    Literal(String),
    /// A reference to another token path (DTCG brace alias).
    Alias(String),
}

/// One token definition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenDef {
    pub value: TokenValue,
    /// Deprecated tokens STILL RESOLVE (via their alias/value) but carry the
    /// replacement path so lint can steer authors off them.
    pub deprecated_for: Option<String>,
}

/// Token faults.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenError {
    /// Path isn't `seg(.seg)*` of `[a-z0-9-]`.
    BadPath(String),
    Unknown(String),
    /// An alias chain revisited a path (or exceeded the depth cap).
    Cycle(String),
}

/// Validate the `seg(.seg)*` lowercase path shape.
fn check_path(path: &str) -> Result<(), TokenError> {
    let ok = !path.is_empty()
        && path.split('.').all(|seg| {
            !seg.is_empty()
                && seg
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        });
    if ok {
        Ok(())
    } else {
        Err(TokenError::BadPath(path.to_owned()))
    }
}

/// The token store.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TokenStore {
    defs: HashMap<String, TokenDef>,
}

impl TokenStore {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.defs.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.defs.is_empty()
    }

    #[must_use]
    pub fn exists(&self, path: &str) -> bool {
        self.defs.contains_key(path)
    }

    /// Is `path` a tier-1 primitive (agents are lint-steered away from these)?
    #[must_use]
    pub fn is_primitive(path: &str) -> bool {
        path.starts_with("base.")
    }

    /// Define/overwrite a literal token.
    pub fn set_literal(&mut self, path: &str, css: &str) -> Result<(), TokenError> {
        check_path(path)?;
        self.defs.insert(
            path.to_owned(),
            TokenDef {
                value: TokenValue::Literal(css.to_owned()),
                deprecated_for: None,
            },
        );
        Ok(())
    }

    /// Define/overwrite an alias token.
    pub fn set_alias(&mut self, path: &str, target: &str) -> Result<(), TokenError> {
        check_path(path)?;
        check_path(target)?;
        self.defs.insert(
            path.to_owned(),
            TokenDef {
                value: TokenValue::Alias(target.to_owned()),
                deprecated_for: None,
            },
        );
        Ok(())
    }

    /// Rename `old` → `new`: `new` takes `old`'s definition; `old` becomes a
    /// DEPRECATED alias to `new` (never a hard delete — references keep
    /// resolving; lint steers authors to the replacement).
    pub fn deprecate_and_alias(&mut self, old: &str, new: &str) -> Result<(), TokenError> {
        check_path(old)?;
        check_path(new)?;
        let Some(def) = self.defs.remove(old) else {
            return Err(TokenError::Unknown(old.to_owned()));
        };
        self.defs.insert(new.to_owned(), def);
        self.defs.insert(
            old.to_owned(),
            TokenDef {
                value: TokenValue::Alias(new.to_owned()),
                deprecated_for: Some(new.to_owned()),
            },
        );
        Ok(())
    }

    /// Resolve `path` through its alias chain to the concrete CSS value.
    /// Cycle-safe (visited tracking + depth cap).
    pub fn resolve(&self, path: &str) -> Result<&str, TokenError> {
        check_path(path)?;
        let mut visited: Vec<&str> = Vec::new();
        let mut current = path;
        loop {
            if visited.len() >= MAX_ALIAS_DEPTH || visited.contains(&current) {
                return Err(TokenError::Cycle(path.to_owned()));
            }
            let Some(def) = self.defs.get(current) else {
                return Err(TokenError::Unknown(current.to_owned()));
            };
            match &def.value {
                TokenValue::Literal(css) => return Ok(css),
                TokenValue::Alias(next) => {
                    visited.push(current);
                    current = next;
                }
            }
        }
    }

    /// Whole-store validation: every path well-formed, every alias resolves,
    /// no cycles. Returns every fault (not just the first).
    #[must_use]
    pub fn validate(&self) -> Vec<TokenError> {
        let mut faults = Vec::new();
        let mut paths: Vec<&String> = self.defs.keys().collect();
        paths.sort();
        for path in paths {
            if let Err(e) = self.resolve(path) {
                faults.push(e);
            }
        }
        faults
    }

    /// Emit the resolved store as CSS custom properties — deterministic
    /// (path-sorted), `--cv-` prefixed, dots → dashes. Unresolvable tokens are
    /// SKIPPED (validate() is the loud path; emission stays total).
    #[must_use]
    pub fn to_css_custom_props(&self) -> String {
        let mut paths: Vec<&String> = self.defs.keys().collect();
        paths.sort();
        let mut out = String::new();
        for path in paths {
            if let Ok(css) = self.resolve(path) {
                out.push_str("--cv-");
                for ch in path.chars() {
                    out.push(if ch == '.' { '-' } else { ch });
                }
                out.push_str(": ");
                out.push_str(css);
                out.push_str(";\n");
            }
        }
        out
    }

    /// The self-contained default theme (the shell overlays the live app
    /// theme on top — 03-SHELLS; core stays theme-source-agnostic).
    #[must_use]
    pub fn default_theme() -> Self {
        let mut t = TokenStore::new();
        let literals: &[(&str, &str)] = &[
            ("base.white", "#ffffff"),
            ("base.black", "#111111"),
            ("base.gray-1", "#f5f5f7"),
            ("base.gray-2", "#d2d2d7"),
            ("base.gray-3", "#6e6e73"),
            ("base.blue", "#0a84ff"),
            ("base.red", "#ff453a"),
            ("base.green", "#30d158"),
            ("base.yellow", "#ffd60a"),
            ("space.xs", "4px"),
            ("space.sm", "8px"),
            ("space.md", "16px"),
            ("space.lg", "24px"),
            ("space.xl", "40px"),
            ("radius.sm", "4px"),
            ("radius.md", "8px"),
            ("radius.lg", "16px"),
            ("shadow.1", "0 1px 3px rgba(0,0,0,0.2)"),
            ("shadow.2", "0 4px 12px rgba(0,0,0,0.25)"),
            ("font.body", "400 14px -apple-system, sans-serif"),
            ("font.h1", "700 28px -apple-system, sans-serif"),
            ("font.h2", "600 20px -apple-system, sans-serif"),
            ("font.mono", "400 13px ui-monospace, monospace"),
        ];
        let aliases: &[(&str, &str)] = &[
            ("color.bg", "base.white"),
            ("color.fg", "base.black"),
            ("color.muted", "base.gray-3"),
            ("color.surface", "base.gray-1"),
            ("color.border", "base.gray-2"),
            ("color.accent", "base.blue"),
            ("color.danger", "base.red"),
            ("color.success", "base.green"),
            ("color.warning", "base.yellow"),
        ];
        for (p, v) in literals {
            let _ = t.set_literal(p, v);
        }
        for (p, a) in aliases {
            let _ = t.set_alias(p, a);
        }
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn literal_and_alias_chains_resolve() {
        let mut t = TokenStore::new();
        t.set_literal("base.blue", "#00f").expect("lit");
        t.set_alias("color.accent", "base.blue").expect("alias");
        t.set_alias("color.link", "color.accent").expect("alias2");
        assert_eq!(t.resolve("color.link"), Ok("#00f"));
    }

    #[test]
    fn cycles_are_detected_not_looped() {
        let mut t = TokenStore::new();
        t.set_alias("color.a", "color.b").expect("a");
        t.set_alias("color.b", "color.a").expect("b");
        assert_eq!(t.resolve("color.a"), Err(TokenError::Cycle("color.a".into())));
        // Self-alias too.
        t.set_alias("color.selfie", "color.selfie").expect("s");
        assert!(matches!(t.resolve("color.selfie"), Err(TokenError::Cycle(_))));
        // validate() reports them all.
        let faults = t.validate();
        assert_eq!(faults.len(), 3);
    }

    #[test]
    fn deprecate_and_alias_keeps_old_paths_resolving() {
        let mut t = TokenStore::new();
        t.set_literal("color.primary", "#00f").expect("lit");
        t.deprecate_and_alias("color.primary", "color.accent").expect("rename");
        assert_eq!(t.resolve("color.accent"), Ok("#00f"));
        assert_eq!(t.resolve("color.primary"), Ok("#00f"), "old path still resolves");
        let dep = t.defs.get("color.primary").and_then(|d| d.deprecated_for.clone());
        assert_eq!(dep, Some("color.accent".to_owned()));
        assert!(matches!(
            t.deprecate_and_alias("color.never", "color.x"),
            Err(TokenError::Unknown(_))
        ));
    }

    #[test]
    fn bad_paths_and_unknowns_are_typed() {
        let mut t = TokenStore::new();
        assert!(matches!(t.set_literal("", "#fff"), Err(TokenError::BadPath(_))));
        assert!(matches!(t.set_literal("Color.BG", "#fff"), Err(TokenError::BadPath(_))));
        assert!(matches!(t.set_literal("a..b", "#fff"), Err(TokenError::BadPath(_))));
        assert!(matches!(t.resolve("color.nope"), Err(TokenError::Unknown(_))));
    }

    #[test]
    fn css_emission_is_deterministic_prefixed_and_total() {
        let mut t = TokenStore::new();
        t.set_literal("space.md", "16px").expect("lit");
        t.set_alias("color.bg", "base.missing").expect("dangling alias");
        let css = t.to_css_custom_props();
        assert!(css.contains("--cv-space-md: 16px;"));
        assert!(!css.contains("base-missing"), "unresolvable tokens are skipped");
        assert_eq!(css, t.to_css_custom_props(), "deterministic");
    }

    #[test]
    fn default_theme_fully_resolves_and_tiers_are_tagged() {
        let t = TokenStore::default_theme();
        assert!(t.validate().is_empty(), "default theme must be self-consistent");
        assert_eq!(t.resolve("color.accent"), Ok("#0a84ff"));
        assert!(TokenStore::is_primitive("base.blue"));
        assert!(!TokenStore::is_primitive("color.accent"));
        let css = t.to_css_custom_props();
        assert!(css.contains("--cv-color-accent: #0a84ff;"));
        assert!(css.contains("--cv-space-md: 16px;"));
    }
}
