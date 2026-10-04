import { range, type CellRange } from "../model/address";
import { FormulaError } from "../model/values";
import { referenceRange, tokenize, type CellReference, type FormulaToken, type RangeReference, type TokenKind } from "./lexer";

/** A parsed formula. */
export type Expr =
  | { e: "number"; value: number }
  | { e: "string"; value: string }
  | { e: "bool"; value: boolean }
  | { e: "error"; value: FormulaError }
  | { e: "cell"; ref: CellReference }
  | { e: "range"; ref: RangeReference }
  | { e: "name"; name: string }
  | { e: "unary"; op: string; operand: Expr }
  | { e: "percent"; operand: Expr }
  | { e: "binary"; op: string; left: Expr; right: Expr }
  | { e: "call"; name: string; args: Expr[] }
  | { e: "array"; rows: Expr[][] }
  /** An omitted argument, as in `IF(A1,,2)`. */
  | { e: "missing" };

const COMPARISON = new Set(["=", "<>", "<", ">", "<=", ">="]);

/**
 * Recursive-descent parser following Excel's operator precedence:
 * `:` › negation › `%` › `^` › `* /` › `+ -` › `&` › comparisons.
 * Throws a FormulaError for text that isn't a formula.
 */
export function parseFormula(source: string): Expr {
  const tokens = tokenize(source).filter((t) => t.kind.t !== "space");
  if (!tokens.length) throw FormulaError.value;
  const p = new Parser(tokens);
  const expression = p.comparison();
  if (p.position !== tokens.length) throw FormulaError.value;
  return expression;
}

class Parser {
  position = 0;
  constructor(private tokens: FormulaToken[]) {}

  private get current(): TokenKind | undefined {
    return this.tokens[this.position]?.kind;
  }

  private is(t: TokenKind["t"]) {
    return this.current?.t === t;
  }

  private operator(symbols: Set<string> | string): string | null {
    const c = this.current;
    if (c?.t !== "op") return null;
    if (typeof symbols === "string" ? c.op === symbols : symbols.has(c.op)) return c.op;
    return null;
  }

  comparison(): Expr {
    let left = this.concat();
    for (let op = this.operator(COMPARISON); op; op = this.operator(COMPARISON)) {
      this.position++;
      left = { e: "binary", op, left, right: this.concat() };
    }
    return left;
  }

  private concat(): Expr {
    let left = this.additive();
    while (this.operator("&")) {
      this.position++;
      left = { e: "binary", op: "&", left, right: this.additive() };
    }
    return left;
  }

  private additive(): Expr {
    let left = this.multiplicative();
    for (let op = this.operator("+") ?? this.operator("-"); op; op = this.operator("+") ?? this.operator("-")) {
      this.position++;
      left = { e: "binary", op, left, right: this.multiplicative() };
    }
    return left;
  }

  private multiplicative(): Expr {
    let left = this.power();
    for (let op = this.operator("*") ?? this.operator("/"); op; op = this.operator("*") ?? this.operator("/")) {
      this.position++;
      left = { e: "binary", op, left, right: this.power() };
    }
    return left;
  }

  private power(): Expr {
    let left = this.unary();
    while (this.operator("^")) {
      this.position++;
      left = { e: "binary", op: "^", left, right: this.unary() };
    }
    return left;
  }

  unary(): Expr {
    const op = this.operator("-") ?? this.operator("+");
    if (op) {
      this.position++;
      return { e: "unary", op, operand: this.unary() };
    }
    return this.percent();
  }

  private percent(): Expr {
    let expression = this.rangeOperator();
    while (this.operator("%")) {
      this.position++;
      expression = { e: "percent", operand: expression };
    }
    return expression;
  }

  private rangeOperator(): Expr {
    let left = this.primary();
    while (this.operator(":")) {
      this.position++;
      left = { e: "binary", op: ":", left, right: this.primary() };
    }
    return left;
  }

  private primary(): Expr {
    const token = this.current;
    if (!token) throw FormulaError.value;
    switch (token.t) {
      case "number": this.position++; return { e: "number", value: token.value };
      case "string": this.position++; return { e: "string", value: token.value };
      case "bool": this.position++; return { e: "bool", value: token.value };
      case "error": this.position++; return { e: "error", value: token.value };
      case "cell": this.position++; return { e: "cell", ref: token.ref };
      case "range": this.position++; return { e: "range", ref: token.ref };
      case "name": this.position++; return { e: "name", name: token.name };
      case "(": {
        this.position++;
        const inner = this.comparison();
        if (!this.is(")")) throw FormulaError.value;
        this.position++;
        return inner;
      }
      case "function": {
        this.position++;
        if (!this.is("(")) throw FormulaError.value;
        this.position++;
        const args: Expr[] = [];
        if (this.is(")")) {
          this.position++;
          return { e: "call", name: token.name, args };
        }
        for (;;) {
          if (this.is(",") || this.is(";") || this.is(")")) args.push({ e: "missing" });
          else args.push(this.comparison());
          if (this.is(",") || this.is(";")) {
            this.position++;
            continue;
          }
          if (!this.is(")")) throw FormulaError.value;
          this.position++;
          break;
        }
        return { e: "call", name: token.name, args };
      }
      case "{": {
        this.position++;
        const rows: Expr[][] = [[]];
        for (;;) {
          rows[rows.length - 1].push(this.unary());
          if (this.is(",")) { this.position++; continue; }
          if (this.is(";")) { this.position++; rows.push([]); continue; }
          if (!this.is("}")) throw FormulaError.value;
          this.position++;
          break;
        }
        const width = rows[0].length;
        if (!rows.every((r) => r.length === width)) throw FormulaError.value;
        return { e: "array", rows };
      }
      default:
        throw FormulaError.value;
    }
  }
}

/** Every reference the expression mentions, for dependency highlighting. */
export function expressionReferences(expression: Expr): { sheet?: string; range: CellRange }[] {
  const result: { sheet?: string; range: CellRange }[] = [];
  const walk = (x: Expr) => {
    switch (x.e) {
      case "cell": result.push({ sheet: x.ref.sheet, range: range({ row: x.ref.row, column: x.ref.column }) }); break;
      case "range": result.push({ sheet: x.ref.sheet, range: referenceRange(x.ref) }); break;
      case "unary": case "percent": walk(x.operand); break;
      case "binary": walk(x.left); walk(x.right); break;
      case "call": x.args.forEach(walk); break;
      case "array": x.rows.forEach((r) => r.forEach(walk)); break;
      default: break;
    }
  };
  walk(expression);
  return result;
}

const VOLATILE = new Set(["NOW", "TODAY", "RAND", "RANDBETWEEN", "RANDARRAY", "OFFSET", "INDIRECT"]);

/** True when the formula uses NOW, RAND or other functions that change on every recalculation. */
export function isVolatile(x: Expr): boolean {
  switch (x.e) {
    case "call": return VOLATILE.has(x.name) || x.args.some(isVolatile);
    case "unary": case "percent": return isVolatile(x.operand);
    case "binary": return isVolatile(x.left) || isVolatile(x.right);
    default: return false;
  }
}
