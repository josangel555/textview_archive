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

fn eval(e: &Expr, resolver: &dyn Fn(CellRef) -> Value) -> Value {
    match e {
        Expr::Number(n) => Value::Number(*n),
        Expr::Str(s) => Value::Text(s.clone()),
        Expr::Ref(name) => match CellRef::parse(name) {
            Some(cr) => resolver(cr),
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
fn call_fn(name: &str, args: &[Expr], resolver: &dyn Fn(CellRef) -> Value) -> Value {
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
                        out.push_str(&value_text(&resolver(cr)));
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
        "ABS" | "INT" | "SQRT" => {
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            let x = match arg_num(args.first(), resolver) {
                Ok(x) => x,
                Err(e) => return e,
            };
            match upper.as_str() {
                "ABS" => Value::Number(x.abs()),
                "INT" => Value::Number(x.floor()), // floor, even for negatives
                "SQRT" => {
                    if x < 0.0 {
                        Value::Error(FormulaError::Num)
                    } else {
                        Value::Number(x.sqrt())
                    }
                }
                _ => Value::Error(FormulaError::Name),
            }
        }
        "ROUND" => {
            if args.is_empty() || args.len() > 2 {
                return Value::Error(FormulaError::Value);
            }
            let x = match arg_num(args.first(), resolver) {
                Ok(x) => x,
                Err(e) => return e,
            };
            let digits = if args.len() == 2 {
                match arg_num(args.get(1), resolver) {
                    Ok(d) => d,
                    Err(e) => return e,
                }
            } else {
                0.0
            };
            let factor = 10f64.powf(digits.trunc()); // powf avoids a float→int cast
            Value::Number((x * factor).round() / factor)
        }
        "MOD" | "POWER" => {
            if args.len() != 2 {
                return Value::Error(FormulaError::Value);
            }
            let a = match arg_num(args.first(), resolver) {
                Ok(x) => x,
                Err(e) => return e,
            };
            let b = match arg_num(args.get(1), resolver) {
                Ok(x) => x,
                Err(e) => return e,
            };
            if upper == "MOD" {
                if b == 0.0 {
                    Value::Error(FormulaError::DivideByZero)
                } else {
                    Value::Number(a - b * (a / b).floor()) // result takes the sign of the divisor
                }
            } else {
                Value::Number(a.powf(b))
            }
        }
        "COUNTIF" => {
            if args.len() != 2 {
                return Value::Error(FormulaError::Value);
            }
            let cells = match arg_cells(args.first()) {
                Some(c) => c,
                None => return Value::Error(FormulaError::Value),
            };
            let crit = match args.get(1) {
                Some(e) => eval(e, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            if let Value::Error(_) = crit {
                return crit;
            }
            let mut count: usize = 0;
            for cr in cells {
                if matches_criterion(&resolver(cr), &crit) {
                    count += 1;
                }
            }
            Value::Number(count as f64)
        }
        "SUMIF" | "AVERAGEIF" => {
            if args.len() != 2 && args.len() != 3 {
                return Value::Error(FormulaError::Value);
            }
            let crit_cells = match arg_cells(args.first()) {
                Some(c) => c,
                None => return Value::Error(FormulaError::Value),
            };
            let crit = match args.get(1) {
                Some(e) => eval(e, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            if let Value::Error(_) = crit {
                return crit;
            }
            let sum_cells = if args.len() == 3 {
                match arg_cells(args.get(2)) {
                    Some(c) => c,
                    None => return Value::Error(FormulaError::Value),
                }
            } else {
                crit_cells.clone()
            };
            let mut total = 0.0;
            let mut matched: usize = 0;
            for (i, cr) in crit_cells.iter().enumerate() {
                if matches_criterion(&resolver(*cr), &crit) {
                    let target = sum_cells.get(i).copied().unwrap_or(*cr);
                    if let Some(n) = numeric_contribution(&resolver(target)) {
                        total += n;
                        matched += 1;
                    }
                }
            }
            if upper == "AVERAGEIF" {
                if matched == 0 {
                    Value::Error(FormulaError::DivideByZero)
                } else {
                    Value::Number(total / matched as f64)
                }
            } else {
                Value::Number(total)
            }
        }
        "ISBLANK" | "ISNUMBER" | "ISTEXT" | "ISNONTEXT" | "ISLOGICAL" | "ISERROR" => {
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            // NB: do NOT propagate errors here — detecting one is the point (ISERROR).
            let v = match args.first() {
                Some(e) => eval(e, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            let b = match upper.as_str() {
                "ISBLANK" => matches!(v, Value::Blank),
                "ISNUMBER" => matches!(v, Value::Number(_)),
                "ISTEXT" => matches!(v, Value::Text(_)),
                "ISNONTEXT" => !matches!(v, Value::Text(_)),
                "ISLOGICAL" => matches!(v, Value::Bool(_)),
                "ISERROR" => matches!(v, Value::Error(_)),
                _ => false,
            };
            Value::Bool(b)
        }
        "MATCH" => {
            use std::cmp::Ordering;
            if args.len() != 2 && args.len() != 3 {
                return Value::Error(FormulaError::Value);
            }
            let target = match args.first() {
                Some(e) => eval(e, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            if let Value::Error(_) = target {
                return target;
            }
            let cells = match arg_cells(args.get(1)) {
                Some(c) => c,
                None => return Value::Error(FormulaError::Value),
            };
            let mt = if args.len() == 3 {
                match arg_num(args.get(2), resolver) {
                    Ok(n) => n,
                    Err(e) => return e,
                }
            } else {
                1.0
            };
            let mut best: Option<usize> = None;
            for (i, cr) in cells.iter().enumerate() {
                let ord = value_cmp(&resolver(*cr), &target);
                if mt == 0.0 {
                    if ord == Ordering::Equal {
                        return Value::Number((i + 1) as f64); // exact
                    }
                } else if mt > 0.0 {
                    // largest value ≤ target, range assumed ascending
                    if ord == Ordering::Greater {
                        break;
                    }
                    best = Some(i + 1);
                } else if ord == Ordering::Less {
                    break; // mt < 0: smallest value ≥ target, range assumed descending
                } else {
                    best = Some(i + 1);
                }
            }
            match best {
                Some(p) => Value::Number(p as f64),
                None => Value::Error(FormulaError::Na),
            }
        }
        "INDEX" => {
            if args.len() != 2 && args.len() != 3 {
                return Value::Error(FormulaError::Value);
            }
            let (start, end) = match arg_range_bounds(args.first()) {
                Some(b) => b,
                None => return Value::Error(FormulaError::Value),
            };
            let nrows = end.row - start.row + 1;
            let ncols = end.col - start.col + 1;
            let p1 = match arg_index1(args.get(1), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let (ri, ci) = if args.len() == 3 {
                let p2 = match arg_index1(args.get(2), resolver) {
                    Ok(n) => n,
                    Err(e) => return e,
                };
                (p1, p2)
            } else if nrows == 1 {
                (1, p1) // single row → the index is the column
            } else {
                (p1, 1) // single column (or default) → the index is the row
            };
            if ri > nrows || ci > ncols {
                return Value::Error(FormulaError::Ref);
            }
            resolver(CellRef {
                col: start.col + ci - 1,
                row: start.row + ri - 1,
            })
        }
        "VLOOKUP" | "HLOOKUP" => {
            use std::cmp::Ordering;
            if args.len() != 3 && args.len() != 4 {
                return Value::Error(FormulaError::Value);
            }
            let target = match args.first() {
                Some(e) => eval(e, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            if let Value::Error(_) = target {
                return target;
            }
            let (start, end) = match arg_range_bounds(args.get(1)) {
                Some(b) => b,
                None => return Value::Error(FormulaError::Value),
            };
            let index = match arg_index1(args.get(2), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            // 4th arg range_lookup: FALSE/0 → exact; omitted/TRUE → approximate.
            let exact = if args.len() == 4 {
                let v = match args.get(3) {
                    Some(e) => eval(e, resolver),
                    None => return Value::Error(FormulaError::Value),
                };
                if let Value::Error(_) = v {
                    return v;
                }
                !as_bool(&v)
            } else {
                false
            };
            let is_v = upper == "VLOOKUP";
            let scan_count = if is_v { end.row - start.row + 1 } else { end.col - start.col + 1 };
            let max_index = if is_v { end.col - start.col + 1 } else { end.row - start.row + 1 };
            if index > max_index {
                return Value::Error(FormulaError::Ref);
            }
            let mut best: Option<u32> = None; // 0-based scan offset of the matching key
            for k in 0..scan_count {
                let key_cell = if is_v {
                    CellRef { col: start.col, row: start.row + k }
                } else {
                    CellRef { col: start.col + k, row: start.row }
                };
                let ord = value_cmp(&resolver(key_cell), &target);
                if exact {
                    if ord == Ordering::Equal {
                        best = Some(k);
                        break;
                    }
                } else {
                    // approximate: largest key ≤ target, table assumed ascending
                    if ord == Ordering::Greater {
                        break;
                    }
                    best = Some(k);
                }
            }
            match best {
                Some(k) => {
                    let result_cell = if is_v {
                        CellRef { col: start.col + index - 1, row: start.row + k }
                    } else {
                        CellRef { col: start.col + k, row: start.row + index - 1 }
                    };
                    resolver(result_cell)
                }
                None => Value::Error(FormulaError::Na),
            }
        }
        "DATE" => {
            if args.len() != 3 {
                return Value::Error(FormulaError::Value);
            }
            let y = match arg_int(args.first(), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let m = match arg_int(args.get(1), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let d = match arg_int(args.get(2), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let total_months = y * 12 + (m - 1); // normalize month overflow
            let ny = total_months.div_euclid(12);
            let nm = total_months.rem_euclid(12) + 1;
            let (fy, fm, fd) = civil_from_days(days_from_civil(ny, nm, 1) + (d - 1));
            Value::Text(format_iso(fy, fm, fd))
        }
        "YEAR" | "MONTH" | "DAY" => {
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            let s = match arg_text(args.first(), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            let (y, m, d) = match parse_iso(&s) {
                Some(t) => t,
                None => return Value::Error(FormulaError::Value),
            };
            let n = match upper.as_str() {
                "YEAR" => y,
                "MONTH" => m,
                "DAY" => d,
                _ => 0,
            };
            Value::Number(n as f64)
        }
        "WEEKDAY" => {
            if args.is_empty() || args.len() > 2 {
                return Value::Error(FormulaError::Value);
            }
            let s = match arg_text(args.first(), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            let (y, m, d) = match parse_iso(&s) {
                Some(t) => t,
                None => return Value::Error(FormulaError::Value),
            };
            let dow_sun0 = (days_from_civil(y, m, d) + 4).rem_euclid(7); // 0=Sun … 6=Sat
            let typ = if args.len() == 2 {
                match arg_int(args.get(1), resolver) {
                    Ok(n) => n,
                    Err(e) => return e,
                }
            } else {
                1
            };
            let wd = if typ == 2 {
                (dow_sun0 + 6).rem_euclid(7) + 1 // Mon=1 … Sun=7
            } else {
                dow_sun0 + 1 // Sun=1 … Sat=7
            };
            Value::Number(wd as f64)
        }
        "DATEDIF" => {
            if args.len() != 3 {
                return Value::Error(FormulaError::Value);
            }
            let s1 = match arg_text(args.first(), resolver) { Ok(s) => s, Err(e) => return e };
            let s2 = match arg_text(args.get(1), resolver) { Ok(s) => s, Err(e) => return e };
            let unit = match arg_text(args.get(2), resolver) { Ok(s) => s, Err(e) => return e };
            let (y1, m1, d1) = match parse_iso(&s1) {
                Some(t) => t,
                None => return Value::Error(FormulaError::Value),
            };
            let (y2, m2, d2) = match parse_iso(&s2) {
                Some(t) => t,
                None => return Value::Error(FormulaError::Value),
            };
            let days1 = days_from_civil(y1, m1, d1);
            let days2 = days_from_civil(y2, m2, d2);
            if days2 < days1 {
                return Value::Error(FormulaError::Num); // end before start
            }
            let n = match unit.to_ascii_uppercase().as_str() {
                "D" => days2 - days1,
                "M" => {
                    let mut mo = (y2 - y1) * 12 + (m2 - m1);
                    if d2 < d1 {
                        mo -= 1;
                    }
                    mo
                }
                "Y" => {
                    let mut yr = y2 - y1;
                    if (m2, d2) < (m1, d1) {
                        yr -= 1;
                    }
                    yr
                }
                _ => return Value::Error(FormulaError::Num),
            };
            Value::Number(n as f64)
        }
        "EDATE" | "EOMONTH" => {
            if args.len() != 2 {
                return Value::Error(FormulaError::Value);
            }
            let s = match arg_text(args.first(), resolver) { Ok(s) => s, Err(e) => return e };
            let months = match arg_int(args.get(1), resolver) { Ok(n) => n, Err(e) => return e };
            let (y, m, d) = match parse_iso(&s) {
                Some(t) => t,
                None => return Value::Error(FormulaError::Value),
            };
            let total = y * 12 + (m - 1) + months;
            let ny = total.div_euclid(12);
            let nm = total.rem_euclid(12) + 1;
            let day = if upper == "EOMONTH" {
                days_in_month(ny, nm) // last day of the shifted month
            } else {
                d.min(days_in_month(ny, nm)) // EDATE: same day, clamped to month length
            };
            let (fy, fm, fd) = civil_from_days(days_from_civil(ny, nm, day));
            Value::Text(format_iso(fy, fm, fd))
        }
        "ROUNDUP" | "ROUNDDOWN" | "TRUNC" => {
            if args.is_empty() || args.len() > 2 {
                return Value::Error(FormulaError::Value);
            }
            let x = match arg_num(args.first(), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let digits = if args.len() == 2 {
                match arg_int(args.get(1), resolver) {
                    Ok(n) => n,
                    Err(e) => return e,
                }
            } else {
                0
            };
            let factor = 10.0_f64.powf(digits as f64);
            let scaled = x * factor;
            // ROUNDUP rounds away from zero; ROUNDDOWN/TRUNC truncate toward zero.
            let r = if upper == "ROUNDUP" { round_away(scaled) } else { scaled.trunc() };
            Value::Number(r / factor)
        }
        "CEILING" | "FLOOR" => {
            if args.is_empty() || args.len() > 2 {
                return Value::Error(FormulaError::Value);
            }
            let x = match arg_num(args.first(), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            let sig = if args.len() == 2 {
                match arg_num(args.get(1), resolver) {
                    Ok(n) => n,
                    Err(e) => return e,
                }
            } else {
                1.0
            };
            if sig == 0.0 {
                return Value::Number(0.0);
            }
            let q = x / sig;
            let rounded = if upper == "CEILING" { q.ceil() } else { q.floor() };
            Value::Number(rounded * sig)
        }
        "SIGN" => {
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            let x = match arg_num(args.first(), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            Value::Number(if x > 0.0 {
                1.0
            } else if x < 0.0 {
                -1.0
            } else {
                0.0
            })
        }
        "EXP" => {
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            let x = match arg_num(args.first(), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            Value::Number(x.exp())
        }
        "LN" | "LOG10" => {
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            let x = match arg_num(args.first(), resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            if x <= 0.0 {
                return Value::Error(FormulaError::Num);
            }
            Value::Number(if upper == "LN" { x.ln() } else { x.log10() })
        }
        "EXACT" => {
            if args.len() != 2 {
                return Value::Error(FormulaError::Value);
            }
            let a = match arg_text(args.first(), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            let b = match arg_text(args.get(1), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            Value::Bool(a == b) // case-sensitive, unlike =
        }
        "REPT" => {
            if args.len() != 2 {
                return Value::Error(FormulaError::Value);
            }
            let s = match arg_text(args.first(), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            let n = match arg_num(args.get(1), resolver) {
                Ok(d) => d,
                Err(e) => return e,
            };
            if n < 0.0 {
                return Value::Error(FormulaError::Value);
            }
            let count = trunc_to_count(n);
            if s.chars().count().saturating_mul(count) > 32767 {
                return Value::Error(FormulaError::Value); // Excel REPT cap; guards memory
            }
            Value::Text(s.repeat(count))
        }
        "SUBSTITUTE" => {
            if args.len() != 3 && args.len() != 4 {
                return Value::Error(FormulaError::Value);
            }
            let text = match arg_text(args.first(), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            let old_s = match arg_text(args.get(1), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            let new_s = match arg_text(args.get(2), resolver) {
                Ok(s) => s,
                Err(e) => return e,
            };
            if old_s.is_empty() {
                return Value::Text(text);
            }
            if args.len() == 4 {
                let nth = match arg_num(args.get(3), resolver) {
                    Ok(d) => d,
                    Err(e) => return e,
                };
                if nth < 1.0 {
                    return Value::Error(FormulaError::Value);
                }
                return Value::Text(substitute_nth(&text, &old_s, &new_s, trunc_to_count(nth)));
            }
            Value::Text(text.replace(&old_s, &new_s))
        }
        "IFERROR" => {
            if args.len() != 2 {
                return Value::Error(FormulaError::Value);
            }
            let v = match args.first() {
                Some(a) => eval(a, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            if let Value::Error(_) = v {
                args.get(1).map_or(Value::Error(FormulaError::Value), |b| eval(b, resolver))
            } else {
                v
            }
        }
        "IFS" => {
            // IFS(cond1, val1, …) → val for the first true cond; none → #N/A.
            if args.len() < 2 || !args.len().is_multiple_of(2) {
                return Value::Error(FormulaError::Value);
            }
            let mut i = 0;
            while i < args.len() {
                let cond = match args.get(i) {
                    Some(c) => eval(c, resolver),
                    None => return Value::Error(FormulaError::Value),
                };
                if let Value::Error(_) = cond {
                    return cond;
                }
                if as_bool(&cond) {
                    return args
                        .get(i + 1)
                        .map_or(Value::Error(FormulaError::Value), |v| eval(v, resolver));
                }
                i += 2;
            }
            Value::Error(FormulaError::Na)
        }
        "SWITCH" => {
            // SWITCH(expr, case1, val1, …, [default]) → first matching case's val;
            // a trailing odd arg is the default; no match + no default → #N/A.
            if args.len() < 3 {
                return Value::Error(FormulaError::Value);
            }
            let subject = match args.first() {
                Some(s) => eval(s, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            if let Value::Error(_) = subject {
                return subject;
            }
            let mut i = 1;
            while i + 1 < args.len() {
                let c = match args.get(i) {
                    Some(c) => eval(c, resolver),
                    None => return Value::Error(FormulaError::Value),
                };
                if let Value::Error(_) = c {
                    return c;
                }
                if value_cmp(&subject, &c) == std::cmp::Ordering::Equal {
                    return args
                        .get(i + 1)
                        .map_or(Value::Error(FormulaError::Value), |v| eval(v, resolver));
                }
                i += 2;
            }
            if i < args.len() {
                // trailing default
                return args.get(i).map_or(Value::Error(FormulaError::Na), |d| eval(d, resolver));
            }
            Value::Error(FormulaError::Na)
        }
        "COUNTA" => match non_blank_count(args, resolver) {
            Ok(n) => Value::Number(n as f64),
            Err(e) => e,
        },
        "MEDIAN" => {
            let mut nums = match numeric_values(args, resolver) {
                Ok(n) => n,
                Err(e) => return e,
            };
            if nums.is_empty() {
                return Value::Error(FormulaError::Num);
            }
            nums.sort_by(f64::total_cmp);
            let mid = nums.len() / 2;
            let median = if nums.len().is_multiple_of(2) {
                // even count → mean of the two middle values
                (nums.get(mid - 1).copied().unwrap_or(0.0) + nums.get(mid).copied().unwrap_or(0.0))
                    / 2.0
            } else {
                nums.get(mid).copied().unwrap_or(0.0)
            };
            Value::Number(median)
        }
        "ISNA" | "ISERR" => {
            // ISNA → #N/A only; ISERR → any error EXCEPT #N/A. Does not propagate.
            if args.len() != 1 {
                return Value::Error(FormulaError::Value);
            }
            let v = match args.first() {
                Some(a) => eval(a, resolver),
                None => return Value::Error(FormulaError::Value),
            };
            if let Value::Error(e) = v {
                let is_na = e == FormulaError::Na;
                Value::Bool(if upper == "ISNA" { is_na } else { !is_na })
            } else {
                Value::Bool(false)
            }
        }
        _ => Value::Error(FormulaError::Name),
    }
}

/// Evaluate an optional arg to a number for a scalar function (missing → #VALUE).
fn arg_num(arg: Option<&Expr>, resolver: &dyn Fn(CellRef) -> Value) -> Result<f64, Value> {
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
fn arg_count(arg: Option<&Expr>, resolver: &dyn Fn(CellRef) -> Value) -> Result<usize, Value> {
    let x = arg_num(arg, resolver)?;
    if !x.is_finite() {
        return Err(Value::Error(FormulaError::Value));
    }
    usize::try_from(x.trunc() as i64).map_err(|_| Value::Error(FormulaError::Value))
}

/// Evaluate an optional arg to its text form for a scalar function (missing → #VALUE).
fn arg_text(
    arg: Option<&Expr>,
    resolver: &dyn Fn(CellRef) -> Value,
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
    resolver: &dyn Fn(CellRef) -> Value,
) -> Result<Vec<f64>, Value> {
    let mut nums = Vec::new();
    for arg in args {
        if let Expr::Range(a, b) = arg {
            let cells = expand_range(a, b).ok_or(Value::Error(FormulaError::Ref))?;
            for cr in cells {
                if let Some(n) = numeric_contribution(&resolver(cr)) {
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

/// Count of non-blank values across `args` (COUNTA): every range cell or scalar
/// arg that is not blank counts (text/number/bool all do). A scalar arg that
/// evaluates to an error propagates.
fn non_blank_count(
    args: &[Expr],
    resolver: &dyn Fn(CellRef) -> Value,
) -> Result<usize, Value> {
    let mut n = 0;
    for arg in args {
        if let Expr::Range(a, b) = arg {
            let cells = expand_range(a, b).ok_or(Value::Error(FormulaError::Ref))?;
            for cr in cells {
                if !matches!(resolver(cr), Value::Blank) {
                    n += 1;
                }
            }
        } else {
            let v = eval(arg, resolver);
            if let Value::Error(_) = v {
                return Err(v);
            }
            if !matches!(v, Value::Blank) {
                n += 1;
            }
        }
    }
    Ok(n)
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
    cmp_apply(op, value_cmp(a, b))
}

/// Resolve a comparison operator against an ordering result.
fn cmp_apply(op: CmpOp, ord: std::cmp::Ordering) -> bool {
    use std::cmp::Ordering;
    match op {
        CmpOp::Eq => ord == Ordering::Equal,
        CmpOp::Ne => ord != Ordering::Equal,
        CmpOp::Lt => ord == Ordering::Less,
        CmpOp::Le => ord != Ordering::Greater,
        CmpOp::Gt => ord == Ordering::Greater,
        CmpOp::Ge => ord != Ordering::Less,
    }
}

/// Parse a COUNTIF/SUMIF criterion's leading comparison operator (default `=`).
fn parse_criterion_op(s: &str) -> (CmpOp, &str) {
    for (prefix, op) in [
        (">=", CmpOp::Ge),
        ("<=", CmpOp::Le),
        ("<>", CmpOp::Ne),
        (">", CmpOp::Gt),
        ("<", CmpOp::Lt),
        ("=", CmpOp::Eq),
    ] {
        if let Some(rest) = s.strip_prefix(prefix) {
            return (op, rest);
        }
    }
    (CmpOp::Eq, s)
}

/// Does a cell value match a COUNTIF-style criterion? Numeric compare when the
/// needle parses as a number and the cell coerces to one; else case-insensitive
/// text (with operator ordering). A blank cell matches only an empty `=` test.
/// Excel-style glob match: `*` = any run (incl. empty), `?` = any one char, `~`
/// escapes the next `*`/`?`/`~` to a literal (a lone `~` is a literal tilde).
/// Plain text with no special chars reduces to exact match. Both inputs are
/// pre-lowercased by the caller (criteria are case-insensitive). Iterative
/// two-pointer with star backtracking — bounded stack, `.get()` only (no indexing).
fn glob_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let mut pi = 0usize;
    let mut ti = 0usize;
    let mut star: Option<(usize, usize)> = None; // (pattern pos after '*', text pos)
    while ti < t.len() {
        match p.get(pi).copied() {
            Some('*') => {
                pi += 1;
                star = Some((pi, ti));
            }
            Some('?') => {
                pi += 1;
                ti += 1;
            }
            other => {
                // A literal token: a `~`-escaped char or a plain char.
                let (lit, adv) = match other {
                    Some('~') => match p.get(pi + 1).copied() {
                        Some(esc @ ('*' | '?' | '~')) => (Some(esc), 2),
                        _ => (Some('~'), 1), // lone '~' is a literal tilde
                    },
                    Some(c) => (Some(c), 1),
                    None => (None, 0),
                };
                if lit.is_some() && lit == t.get(ti).copied() {
                    pi += adv;
                    ti += 1;
                } else if let Some((sp, st)) = star {
                    pi = sp;
                    ti = st + 1;
                    star = Some((sp, st + 1));
                } else {
                    return false;
                }
            }
        }
    }
    while p.get(pi).copied() == Some('*') {
        pi += 1;
    }
    pi == p.len()
}

fn matches_criterion(cell: &Value, crit: &Value) -> bool {
    let cs = value_text(crit);
    let (op, rest) = parse_criterion_op(&cs);
    let needle = rest.trim();
    if matches!(cell, Value::Blank) {
        return op == CmpOp::Eq && needle.is_empty();
    }
    if let (Ok(rn), Ok(cn)) = (needle.parse::<f64>(), as_number(cell.clone())) {
        return cmp_apply(op, cn.partial_cmp(&rn).unwrap_or(std::cmp::Ordering::Equal));
    }
    // Wildcard text match (Excel `*` / `?`, `~`-escape) for `=` / `<>` criteria;
    // other operators fall through to ordering comparison.
    if matches!(op, CmpOp::Eq | CmpOp::Ne) {
        // Exact / `<>` text criteria go through the glob matcher (plain text with no
        // wildcards is just exact match; `*` `?` glob, `~` escapes).
        let matched = glob_match(&needle.to_lowercase(), &value_text(cell).to_lowercase());
        return if op == CmpOp::Eq { matched } else { !matched };
    }
    let ord = value_text(cell).to_lowercase().cmp(&needle.to_lowercase());
    cmp_apply(op, ord)
}

/// The cells a COUNTIF/SUMIF range/ref argument denotes (`None` if not a range/ref).
fn arg_cells(arg: Option<&Expr>) -> Option<Vec<CellRef>> {
    match arg {
        Some(Expr::Range(a, b)) => expand_range(a, b),
        Some(Expr::Ref(name)) => CellRef::parse(name).map(|cr| vec![cr]),
        _ => None,
    }
}

/// The normalized (top-left, bottom-right) bounds of a range/ref argument.
fn arg_range_bounds(arg: Option<&Expr>) -> Option<(CellRef, CellRef)> {
    match arg {
        Some(Expr::Range(a, b)) => {
            let s = CellRef::parse(a)?;
            let e = CellRef::parse(b)?;
            Some((
                CellRef { col: s.col.min(e.col), row: s.row.min(e.row) },
                CellRef { col: s.col.max(e.col), row: s.row.max(e.row) },
            ))
        }
        Some(Expr::Ref(name)) => CellRef::parse(name).map(|c| (c, c)),
        _ => None,
    }
}

/// Evaluate an arg to a 1-based positive index (INDEX/VLOOKUP positions). `< 1`
/// or non-integer-convertible → #REF. Checked conversion (no truncating cast).
fn arg_index1(arg: Option<&Expr>, resolver: &dyn Fn(CellRef) -> Value) -> Result<u32, Value> {
    let n = arg_count(arg, resolver)?; // usize ≥ 0, bounds-checked
    if n < 1 {
        return Err(Value::Error(FormulaError::Ref));
    }
    u32::try_from(n).map_err(|_| Value::Error(FormulaError::Ref))
}

/// Evaluate an arg to a (possibly negative) integer (date components, month shifts).
// Bounds-checked f64→i64: non-finite rejected; `trunc()` takes the integer part.
#[allow(clippy::cast_possible_truncation)]
fn arg_int(arg: Option<&Expr>, resolver: &dyn Fn(CellRef) -> Value) -> Result<i64, Value> {
    let x = arg_num(arg, resolver)?;
    if !x.is_finite() {
        return Err(Value::Error(FormulaError::Value));
    }
    Ok(x.trunc() as i64)
}

// MARK: - Civil-date math (proleptic Gregorian; Howard Hinnant's algorithms, all
// i64 so no narrowing casts). Dates are ISO "YYYY-MM-DD" text, matching the Swift
// engine's model. Days are counted from 1970-01-01.

/// Days since 1970-01-01 for a civil date. `m` must be in 1..=12 (callers
/// normalize month overflow first); day arithmetic is done in day-offsets.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400; // [0, 399]
    let mp = if m > 2 { m - 3 } else { m + 9 }; // [0, 11]
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe - 719_468
}

/// Inverse of `days_from_civil`: a day count → (year, month, day). Normalizes.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Parse a strict ISO "YYYY-MM-DD" (round-trip validated, so 2024-02-30 → None).
fn parse_iso(s: &str) -> Option<(i64, i64, i64)> {
    let mut parts = s.trim().split('-');
    let y: i64 = parts.next()?.parse().ok()?;
    let m: i64 = parts.next()?.parse().ok()?;
    let d: i64 = parts.next()?.parse().ok()?;
    if parts.next().is_some() || !(1..=12).contains(&m) || d < 1 {
        return None;
    }
    let round = civil_from_days(days_from_civil(y, m, d));
    if round == (y, m, d) {
        Some((y, m, d))
    } else {
        None
    }
}

fn format_iso(y: i64, m: i64, d: i64) -> String {
    format!("{y:04}-{m:02}-{d:02}")
}

/// Number of days in month `m` of year `y` (`m` 1..=12).
fn days_in_month(y: i64, m: i64) -> i64 {
    let next = y * 12 + (m - 1) + 1;
    days_from_civil(next.div_euclid(12), next.rem_euclid(12) + 1, 1) - days_from_civil(y, m, 1)
}

/// Round away from zero (Excel ROUNDUP / Swift `.awayFromZero`): magnitude up.
fn round_away(x: f64) -> f64 {
    if x >= 0.0 {
        x.ceil()
    } else {
        x.floor()
    }
}

/// Truncate a finite, non-negative count to `usize` (Excel `Int()`; the caller
/// range-guards, and the f64→usize cast saturates on overflow).
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn trunc_to_count(n: f64) -> usize {
    n.trunc() as usize
}

/// Replace the `nth` (1-based) occurrence of `old` in `text` with `new`; all
/// other occurrences are left intact (Excel SUBSTITUTE's instance form).
fn substitute_nth(text: &str, old: &str, new: &str, nth: usize) -> String {
    if nth == 0 || old.is_empty() {
        return text.to_string();
    }
    let mut count = 0usize;
    let mut result = String::new();
    let mut rest = text;
    while let Some(pos) = rest.find(old) {
        count += 1;
        let before = rest.get(..pos).unwrap_or("");
        let end = pos + old.len();
        let after = rest.get(end..).unwrap_or("");
        if count == nth {
            result.push_str(before);
            result.push_str(new);
            result.push_str(after);
            return result;
        }
        result.push_str(before);
        result.push_str(rest.get(pos..end).unwrap_or(""));
        rest = after;
    }
    result.push_str(rest);
    result
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

    /// The A1-style string for this cell (`A1`, `AA10`) — inverse of [`Self::parse`].
    #[must_use]
    pub fn a1(&self) -> String {
        let mut col = self.col + 1; // 1-based for bijective base-26
        let mut letters = Vec::new();
        while col > 0 {
            let rem = (col - 1) % 26; // 0..=25
            letters.push(char::from(b'A' + u8::try_from(rem).unwrap_or(0)));
            col = (col - 1) / 26;
        }
        letters.reverse();
        let body: String = letters.into_iter().collect();
        let row = self.row + 1;
        format!("{body}{row}")
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
    // The public API takes a raw-text resolver; compose `coerce_cell` once so the
    // internal evaluator resolves refs to `Value` (lets recalc resolve a formula
    // cell to its computed value — bool/error can't round-trip as text).
    let value_resolver = |cr: CellRef| coerce_cell(resolver(cr));
    match p.parse() {
        Ok(expr) => eval(&expr, &value_resolver),
        Err(e) => Value::Error(e),
    }
}

/// Max dependency-chain depth `recalc` follows before declaring a cycle —
/// stack-safety for pathological chains (the `visiting` set already catches true
/// cycles; this bounds non-cyclic chains deeper than any realistic sheet).
const MAX_RECALC_DEPTH: usize = 1000;

/// Whether a raw cell value is a formula (its trimmed text starts with `=`).
fn is_formula(raw: &str) -> bool {
    raw.trim_start().starts_with('=')
}

/// Recalculate a grid: given every cell as raw text (A1 → raw), compute the
/// `Value` of each FORMULA cell, resolving references to other cells' COMPUTED
/// values in dependency order (so a formula referencing another formula cell sees
/// its result, not its raw text). Returns A1 → `Value` for the formula cells only.
/// A reference cycle yields `#CYCLE` for the cells on it (matching the Swift engine).
#[must_use]
pub fn recalc(
    cells: &std::collections::HashMap<String, String>,
) -> std::collections::HashMap<String, Value> {
    let rc = Recalc {
        cells,
        cache: std::cell::RefCell::new(std::collections::HashMap::new()),
        visiting: std::cell::RefCell::new(std::collections::HashSet::new()),
    };
    let mut out = std::collections::HashMap::new();
    for (a1, raw) in cells {
        if is_formula(raw) {
            out.insert(a1.clone(), rc.resolve(a1, 0));
        }
    }
    out
}

/// Recalc working state: the raw grid plus a memo cache and the in-progress
/// `visiting` set for cycle detection. `RefCell` so the eval resolver closure can
/// borrow `&self` while recursively resolving referenced cells.
struct Recalc<'a> {
    cells: &'a std::collections::HashMap<String, String>,
    cache: std::cell::RefCell<std::collections::HashMap<String, Value>>,
    visiting: std::cell::RefCell<std::collections::HashSet<String>>,
}

impl Recalc<'_> {
    /// The computed `Value` of the cell at A1 address `a1`.
    fn resolve(&self, a1: &str, depth: usize) -> Value {
        if let Some(v) = self.cache.borrow().get(a1) {
            return v.clone();
        }
        let raw = match self.cells.get(a1) {
            Some(r) => r,
            None => return Value::Blank,
        };
        if !is_formula(raw) {
            return coerce_cell(Some(raw.clone()));
        }
        if depth > MAX_RECALC_DEPTH || self.visiting.borrow().contains(a1) {
            return Value::Error(FormulaError::Cycle);
        }
        self.visiting.borrow_mut().insert(a1.to_string());
        let trimmed = raw.trim();
        let body = trimmed.strip_prefix('=').unwrap_or(trimmed);
        let value = match tokenize(body) {
            Ok(toks) if toks.is_empty() => Value::Blank,
            Ok(toks) => {
                let mut p = Parser { toks, pos: 0 };
                match p.parse() {
                    Ok(expr) => eval(&expr, &|cr| self.resolve(&cr.a1(), depth + 1)),
                    Err(e) => Value::Error(e),
                }
            }
            Err(e) => Value::Error(e),
        };
        self.visiting.borrow_mut().remove(a1);
        self.cache.borrow_mut().insert(a1.to_string(), value.clone());
        value
    }
}

// MARK: - FFI / dispatch (stateless snapshot evaluation — the spike's first cut)

/// A batch evaluation request: formulas + a cell-grid snapshot (A1 → raw text).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormulaRequest {
    /// The formulas to evaluate (each may carry a leading `=`).
    pub formulas: Vec<String>,
    /// Snapshot of the referenced cells, keyed by A1 address. A missing key is blank.
    #[serde(default)]
    pub cells: std::collections::HashMap<String, String>,
}

/// The evaluated values, one per input formula (same order).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormulaResponse {
    /// One value per input formula.
    pub values: Vec<Value>,
}

/// Dispatch/FFI entry (`Method::FormulaEvaluate`): decode the request frame,
/// evaluate each formula against the snapshot, encode the response frame.
/// Stateless — the grid snapshot rides the request (see the spike doc); a stateful
/// session handle is the later recalc-phase optimization.
///
/// # Errors
/// [`crate::wire::WireFault`] on a malformed/oversized frame.
pub fn evaluate_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: FormulaRequest = crate::wire::decode_frame(req_frame)?;
    let cells = req.cells;
    let resolver = |cr: CellRef| cells.get(&cr.a1()).cloned();
    let values: Vec<Value> = req.formulas.iter().map(|f| evaluate_with(f, &resolver)).collect();
    crate::wire::encode_frame(&FormulaResponse { values })
}

/// A whole-grid recalc request: every cell as raw text (A1 → raw).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecalcRequest {
    /// The full grid, A1 address → raw cell text (data + formula cells).
    pub cells: std::collections::HashMap<String, String>,
}

/// The computed value of each FORMULA cell (A1 → value); data cells are omitted.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecalcResponse {
    /// A1 address → computed `Value`, for formula cells only.
    pub values: std::collections::HashMap<String, Value>,
}

/// Dispatch/FFI entry (`Method::FormulaRecalc`): decode the grid, recalc every
/// formula cell in dependency order (references resolve to computed values; cycles
/// → `#CYCLE`), encode the result map.
///
/// # Errors
/// [`crate::wire::WireFault`] on a malformed/oversized frame.
pub fn recalc_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: RecalcRequest = crate::wire::decode_frame(req_frame)?;
    let values = recalc(&req.cells);
    crate::wire::encode_frame(&RecalcResponse { values })
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

    #[test]
    fn math_functions() {
        assert_eq!(evaluate("ABS(-3)"), Value::Number(3.0));
        assert_eq!(evaluate("INT(2.9)"), Value::Number(2.0));
        assert_eq!(evaluate("INT(-1.5)"), Value::Number(-2.0)); // floor, not truncate
        assert_eq!(evaluate("SQRT(9)"), Value::Number(3.0));
        assert!(matches!(evaluate("SQRT(-1)"), Value::Error(FormulaError::Num)));
        assert_eq!(evaluate("ROUND(1.23456, 2)"), Value::Number(1.23)); // avoid a π-ish literal (clippy::approx_constant)
        assert_eq!(evaluate("ROUND(2.5, 0)"), Value::Number(3.0)); // half away from zero
        assert_eq!(evaluate("MOD(7, 3)"), Value::Number(1.0));
        assert_eq!(evaluate("MOD(-1, 3)"), Value::Number(2.0)); // result takes divisor's sign
        assert!(matches!(evaluate("MOD(1, 0)"), Value::Error(FormulaError::DivideByZero)));
        assert_eq!(evaluate("POWER(2, 10)"), Value::Number(1024.0));
    }

    #[test]
    fn conditional_aggregates() {
        use std::collections::HashMap;
        let grid: HashMap<CellRef, String> = [
            (CellRef { col: 0, row: 0 }, "5".to_string()),  // A1
            (CellRef { col: 0, row: 1 }, "10".to_string()), // A2
            (CellRef { col: 0, row: 2 }, "15".to_string()), // A3
            (CellRef { col: 1, row: 0 }, "1".to_string()),  // B1
            (CellRef { col: 1, row: 1 }, "2".to_string()),  // B2
            (CellRef { col: 1, row: 2 }, "3".to_string()),  // B3
        ]
        .into_iter()
        .collect();
        let r = |c: CellRef| grid.get(&c).cloned();
        assert_eq!(evaluate_with("COUNTIF(A1:A3, \">5\")", &r), Value::Number(2.0)); // 10, 15
        assert_eq!(evaluate_with("COUNTIF(A1:A3, 5)", &r), Value::Number(1.0)); // numeric criterion
        assert_eq!(evaluate_with("COUNTIF(A1:A3, \">=5\")", &r), Value::Number(3.0));
        assert_eq!(evaluate_with("SUMIF(A1:A3, \">5\")", &r), Value::Number(25.0)); // 10 + 15
        assert_eq!(evaluate_with("SUMIF(A1:A3, \">5\", B1:B3)", &r), Value::Number(5.0)); // B2 + B3
        assert_eq!(evaluate_with("AVERAGEIF(A1:A3, \">5\")", &r), Value::Number(12.5));
        assert!(matches!(
            evaluate_with("AVERAGEIF(A1:A3, \">100\")", &r),
            Value::Error(FormulaError::DivideByZero)
        ));
    }

    #[test]
    fn is_predicates() {
        let nr = |_: CellRef| None;
        assert_eq!(evaluate("ISNUMBER(5)"), Value::Bool(true));
        assert_eq!(evaluate("ISNUMBER(\"x\")"), Value::Bool(false));
        assert_eq!(evaluate("ISTEXT(\"x\")"), Value::Bool(true));
        assert_eq!(evaluate("ISNONTEXT(5)"), Value::Bool(true));
        assert_eq!(evaluate("ISLOGICAL(1>0)"), Value::Bool(true));
        assert_eq!(evaluate("ISERROR(1/0)"), Value::Bool(true)); // detects, does not propagate
        assert_eq!(evaluate("ISERROR(5)"), Value::Bool(false));
        assert_eq!(evaluate_with("ISBLANK(Z9)", &nr), Value::Bool(true)); // missing cell → blank
    }

    #[test]
    fn match_and_index() {
        use std::collections::HashMap;
        let grid: HashMap<CellRef, String> = [
            (CellRef { col: 0, row: 0 }, "10".to_string()), // A1
            (CellRef { col: 0, row: 1 }, "20".to_string()), // A2
            (CellRef { col: 0, row: 2 }, "30".to_string()), // A3
            (CellRef { col: 1, row: 0 }, "x".to_string()),  // B1
            (CellRef { col: 1, row: 1 }, "y".to_string()),  // B2
            (CellRef { col: 1, row: 2 }, "z".to_string()),  // B3
        ]
        .into_iter()
        .collect();
        let r = |c: CellRef| grid.get(&c).cloned();
        assert_eq!(evaluate_with("MATCH(20, A1:A3, 0)", &r), Value::Number(2.0)); // exact
        assert_eq!(evaluate_with("MATCH(25, A1:A3, 1)", &r), Value::Number(2.0)); // largest ≤ 25
        assert!(matches!(
            evaluate_with("MATCH(99, A1:A3, 0)", &r),
            Value::Error(FormulaError::Na)
        ));
        assert_eq!(evaluate_with("INDEX(A1:A3, 2)", &r), Value::Number(20.0)); // 1-D
        assert_eq!(evaluate_with("INDEX(A1:B3, 3, 2)", &r), Value::Text("z".to_string())); // 2-D
        assert!(matches!(
            evaluate_with("INDEX(A1:A3, 9)", &r),
            Value::Error(FormulaError::Ref)
        ));
        // INDEX + MATCH combo
        assert_eq!(
            evaluate_with("INDEX(B1:B3, MATCH(30, A1:A3, 0))", &r),
            Value::Text("z".to_string())
        );
    }

    #[test]
    fn vlookup_hlookup() {
        use std::collections::HashMap;
        // VLOOKUP table A1:B3 — 10→"ten", 20→"twenty", 30→"thirty"
        let v: HashMap<CellRef, String> = [
            (CellRef { col: 0, row: 0 }, "10".to_string()),
            (CellRef { col: 1, row: 0 }, "ten".to_string()),
            (CellRef { col: 0, row: 1 }, "20".to_string()),
            (CellRef { col: 1, row: 1 }, "twenty".to_string()),
            (CellRef { col: 0, row: 2 }, "30".to_string()),
            (CellRef { col: 1, row: 2 }, "thirty".to_string()),
        ]
        .into_iter()
        .collect();
        let r = |c: CellRef| v.get(&c).cloned();
        assert_eq!(evaluate_with("VLOOKUP(20, A1:B3, 2, 0)", &r), Value::Text("twenty".to_string())); // exact
        assert_eq!(evaluate_with("VLOOKUP(25, A1:B3, 2)", &r), Value::Text("twenty".to_string())); // approx → 20's row
        assert!(matches!(
            evaluate_with("VLOOKUP(99, A1:B3, 2, 0)", &r),
            Value::Error(FormulaError::Na)
        ));
        assert!(matches!(
            evaluate_with("VLOOKUP(20, A1:B3, 9, 0)", &r),
            Value::Error(FormulaError::Ref)
        ));

        // HLOOKUP table A1:C2 — row1 = 1,2,3 ; row2 = a,b,c
        let h: HashMap<CellRef, String> = [
            (CellRef { col: 0, row: 0 }, "1".to_string()),
            (CellRef { col: 1, row: 0 }, "2".to_string()),
            (CellRef { col: 2, row: 0 }, "3".to_string()),
            (CellRef { col: 0, row: 1 }, "a".to_string()),
            (CellRef { col: 1, row: 1 }, "b".to_string()),
            (CellRef { col: 2, row: 1 }, "c".to_string()),
        ]
        .into_iter()
        .collect();
        let hr = |c: CellRef| h.get(&c).cloned();
        assert_eq!(evaluate_with("HLOOKUP(2, A1:C2, 2, 0)", &hr), Value::Text("b".to_string()));
    }

    #[test]
    fn date_functions() {
        assert_eq!(evaluate("DATE(2024, 3, 15)"), Value::Text("2024-03-15".to_string()));
        assert_eq!(evaluate("DATE(2024, 13, 1)"), Value::Text("2025-01-01".to_string())); // month overflow
        assert_eq!(evaluate("DATE(2024, 1, 32)"), Value::Text("2024-02-01".to_string())); // day overflow
        assert_eq!(evaluate("YEAR(\"2024-03-15\")"), Value::Number(2024.0));
        assert_eq!(evaluate("MONTH(\"2024-03-15\")"), Value::Number(3.0));
        assert_eq!(evaluate("DAY(\"2024-03-15\")"), Value::Number(15.0));
        assert!(matches!(evaluate("YEAR(\"2024-02-30\")"), Value::Error(FormulaError::Value))); // impossible date
        // 2024-03-15 is a Friday: type 1 (Sun=1) → 6; type 2 (Mon=1) → 5
        assert_eq!(evaluate("WEEKDAY(\"2024-03-15\")"), Value::Number(6.0));
        assert_eq!(evaluate("WEEKDAY(\"2024-03-15\", 2)"), Value::Number(5.0));
        assert_eq!(evaluate("YEAR(DATE(1999, 12, 31))"), Value::Number(1999.0)); // round-trip
    }

    #[test]
    fn date_arithmetic() {
        assert_eq!(evaluate("DATEDIF(\"2024-01-01\", \"2024-01-31\", \"D\")"), Value::Number(30.0));
        assert_eq!(evaluate("DATEDIF(\"2024-01-15\", \"2024-03-20\", \"M\")"), Value::Number(2.0)); // complete months
        assert_eq!(evaluate("DATEDIF(\"2020-06-01\", \"2024-05-31\", \"Y\")"), Value::Number(3.0)); // not yet 4 full years
        assert!(matches!(
            evaluate("DATEDIF(\"2024-05-01\", \"2024-01-01\", \"D\")"),
            Value::Error(FormulaError::Num)
        )); // end before start
        assert_eq!(evaluate("EDATE(\"2024-01-31\", 1)"), Value::Text("2024-02-29".to_string())); // clamp to leap Feb
        assert_eq!(evaluate("EDATE(\"2024-03-15\", -2)"), Value::Text("2024-01-15".to_string())); // negative shift
        assert_eq!(evaluate("EOMONTH(\"2024-01-15\", 0)"), Value::Text("2024-01-31".to_string()));
        assert_eq!(evaluate("EOMONTH(\"2024-01-15\", 1)"), Value::Text("2024-02-29".to_string()));
        assert_eq!(evaluate("EOMONTH(\"2024-12-10\", 1)"), Value::Text("2025-01-31".to_string())); // year roll
    }

    #[test]
    fn cellref_a1_roundtrip() {
        assert_eq!(CellRef { col: 0, row: 0 }.a1(), "A1");
        assert_eq!(CellRef { col: 1, row: 11 }.a1(), "B12");
        assert_eq!(CellRef { col: 26, row: 2 }.a1(), "AA3"); // bijective base-26
        for s in ["A1", "Z100", "AA1", "ABC123"] {
            assert_eq!(CellRef::parse(s).map(|c| c.a1()).as_deref(), Some(s));
        }
    }

    #[test]
    fn evaluate_wire_roundtrip() {
        use std::collections::HashMap;
        let cells: HashMap<String, String> = [
            ("A1".to_string(), "5".to_string()),
            ("A2".to_string(), "10".to_string()),
        ]
        .into_iter()
        .collect();
        let req = FormulaRequest {
            formulas: vec!["A1+A2".to_string(), "SUM(A1:A2)".to_string(), "1/0".to_string()],
            cells,
        };
        let frame = crate::wire::encode_frame(&req).expect("encode request");
        let out = evaluate_wire(&frame).expect("evaluate_wire");
        let resp: FormulaResponse = crate::wire::decode_frame(&out).expect("decode response");
        assert_eq!(
            resp.values,
            vec![
                Value::Number(15.0),
                Value::Number(15.0),
                Value::Error(FormulaError::DivideByZero),
            ]
        );
    }

    #[test]
    fn math_extended_functions() {
        assert_eq!(evaluate("ROUNDUP(3.14159, 2)"), Value::Number(3.15));
        assert_eq!(evaluate("ROUNDUP(-3.14159, 2)"), Value::Number(-3.15)); // away from zero
        assert_eq!(evaluate("ROUNDDOWN(3.789, 1)"), Value::Number(3.7));
        assert_eq!(evaluate("TRUNC(3.789)"), Value::Number(3.0));
        assert_eq!(evaluate("TRUNC(-3.789)"), Value::Number(-3.0));
        assert_eq!(evaluate("CEILING(4.2)"), Value::Number(5.0));
        assert_eq!(evaluate("CEILING(4.2, 0.5)"), Value::Number(4.5));
        assert_eq!(evaluate("FLOOR(4.8)"), Value::Number(4.0));
        assert_eq!(evaluate("FLOOR(4.8, 0.5)"), Value::Number(4.5));
        assert_eq!(evaluate("SIGN(-3)"), Value::Number(-1.0));
        assert_eq!(evaluate("SIGN(0)"), Value::Number(0.0));
        assert_eq!(evaluate("EXP(0)"), Value::Number(1.0));
        assert_eq!(evaluate("LN(1)"), Value::Number(0.0));
        assert_eq!(evaluate("LOG10(1000)"), Value::Number(3.0));
        assert!(matches!(evaluate("LN(-1)"), Value::Error(FormulaError::Num)));
        assert!(matches!(evaluate("LN(0)"), Value::Error(FormulaError::Num)));
    }

    #[test]
    fn text_extended_functions() {
        assert_eq!(evaluate("EXACT(\"abc\", \"abc\")"), Value::Bool(true));
        assert_eq!(evaluate("EXACT(\"abc\", \"ABC\")"), Value::Bool(false)); // case-sensitive
        assert_eq!(evaluate("REPT(\"ab\", 3)"), Value::Text("ababab".to_string()));
        assert_eq!(evaluate("REPT(\"x\", 0)"), Value::Text(String::new()));
        assert!(matches!(evaluate("REPT(\"x\", -1)"), Value::Error(FormulaError::Value)));
        assert_eq!(evaluate("SUBSTITUTE(\"a-b-c\", \"-\", \"+\")"), Value::Text("a+b+c".to_string()));
        assert_eq!(evaluate("SUBSTITUTE(\"a-b-c\", \"-\", \"+\", 2)"), Value::Text("a-b+c".to_string()));
        assert_eq!(evaluate("SUBSTITUTE(\"abc\", \"\", \"x\")"), Value::Text("abc".to_string())); // empty old → unchanged
    }

    #[test]
    fn logical_error_functions() {
        assert_eq!(evaluate("IFERROR(1/0, 99)"), Value::Number(99.0));
        assert_eq!(evaluate("IFERROR(5, 99)"), Value::Number(5.0));
        assert_eq!(evaluate("IFS(1>2, \"a\", 3>2, \"b\")"), Value::Text("b".to_string()));
        assert!(matches!(evaluate("IFS(1>2, \"a\", 2>3, \"b\")"), Value::Error(FormulaError::Na)));
        assert_eq!(
            evaluate("SWITCH(2, 1, \"one\", 2, \"two\", \"def\")"),
            Value::Text("two".to_string())
        );
        assert_eq!(
            evaluate("SWITCH(9, 1, \"one\", 2, \"two\", \"def\")"),
            Value::Text("def".to_string())
        );
        assert!(matches!(
            evaluate("SWITCH(9, 1, \"one\", 2, \"two\")"),
            Value::Error(FormulaError::Na)
        ));
        assert_eq!(evaluate("ISERR(1/0)"), Value::Bool(true)); // #DIV/0! is an error ≠ #N/A
        assert_eq!(evaluate("ISNA(1/0)"), Value::Bool(false));
        assert_eq!(evaluate("ISNA(5)"), Value::Bool(false)); // non-error → false
    }

    #[test]
    fn stats_functions() {
        assert_eq!(evaluate("MEDIAN(1, 3, 2)"), Value::Number(2.0)); // odd → middle
        assert_eq!(evaluate("MEDIAN(1, 2, 3, 4)"), Value::Number(2.5)); // even → mean of two
        assert_eq!(evaluate("MEDIAN(5)"), Value::Number(5.0));
        assert!(matches!(evaluate("MEDIAN(\"x\")"), Value::Error(FormulaError::Num))); // no numbers → #NUM
        assert_eq!(evaluate("COUNTA(1, \"x\", 5)"), Value::Number(3.0));
        assert_eq!(evaluate("COUNTA(A1:A3)"), Value::Number(0.0)); // all blank (no resolver)
    }

    #[test]
    fn recalc_engine() {
        use std::collections::HashMap;
        let cells: HashMap<String, String> = [
            ("A1", "5"),
            ("A2", "=A1+1"), // chain: → 6
            ("A3", "=A2*2"), // chain: → 12
            ("B1", "=B2"), // mutual cycle
            ("B2", "=B1"),
            ("C1", "=C1"), // self cycle
            ("D1", "=A2>A1"), // bool, references FORMULA cell A2 (must see 6, not "=A1+1")
            ("E1", "=D1"), // references a bool-formula cell (bool VALUE must propagate)
        ]
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect();
        let out = recalc(&cells);
        assert_eq!(out.get("A2"), Some(&Value::Number(6.0)));
        assert_eq!(out.get("A3"), Some(&Value::Number(12.0)));
        assert!(matches!(out.get("B1"), Some(Value::Error(FormulaError::Cycle))));
        assert!(matches!(out.get("B2"), Some(Value::Error(FormulaError::Cycle))));
        assert!(matches!(out.get("C1"), Some(Value::Error(FormulaError::Cycle))));
        assert_eq!(out.get("D1"), Some(&Value::Bool(true))); // 6 > 5 — recursion gap closed
        assert_eq!(out.get("E1"), Some(&Value::Bool(true))); // bool value propagated through a formula ref
        assert_eq!(out.get("A1"), None); // data cells are not in the output
    }

    #[test]
    fn recalc_wire_roundtrip() {
        use std::collections::HashMap;
        let cells: HashMap<String, String> = [("A1", "5"), ("A2", "=A1+1"), ("A3", "=A2*2")]
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect();
        let frame = crate::wire::encode_frame(&RecalcRequest { cells }).expect("encode request");
        let out = recalc_wire(&frame).expect("recalc_wire");
        let resp: RecalcResponse = crate::wire::decode_frame(&out).expect("decode response");
        assert_eq!(resp.values.get("A2"), Some(&Value::Number(6.0)));
        assert_eq!(resp.values.get("A3"), Some(&Value::Number(12.0)));
        assert_eq!(resp.values.get("A1"), None); // data cell omitted from the result
    }

    #[test]
    fn wildcard_criteria() {
        use std::collections::HashMap;
        let grid: HashMap<CellRef, String> = [
            (CellRef { col: 0, row: 0 }, "apple"),
            (CellRef { col: 0, row: 1 }, "apricot"),
            (CellRef { col: 0, row: 2 }, "banana"),
            (CellRef { col: 0, row: 3 }, "grape"),
        ]
        .into_iter()
        .map(|(k, v)| (k, v.to_string()))
        .collect();
        let r = |c: CellRef| grid.get(&c).cloned();
        assert_eq!(evaluate_with("COUNTIF(A1:A4, \"a*\")", &r), Value::Number(2.0)); // prefix: apple, apricot
        assert_eq!(evaluate_with("COUNTIF(A1:A4, \"*e\")", &r), Value::Number(2.0)); // suffix: apple, grape
        assert_eq!(evaluate_with("COUNTIF(A1:A4, \"*a*\")", &r), Value::Number(4.0)); // contains a
        assert_eq!(evaluate_with("COUNTIF(A1:A4, \"?a*\")", &r), Value::Number(1.0)); // 2nd char a: banana
        assert_eq!(evaluate_with("COUNTIF(A1:A4, \"gr?pe\")", &r), Value::Number(1.0)); // grape
        assert_eq!(evaluate_with("COUNTIF(A1:A4, \"A*\")", &r), Value::Number(2.0)); // case-insensitive
        assert_eq!(evaluate_with("COUNTIF(A1:A4, \"<>a*\")", &r), Value::Number(2.0)); // NOT a*: banana, grape

        let lit: HashMap<CellRef, String> =
            [(CellRef { col: 0, row: 0 }, "a*b"), (CellRef { col: 0, row: 1 }, "axb")]
                .into_iter()
                .map(|(k, v)| (k, v.to_string()))
                .collect();
        let rl = |c: CellRef| lit.get(&c).cloned();
        assert_eq!(evaluate_with("COUNTIF(A1:A2, \"a~*b\")", &rl), Value::Number(1.0)); // ~ escapes * → literal
    }
}
