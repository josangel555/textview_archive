//! Formula evaluator — the Rust port of the Swift `FormulaEngine` / `FormulaParser`
//! (rust-core migration; sheet epic TSK-673 / TSK-1212). Pure, sans-IO: a formula
//! string in, a typed `Value` out.
//!
//! **Slice 1 = the ARITHMETIC core** — number literals, the binary operators
//! `+ - * / ^`, unary `±`, postfix `%`, and parentheses, with the same precedence
//! the Swift engine pins (`^` right-assoc and binding TIGHTER than unary minus, so
//! `-2^2 = -4` and `2^3^2 = 512`; `%` is `/100`). Cell references, ranges, and the
//! full function library (SUM/IF/VLOOKUP/… already written in Swift, with 29
//! host tests) land in following slices, validated against that Swift corpus as
//! the cross-language golden cases (the TSK-586 parity pattern). FFI exposure +
//! the Swift CSV consumer rewiring are their own later slices.

use serde::{Deserialize, Serialize};

/// A computed formula/cell value. Mirrors the Swift `FormulaValue`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "lowercase")]
pub enum Value {
    /// A numeric result.
    Number(f64),
    /// A text result.
    Text(String),
    /// A boolean result.
    Bool(bool),
    /// An empty cell / no value.
    Blank,
    /// A typed error result.
    Error(FormulaError),
}

/// A typed formula error (Excel-style display). Mirrors the Swift `FormulaError`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FormulaError {
    /// `#DIV/0!` — division by zero.
    DivideByZero,
    /// `#VALUE!` — wrong type of operand.
    Value,
    /// `#REF!` — invalid cell reference.
    Ref,
    /// `#NAME?` — unknown function/name.
    Name,
    /// `#NUM!` — invalid numeric argument.
    Num,
    /// `#CYCLE!` — circular reference.
    Cycle,
    /// `#ERROR!` — the formula could not be parsed.
    Parse,
    /// `#N/A` — value not available (e.g. a lookup miss).
    Na,
}

impl FormulaError {
    /// The cell-display text Excel/Sheets show for this error.
    #[must_use]
    pub fn display(self) -> &'static str {
        match self {
            FormulaError::DivideByZero => "#DIV/0!",
            FormulaError::Value => "#VALUE!",
            FormulaError::Ref => "#REF!",
            FormulaError::Name => "#NAME?",
            FormulaError::Num => "#NUM!",
            FormulaError::Cycle => "#CYCLE!",
            FormulaError::Parse => "#ERROR!",
            FormulaError::Na => "#N/A",
        }
    }
}

// MARK: - Tokenizer

#[derive(Debug, Clone, PartialEq)]
enum Token {
    Number(f64),
    Plus,
    Minus,
    Star,
    Slash,
    Caret,
    Percent,
    LParen,
    RParen,
    /// An identifier run (letters then alphanumerics) — a cell reference like `A1`
    /// (functions/booleans are later slices).
    Ident(String),
}

fn tokenize(s: &str) -> Result<Vec<Token>, FormulaError> {
    let mut toks = Vec::new();
    let mut chars = s.chars().peekable();
    while let Some(&c) = chars.peek() {
        match c {
            ' ' | '\t' | '\n' | '\r' => { chars.next(); }
            '+' => { chars.next(); toks.push(Token::Plus); }
            '-' => { chars.next(); toks.push(Token::Minus); }
            '*' => { chars.next(); toks.push(Token::Star); }
            '/' => { chars.next(); toks.push(Token::Slash); }
            '^' => { chars.next(); toks.push(Token::Caret); }
            '%' => { chars.next(); toks.push(Token::Percent); }
            '(' => { chars.next(); toks.push(Token::LParen); }
            ')' => { chars.next(); toks.push(Token::RParen); }
            _ if c.is_ascii_digit() || c == '.' => {
                let mut lit = String::new();
                while let Some(&d) = chars.peek() {
                    if d.is_ascii_digit() || d == '.' {
                        lit.push(d);
                        chars.next();
                    } else {
                        break;
                    }
                }
                // optional scientific exponent: e/E [±] digits (f64::parse rejects a bare trailing 'e')
                if matches!(chars.peek(), Some(&'e') | Some(&'E')) {
                    lit.push('e');
                    chars.next();
                    if let Some(&(sign @ ('+' | '-'))) = chars.peek() {
                        lit.push(sign);
                        chars.next();
                    }
                    while let Some(&d) = chars.peek() {
                        if d.is_ascii_digit() {
                            lit.push(d);
                            chars.next();
                        } else {
                            break;
                        }
                    }
                }
                let n: f64 = lit.parse().map_err(|_| FormulaError::Parse)?;
                toks.push(Token::Number(n));
            }
            _ if c.is_ascii_alphabetic() => {
                let mut id = String::new();
                while let Some(&d) = chars.peek() {
                    if d.is_ascii_alphanumeric() {
                        id.push(d);
                        chars.next();
                    } else {
                        break;
                    }
                }
                toks.push(Token::Ident(id));
            }
            _ => return Err(FormulaError::Parse),
        }
    }
    Ok(toks)
}

