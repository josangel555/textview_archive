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
    /// or a function name like `SUM`.
    Ident(String),
    /// `:` — range separator (`A1:B2`).
    Colon,
    /// `,` — function-argument separator.
    Comma,
    /// Comparison operators: `=`, `<>`, `<`, `<=`, `>`, `>=`.
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    /// A string literal `"..."` (a doubled `""` is an embedded quote).
    Str(String),
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
            ':' => { chars.next(); toks.push(Token::Colon); }
            ',' => { chars.next(); toks.push(Token::Comma); }
            '=' => { chars.next(); toks.push(Token::Eq); }
            '>' => {
                chars.next();
                if matches!(chars.peek(), Some(&'=')) {
                    chars.next();
                    toks.push(Token::Ge);
                } else {
                    toks.push(Token::Gt);
                }
            }
            '<' => {
                chars.next();
                match chars.peek() {
                    Some(&'=') => { chars.next(); toks.push(Token::Le); }
                    Some(&'>') => { chars.next(); toks.push(Token::Ne); }
                    _ => toks.push(Token::Lt),
                }
            }
            '"' => {
                chars.next(); // opening quote
                let mut lit = String::new();
                loop {
                    match chars.next() {
                        Some('"') => {
                            if matches!(chars.peek(), Some(&'"')) {
                                chars.next();
                                lit.push('"'); // doubled "" → embedded quote
                            } else {
                                break;
                            }
                        }
                        Some(ch) => lit.push(ch),
                        None => return Err(FormulaError::Parse), // unterminated string
                    }
                }
                toks.push(Token::Str(lit));
            }
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
    /// A string literal.
    Str(String),
    /// A cell reference (the raw A1-style identifier; parsed at eval time).
    Ref(String),
    /// A cell range `A1:B2` (raw idents; valid only as a function argument).
    Range(String, String),
    /// A function call `NAME(arg, …)`.
    Call(String, Vec<Expr>),
    Neg(Box<Expr>),
    Percent(Box<Expr>),
    Bin(BinOp, Box<Expr>, Box<Expr>),
    /// A comparison `l <op> r` — yields a boolean. Binds looser than `+`/`-`.
    Cmp(CmpOp, Box<Expr>, Box<Expr>),
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum CmpOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
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
        let e = self.compare()?;
        if self.pos != self.toks.len() {
            return Err(FormulaError::Parse); // trailing/unconsumed tokens
        }
        Ok(e)
    }

    // Comparisons bind looser than +/-; non-chaining (Excel doesn't chain them).
    fn compare(&mut self) -> Result<Expr, FormulaError> {
        let left = self.add()?;
        let op = match self.peek() {
            Some(Token::Eq) => CmpOp::Eq,
            Some(Token::Ne) => CmpOp::Ne,
            Some(Token::Lt) => CmpOp::Lt,
            Some(Token::Le) => CmpOp::Le,
            Some(Token::Gt) => CmpOp::Gt,
            Some(Token::Ge) => CmpOp::Ge,
            _ => return Ok(left),
        };
        self.pos += 1;
        let right = self.add()?;
        Ok(Expr::Cmp(op, Box::new(left), Box::new(right)))
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

    // Comma-separated argument list, up to (not consuming) the closing `)`.
    fn arg_list(&mut self) -> Result<Vec<Expr>, FormulaError> {
        let mut args = Vec::new();
        if let Some(Token::RParen) = self.toks.get(self.pos) {
            return Ok(args); // empty: NAME()
        }
        loop {
            args.push(self.compare()?);
            if let Some(Token::Comma) = self.toks.get(self.pos) {
                self.pos += 1;
            } else {
                break;
            }
        }
        Ok(args)
    }

    fn primary(&mut self) -> Result<Expr, FormulaError> {
        match self.toks.get(self.pos).cloned() {
            Some(Token::Number(n)) => {
                self.pos += 1;
                Ok(Expr::Number(n))
            }
            Some(Token::Str(s)) => {
                self.pos += 1;
                Ok(Expr::Str(s))
            }
            Some(Token::Ident(name)) => {
                self.pos += 1;
                match self.toks.get(self.pos) {
                    Some(Token::LParen) => {
                        self.pos += 1;
                        let args = self.arg_list()?;
                        match self.toks.get(self.pos) {
                            Some(Token::RParen) => {
                                self.pos += 1;
                                Ok(Expr::Call(name, args))
                            }
                            _ => Err(FormulaError::Parse),
                        }
                    }
                    Some(Token::Colon) => {
                        self.pos += 1;
                        match self.toks.get(self.pos).cloned() {
                            Some(Token::Ident(end)) => {
                                self.pos += 1;
                                Ok(Expr::Range(name, end))
                            }
                            _ => Err(FormulaError::Parse),
                        }
                    }
                    _ => Ok(Expr::Ref(name)),
                }
            }
            Some(Token::LParen) => {
                self.pos += 1;
                let e = self.compare()?;
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
        Expr::Str(s) => Value::Text(s.clone()),
        Expr::Ref(name) => match CellRef::parse(name) {
            Some(cr) => coerce_cell(resolver(cr)),
            None => Value::Error(FormulaError::Name), // not a valid cell ref
        },
        Expr::Range(_, _) => Value::Error(FormulaError::Value), // bare range invalid in scalar context
        Expr::Call(name, args) => call_fn(name, args, resolver),
        Expr::Cmp(op, l, r) => {
            let lv = eval(l, resolver);
            if let Value::Error(_) = lv {
                return lv;
            }
            let rv = eval(r, resolver);
            if let Value::Error(_) = rv {
                return rv;
            }
            Value::Bool(compare_values(*op, &lv, &rv))
        }
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

/// Evaluate a function call. Unknown name → #NAME?. (Slice 3a: aggregates +
/// logical; text/math/lookup arrive in following slices, ported against the
/// Swift FormulaEngine corpus.)
fn call_fn(name: &str, args: &[Expr], resolver: &dyn Fn(CellRef) -> Option<String>) -> Value {
    let upper = name.to_ascii_uppercase();
    match upper.as_str() {
        "SUM" | "AVERAGE" | "MIN" | "MAX" | "COUNT" | "PRODUCT" => {
            match numeric_values(args, resolver) {
                Ok(nums) => aggregate(&upper, &nums),
                Err(e) => e,
            }
        }
        "IF" => {
            let cond = match args.first() {
                Some(c) => eval(c, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            if let Value::Error(_) = cond {
                return cond;
            }
            if as_bool(&cond) {
                args.get(1).map_or(Value::Error(FormulaError::Value), |t| eval(t, resolver))
            } else {
                args.get(2).map_or(Value::Bool(false), |f| eval(f, resolver))
            }
        }
        "AND" | "OR" => {
            if args.is_empty() {
                return Value::Error(FormulaError::Value);
            }
            let is_and = upper == "AND";
            let mut acc = is_and;
            for arg in args {
                let v = eval(arg, resolver);
                if let Value::Error(_) = v {
                    return v;
                }
                let b = as_bool(&v);
                acc = if is_and { acc && b } else { acc || b };
            }
            Value::Bool(acc)
        }
        "NOT" => {
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            match args.first() {
                Some(a) => {
                    let v = eval(a, resolver);
                    if let Value::Error(_) = v {
                        v
                    } else {
                        Value::Bool(!as_bool(&v))
                    }
                }
                None => Value::Error(FormulaError::Value),
            }
        }
        "UPPER" | "LOWER" | "TRIM" | "LEN" => {
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            let s = match arg_text(args.first(), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            match upper.as_str() {
                "UPPER" => Value::Text(s.to_uppercase()),
                "LOWER" => Value::Text(s.to_lowercase()),
                "TRIM" => Value::Text(s.trim().to_string()),
                "LEN" => Value::Number(s.chars().count() as f64),
                _ => Value::Error(FormulaError::Name),
            }
        }
        "LEFT" | "RIGHT" => {
            if args.is_empty() || args.len() > 2 {
                return Value::Error(FormulaError::Value);
            }
            let s = match arg_text(args.first(), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            let n = if args.len() == 2 {
                match arg_count(args.get(1), resolver) {
                    Ok(n) => n,
                    Err(e) => return e,
                }
            } else {
                1
            };
            let chars: Vec<char> = s.chars().collect();
            let take = n.min(chars.len());
            let out: String = if upper == "LEFT" {
                chars.iter().take(take).collect()
            } else {
                chars.iter().skip(chars.len() - take).collect()
            };
            Value::Text(out)
        }
        "MID" => {
            if args.len() != 3 {
                return Value::Error(FormulaError::Value);
            }
            let s = match arg_text(args.first(), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            let start = match arg_count(args.get(1), resolver) {
                Ok(n) if n >= 1 => n,
                Ok(_) => return Value::Error(FormulaError::Value),
                Err(e) => return e,
            };
            let len = match arg_count(args.get(2), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let chars: Vec<char> = s.chars().collect();
            let out: String = chars.iter().skip(start - 1).take(len).collect();
            Value::Text(out)
        }
        "CONCAT" | "CONCATENATE" => {
            let mut out = String::new();
            for arg in args {
                if let Expr::Range(a, b) = arg {
                    let cells = match expand_range(a, b) {
                        Some(c) => c,
                        None => return Value::Error(FormulaError::Ref),
                    };
                    for cr in cells {
                        out.push_str(&value_text(&coerce_cell(resolver(cr))));
                    }
                } else {
                    let v = eval(arg, resolver);
                    if let Value::Error(_) = v {
                        return v;
                    }
                    out.push_str(&value_text(&v));
                }
            }
            Value::Text(out)
        }
        _ => Value::Error(FormulaError::Name),
    }
}

/// Evaluate an optional arg to a number for a scalar function (missing → #VALUE).
fn arg_num(arg: Option<&Expr>, resolver: &dyn Fn(CellRef) -> Option<String>) -> Result<f64, Value> {
    match arg {
        Some(e) => as_number(eval(e, resolver)),
        None => Err(Value::Error(FormulaError::Value)),
    }
}

/// Evaluate an arg to a non-negative integer count (LEFT/RIGHT/MID lengths).
/// Non-finite or negative → #VALUE.
// Bounds-checked f64→usize: non-finite rejected above; `trunc() as i64` takes the
// integer part toward zero, and `usize::try_from` rejects negatives/overflow → #VALUE.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn arg_count(arg: Option<&Expr>, resolver: &dyn Fn(CellRef) -> Option<String>) -> Result<usize, Value> {
    let x = arg_num(arg, resolver)?;
    if !x.is_finite() {
        return Err(Value::Error(FormulaError::Value));
    }
    usize::try_from(x.trunc() as i64).map_err(|_| Value::Error(FormulaError::Value))
}

/// Evaluate an optional arg to its text form for a scalar function (missing → #VALUE).
fn arg_text(
    arg: Option<&Expr>,
    resolver: &dyn Fn(CellRef) -> Option<String>,
) -> Result<String, Value> {
    match arg {
        Some(e) => {
            let v = eval(e, resolver);
            if let Value::Error(_) = v {
                Err(v)
            } else {
                Ok(value_text(&v))
            }
        }
        None => Err(Value::Error(FormulaError::Value)),
    }
}

/// Numeric aggregate over the flattened values. MIN/MAX of an empty set → 0,
/// AVERAGE of empty → #DIV/0! (Excel semantics).
fn aggregate(name: &str, nums: &[f64]) -> Value {
    match name {
        "SUM" => Value::Number(nums.iter().sum()),
        "PRODUCT" => Value::Number(nums.iter().product()),
        "COUNT" => Value::Number(nums.len() as f64),
        "AVERAGE" => {
            if nums.is_empty() {
                Value::Error(FormulaError::DivideByZero)
            } else {
                Value::Number(nums.iter().sum::<f64>() / nums.len() as f64)
            }
        }
        "MIN" => Value::Number(if nums.is_empty() {
            0.0
        } else {
            nums.iter().copied().fold(f64::INFINITY, f64::min)
        }),
        "MAX" => Value::Number(if nums.is_empty() {
            0.0
        } else {
            nums.iter().copied().fold(f64::NEG_INFINITY, f64::max)
        }),
        _ => Value::Error(FormulaError::Name),
    }
}

/// Flatten function args to numbers: ranges expand to their cells (blank/text
/// skipped), scalars evaluate (numbers/booleans contribute). An error in any
/// scalar arg propagates as `Err`.
fn numeric_values(
    args: &[Expr],
    resolver: &dyn Fn(CellRef) -> Option<String>,
) -> Result<Vec<f64>, Value> {
    let mut nums = Vec::new();
    for arg in args {
        if let Expr::Range(a, b) = arg {
            let cells = expand_range(a, b).ok_or(Value::Error(FormulaError::Ref))?;
            for cr in cells {
                if let Some(n) = numeric_contribution(&coerce_cell(resolver(cr))) {
                    nums.push(n);
                }
            }
        } else {
            let v = eval(arg, resolver);
            if let Value::Error(_) = v {
                return Err(v);
            }
            if let Some(n) = numeric_contribution(&v) {
                nums.push(n);
            }
        }
    }
    Ok(nums)
}

/// A value's numeric contribution to an aggregate: numbers + booleans count;
/// blank and text do NOT (spreadsheet range-aggregate semantics).
fn numeric_contribution(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => Some(*n),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::Blank | Value::Text(_) | Value::Error(_) => None,
    }
}

/// Expand a range `a:b` (raw idents) to its cells in row-major order. `None` if
/// either endpoint is malformed.
fn expand_range(a: &str, b: &str) -> Option<Vec<CellRef>> {
    let start = CellRef::parse(a)?;
    let end = CellRef::parse(b)?;
    let (c0, c1) = (start.col.min(end.col), start.col.max(end.col));
    let (r0, r1) = (start.row.min(end.row), start.row.max(end.row));
    let mut cells = Vec::new();
    for r in r0..=r1 {
        for c in c0..=c1 {
            cells.push(CellRef { col: c, row: r });
        }
    }
    Some(cells)
}

/// Coerce a value to a boolean for IF/AND/OR/NOT: bool as-is, non-zero number →
/// true, blank → false, "true"/numeric text → true, other text/error → false.
fn as_bool(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::Number(n) => *n != 0.0,
        Value::Blank | Value::Error(_) => false,
        Value::Text(s) => {
            s.eq_ignore_ascii_case("true")
                || s.trim().parse::<f64>().is_ok_and(|n| n != 0.0)
        }
    }
}

/// Apply a comparison operator to two already-evaluated, non-error values.
fn compare_values(op: CmpOp, a: &Value, b: &Value) -> bool {
    use std::cmp::Ordering;
    let ord = value_cmp(a, b);
    match op {
        CmpOp::Eq => ord == Ordering::Equal,
        CmpOp::Ne => ord != Ordering::Equal,
        CmpOp::Lt => ord == Ordering::Less,
        CmpOp::Le => ord != Ordering::Greater,
        CmpOp::Gt => ord == Ordering::Greater,
        CmpOp::Ge => ord != Ordering::Less,
    }
}

/// Order two values: numerically when BOTH coerce to numbers (number/bool/blank/
/// numeric-text — blank counts as 0), otherwise case-insensitive text.
fn value_cmp(a: &Value, b: &Value) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    if let (Ok(x), Ok(y)) = (as_number(a.clone()), as_number(b.clone())) {
        x.partial_cmp(&y).unwrap_or(Ordering::Equal)
    } else {
        value_text(a)
            .to_lowercase()
            .cmp(&value_text(b).to_lowercase())
    }
}

/// A value's text form (for text comparison): numbers without a trailing `.0`,
/// booleans as TRUE/FALSE, blank as empty, error as its display code.
fn value_text(v: &Value) -> String {
    match v {
        Value::Number(n) => n.to_string(),
        Value::Text(s) => s.clone(),
        Value::Bool(b) => if *b { "TRUE".to_string() } else { "FALSE".to_string() },
        Value::Blank => String::new(),
        Value::Error(e) => e.display().to_string(),
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

    #[test]
    fn aggregate_functions_over_ranges() {
        use std::collections::HashMap;
        let grid: HashMap<CellRef, String> = [
            (CellRef { col: 0, row: 0 }, "1".to_string()), // A1
            (CellRef { col: 0, row: 1 }, "2".to_string()), // A2
            (CellRef { col: 0, row: 2 }, "3".to_string()), // A3
            (CellRef { col: 0, row: 3 }, "x".to_string()), // A4 (text — skipped)
        ]
        .into_iter()
        .collect();
        let r = |c: CellRef| grid.get(&c).cloned();
        assert_eq!(evaluate_with("SUM(A1:A4)", &r), Value::Number(6.0)); // text skipped
        assert_eq!(evaluate_with("COUNT(A1:A4)", &r), Value::Number(3.0)); // text not counted
        assert_eq!(evaluate_with("AVERAGE(A1:A3)", &r), Value::Number(2.0));
        assert_eq!(evaluate_with("MIN(A1:A3)", &r), Value::Number(1.0));
        assert_eq!(evaluate_with("MAX(A1:A3)", &r), Value::Number(3.0));
        assert_eq!(evaluate_with("PRODUCT(A1:A3)", &r), Value::Number(6.0));
        assert_eq!(evaluate_with("SUM(A1,A2,10)", &r), Value::Number(13.0)); // mixed scalar args
    }

    #[test]
    fn logical_functions_numeric_truthiness() {
        // (comparison operators arrive in slice 3b; here cond is numeric truthiness)
        assert_eq!(evaluate("IF(1, 10, 20)"), Value::Number(10.0));
        assert_eq!(evaluate("IF(0, 10, 20)"), Value::Number(20.0));
        assert_eq!(evaluate("IF(0, 1)"), Value::Bool(false)); // no else → FALSE
        assert_eq!(evaluate("AND(1, 1)"), Value::Bool(true));
        assert_eq!(evaluate("AND(1, 0)"), Value::Bool(false));
        assert_eq!(evaluate("OR(0, 1)"), Value::Bool(true));
        assert_eq!(evaluate("NOT(0)"), Value::Bool(true));
    }

    #[test]
    fn nested_calls_unknown_and_empty() {
        assert_eq!(evaluate("SUM(1, 2, IF(1, 3, 0))"), Value::Number(6.0)); // nested call
        assert!(matches!(evaluate("BOGUS(1)"), Value::Error(FormulaError::Name))); // unknown fn
        assert_eq!(evaluate("SUM()"), Value::Number(0.0)); // empty args
        assert_eq!(evaluate("MIN()"), Value::Number(0.0)); // empty → 0
    }

    #[test]
    fn comparison_operators() {
        assert_eq!(evaluate("1<2"), Value::Bool(true));
        assert_eq!(evaluate("2<=2"), Value::Bool(true));
        assert_eq!(evaluate("3>2"), Value::Bool(true));
        assert_eq!(evaluate("3>=4"), Value::Bool(false));
        assert_eq!(evaluate("2=2"), Value::Bool(true));
        assert_eq!(evaluate("2<>3"), Value::Bool(true));
        assert_eq!(evaluate("1+1=2"), Value::Bool(true)); // comparison binds looser than +
    }

    #[test]
    fn comparisons_with_if_refs_blank_and_text() {
        use std::collections::HashMap;
        let grid: HashMap<CellRef, String> = [
            (CellRef { col: 0, row: 0 }, "7".to_string()),   // A1 = 7
            (CellRef { col: 1, row: 0 }, "abc".to_string()), // B1
            (CellRef { col: 2, row: 0 }, "ABC".to_string()), // C1
        ]
        .into_iter()
        .collect();
        let r = |c: CellRef| grid.get(&c).cloned();
        assert_eq!(evaluate_with("IF(A1>5, 100, 200)", &r), Value::Number(100.0));
        assert_eq!(evaluate_with("IF(A1>10, 100, 200)", &r), Value::Number(200.0));
        assert_eq!(evaluate_with("AND(A1>5, A1<10)", &r), Value::Bool(true));
        assert_eq!(evaluate_with("Z9=0", &r), Value::Bool(true)); // blank coerces to 0
        assert_eq!(evaluate_with("B1=C1", &r), Value::Bool(true)); // text compare is case-insensitive
    }

    #[test]
    fn string_literals_and_text_functions() {
        assert_eq!(evaluate("UPPER(\"abc\")"), Value::Text("ABC".to_string()));
        assert_eq!(evaluate("LOWER(\"ABC\")"), Value::Text("abc".to_string()));
        assert_eq!(evaluate("TRIM(\"  hi  \")"), Value::Text("hi".to_string()));
        assert_eq!(evaluate("LEN(\"hello\")"), Value::Number(5.0));
        assert_eq!(evaluate("LEFT(\"hello\", 2)"), Value::Text("he".to_string()));
        assert_eq!(evaluate("RIGHT(\"hello\", 3)"), Value::Text("llo".to_string()));
        assert_eq!(evaluate("LEFT(\"hello\")"), Value::Text("h".to_string())); // default 1
        assert_eq!(evaluate("MID(\"hello\", 2, 3)"), Value::Text("ell".to_string()));
        assert_eq!(evaluate("CONCAT(\"a\", \"b\", \"c\")"), Value::Text("abc".to_string()));
        // a doubled "" is an embedded quote
        assert_eq!(evaluate("\"a\"\"b\""), Value::Text("a\"b".to_string()));
    }

    #[test]
    fn concat_with_numbers_and_refs() {
        use std::collections::HashMap;
        let grid: HashMap<CellRef, String> =
            [(CellRef { col: 0, row: 0 }, "world".to_string())].into_iter().collect(); // A1
        let r = |c: CellRef| grid.get(&c).cloned();
        assert_eq!(evaluate_with("CONCAT(\"x\", 5)", &r), Value::Text("x5".to_string())); // number → text
        assert_eq!(
            evaluate_with("CONCAT(\"hello \", A1)", &r),
            Value::Text("hello world".to_string())
        );
    }
}