// MARK: - AST + recursive-descent parser

#[derive(Debug, Clone, PartialEq)]
enum Expr {
    Number(f64),
    /// A cell reference (the raw A1-style identifier; parsed at eval time).
    Ref(String),
    Neg(Box<Expr>),
    Percent(Box<Expr>),
    Bin(BinOp, Box<Expr>, Box<Expr>),
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Pow,
}

struct Parser {
    toks: Vec<Token>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Token> {
        self.toks.get(self.pos)
    }

    fn parse(&mut self) -> Result<Expr, FormulaError> {
        let e = self.add()?;
        if self.pos != self.toks.len() {
            return Err(FormulaError::Parse); // trailing/unconsumed tokens
        }
        Ok(e)
    }

    fn add(&mut self) -> Result<Expr, FormulaError> {
        let mut left = self.mul()?;
        while let Some(op) = match self.peek() {
            Some(Token::Plus) => Some(BinOp::Add),
            Some(Token::Minus) => Some(BinOp::Sub),
            _ => None,
        } {
            self.pos += 1;
            let right = self.mul()?;
            left = Expr::Bin(op, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    fn mul(&mut self) -> Result<Expr, FormulaError> {
        let mut left = self.unary()?;
        while let Some(op) = match self.peek() {
            Some(Token::Star) => Some(BinOp::Mul),
            Some(Token::Slash) => Some(BinOp::Div),
            _ => None,
        } {
            self.pos += 1;
            let right = self.unary()?;
            left = Expr::Bin(op, Box::new(left), Box::new(right));
        }
        Ok(left)
    }

    // Unary ± binds LOOSER than ^ (so `-2^2` is `-(2^2)`).
    fn unary(&mut self) -> Result<Expr, FormulaError> {
        match self.peek() {
            Some(Token::Minus) => {
                self.pos += 1;
                Ok(Expr::Neg(Box::new(self.unary()?)))
            }
            Some(Token::Plus) => {
                self.pos += 1;
                self.unary()
            }
            _ => self.power(),
        }
    }

    // `^` right-assoc: the exponent recurses through `unary` (allows `2^-3`).
    fn power(&mut self) -> Result<Expr, FormulaError> {
        let base = self.postfix()?;
        if let Some(Token::Caret) = self.peek() {
            self.pos += 1;
            let exp = self.unary()?;
            Ok(Expr::Bin(BinOp::Pow, Box::new(base), Box::new(exp)))
        } else {
            Ok(base)
        }
    }

    fn postfix(&mut self) -> Result<Expr, FormulaError> {
        let mut e = self.primary()?;
        while let Some(Token::Percent) = self.peek() {
            self.pos += 1;
            e = Expr::Percent(Box::new(e));
        }
        Ok(e)
    }

    fn primary(&mut self) -> Result<Expr, FormulaError> {
        match self.toks.get(self.pos).cloned() {
            Some(Token::Number(n)) => {
                self.pos += 1;
                Ok(Expr::Number(n))
            }
            Some(Token::Ident(name)) => {
                self.pos += 1;
                Ok(Expr::Ref(name))
            }
            Some(Token::LParen) => {
                self.pos += 1;
                let e = self.add()?;
                match self.toks.get(self.pos) {
                    Some(Token::RParen) => {
                        self.pos += 1;
                        Ok(e)
                    }
                    _ => Err(FormulaError::Parse),
                }
            }
            _ => Err(FormulaError::Parse),
        }
    }
}

// MARK: - Evaluator

fn eval(e: &Expr, resolver: &dyn Fn(CellRef) -> Option<String>) -> Value {
    match e {
        Expr::Number(n) => Value::Number(*n),
        Expr::Ref(name) => match CellRef::parse(name) {
            Some(cr) => coerce_cell(resolver(cr)),
            None => Value::Error(FormulaError::Name), // not a valid ref (fns/bools: later slices)
        },
        Expr::Neg(inner) => match as_number(eval(inner, resolver)) {
            Ok(n) => Value::Number(-n),
            Err(v) => v,
        },
        Expr::Percent(inner) => match as_number(eval(inner, resolver)) {
            Ok(n) => Value::Number(n / 100.0),
            Err(v) => v,
        },
        Expr::Bin(op, l, r) => {
            let lv = match as_number(eval(l, resolver)) {
                Ok(n) => n,
                Err(v) => return v,
            };
            let rv = match as_number(eval(r, resolver)) {
                Ok(n) => n,
                Err(v) => return v,
            };
            match op {
                BinOp::Add => Value::Number(lv + rv),
                BinOp::Sub => Value::Number(lv - rv),
                BinOp::Mul => Value::Number(lv * rv),
                BinOp::Div => {
                    if rv == 0.0 {
                        Value::Error(FormulaError::DivideByZero)
                    } else {
                        Value::Number(lv / rv)
                    }
                }
                BinOp::Pow => Value::Number(lv.powf(rv)),
            }
        }
    }
}

/// Coerce a value to a number for arithmetic (Excel-style): numbers as-is,
/// bool→1/0, blank→0, numeric text parsed; non-numeric text→#VALUE; an error
/// propagates. `Ok(n)` or `Err(the Value to return)`.
fn as_number(v: Value) -> Result<f64, Value> {
    match v {
        Value::Number(n) => Ok(n),
        Value::Bool(b) => Ok(if b { 1.0 } else { 0.0 }),
        Value::Blank => Ok(0.0),
        Value::Text(s) => s
            .trim()
            .parse::<f64>()
            .map_err(|_| Value::Error(FormulaError::Value)),
        Value::Error(e) => Err(Value::Error(e)),
    }
}

/// Interpret a raw cell string as a value: empty/missing → Blank, numeric →
/// Number, otherwise Text. (Booleans arrive with the function/literal slice.)
fn coerce_cell(raw: Option<String>) -> Value {
    match raw {
        None => Value::Blank,
        Some(s) => {
            let t = s.trim();
            if t.is_empty() {
                Value::Blank
            } else if let Ok(n) = t.parse::<f64>() {
                Value::Number(n)
            } else {
                Value::Text(s)
            }
        }
    }
}

/// A 0-based cell coordinate. Mirrors the Swift `CellReference`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CellRef {
    /// 0-based column (A=0, B=1, …, Z=25, AA=26, …).
    pub col: u32,
    /// 0-based row (A1 → 0).
    pub row: u32,
}

impl CellRef {
    /// Parse an A1-style reference ("A1", "B12", "AA3") — bijective base-26 column,
    /// 1-based text row → 0-based. `None` if malformed.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        let mut chars = s.chars().peekable();
        let mut col: u32 = 0;
        let mut letters = 0u32;
        while let Some(&c) = chars.peek() {
            if c.is_ascii_alphabetic() {
                col = col
                    .checked_mul(26)?
                    .checked_add(c.to_ascii_uppercase() as u32 - 'A' as u32 + 1)?;
                chars.next();
                letters += 1;
            } else {
                break;
            }
        }
        if letters == 0 {
            return None;
        }
        let mut row: u32 = 0;
        let mut digits = 0u32;
        while let Some(&c) = chars.peek() {
            if c.is_ascii_digit() {
                row = row.checked_mul(10)?.checked_add(c as u32 - '0' as u32)?;
                chars.next();
                digits += 1;
            } else {
                break;
            }
        }
        if digits == 0 || row == 0 || chars.next().is_some() {
            return None;
        }
        Some(Self { col: col - 1, row: row - 1 })
    }
}

/// Evaluate with no cell grid — references resolve to blank. Convenience for
/// pure-arithmetic callers/tests.
#[must_use]
pub fn evaluate(formula: &str) -> Value {
    evaluate_with(formula, &|_| None)
}

/// Evaluate a formula against a cell resolver (`CellRef` → raw cell text, `None`
/// for a blank/out-of-range cell). An optional leading `=` is stripped; an empty
/// formula is `Blank`; a lexer/parser failure is `Error(Parse)`.
#[must_use]
pub fn evaluate_with(formula: &str, resolver: &dyn Fn(CellRef) -> Option<String>) -> Value {
    let trimmed = formula.trim();
    let body = trimmed.strip_prefix('=').unwrap_or(trimmed);
    let toks = match tokenize(body) {
        Ok(t) => t,
        Err(e) => return Value::Error(e),
    };
    if toks.is_empty() {
        return Value::Blank;
    }
    let mut p = Parser { toks, pos: 0 };
    match p.parse() {
        Ok(expr) => eval(&expr, resolver),
        Err(e) => Value::Error(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Assert a formula evaluates to an exact numeric value (no panic! — clippy clean).
    fn num(s: &str, expected: f64) {
        assert_eq!(evaluate(s), Value::Number(expected), "for {s:?}");
    }

    #[test]
    fn arithmetic_precedence() {
        num("1+2*3", 7.0); // * before +
        num("(1+2)*3", 9.0); // parens
        num("10-3-2", 5.0); // left-assoc -
        num("8/2/2", 2.0); // left-assoc /
    }

    #[test]
    fn power_right_assoc_and_unary_binding() {
        num("2^3^2", 512.0); // right-assoc: 2^(3^2)=2^9
        num("-2^2", -4.0); // unary minus looser than ^: -(2^2)
        num("--5", 5.0);
        num("+7", 7.0);
    }

    #[test]
    fn percent_postfix() {
        num("50%", 0.5);
        num("100%+1", 2.0);
    }

    #[test]
    fn leading_equals_and_scientific() {
        num("=1+1", 2.0);
        num("1e3", 1000.0);
        num("1.5e-1", 0.15);
    }

    #[test]
    fn divide_by_zero_is_typed_error() {
        assert_eq!(evaluate("1/0"), Value::Error(FormulaError::DivideByZero));
    }

    #[test]
    fn malformed_is_parse_error() {
        assert!(matches!(evaluate("1+"), Value::Error(FormulaError::Parse)));
        assert!(matches!(evaluate("(1+2"), Value::Error(FormulaError::Parse)));
        assert!(matches!(evaluate("1 2"), Value::Error(FormulaError::Parse)));
        assert!(matches!(evaluate("@"), Value::Error(FormulaError::Parse)));
    }

    #[test]
    fn empty_is_blank() {
        assert_eq!(evaluate(""), Value::Blank);
        assert_eq!(evaluate("="), Value::Blank);
        assert_eq!(evaluate("   "), Value::Blank);
    }

    #[test]
    fn error_display_matches_excel() {
        assert_eq!(FormulaError::Na.display(), "#N/A");
        assert_eq!(FormulaError::DivideByZero.display(), "#DIV/0!");
        assert_eq!(FormulaError::Value.display(), "#VALUE!");
    }

    #[test]
    fn cellref_parse_a1() {
        assert_eq!(CellRef::parse("A1"), Some(CellRef { col: 0, row: 0 }));
        assert_eq!(CellRef::parse("B12"), Some(CellRef { col: 1, row: 11 }));
        assert_eq!(CellRef::parse("AA3"), Some(CellRef { col: 26, row: 2 })); // bijective base-26
        assert_eq!(CellRef::parse("A0"), None); // rows are 1-based
        assert_eq!(CellRef::parse("1A"), None);
        assert_eq!(CellRef::parse("A"), None);
        assert_eq!(CellRef::parse(""), None);
        assert_eq!(CellRef::parse("A1B"), None); // trailing junk
    }

    #[test]
    fn cell_refs_resolve_and_coerce() {
        use std::collections::HashMap;
        let grid: HashMap<CellRef, String> = [
            (CellRef { col: 0, row: 0 }, "5".to_string()),   // A1
            (CellRef { col: 1, row: 0 }, "10".to_string()),  // B1
            (CellRef { col: 0, row: 1 }, "abc".to_string()), // A2 (text)
        ]
        .into_iter()
        .collect();
        let r = |c: CellRef| grid.get(&c).cloned();
        assert_eq!(evaluate_with("A1+B1", &r), Value::Number(15.0));
        assert_eq!(evaluate_with("A1*2", &r), Value::Number(10.0));
        assert_eq!(evaluate_with("A1", &r), Value::Number(5.0));
        assert_eq!(evaluate_with("Z9", &r), Value::Blank); // missing cell → blank
        assert_eq!(evaluate_with("A2", &r), Value::Text("abc".to_string()));
        // text in arithmetic → #VALUE
        assert_eq!(evaluate_with("A2+1", &r), Value::Error(FormulaError::Value));
    }
}
