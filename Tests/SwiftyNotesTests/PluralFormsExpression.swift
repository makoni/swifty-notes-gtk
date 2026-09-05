import Foundation

/// The `plural=` expression from a catalogue's `Plural-Forms` header,
/// evaluated the way gettext evaluates it.
///
/// A guard that wants to know *which* form a language uses for a given count
/// cannot assume the order: index 0 is the singular in English, German and
/// Russian, but the zero form in Arabic. The header carries the answer as a C
/// expression over `n`, so the tests read it rather than tabulating it.
///
/// The grammar is the one gettext documents for the header: integer literals,
/// `n`, the usual arithmetic, comparison and logical operators, `?:`, and
/// parentheses. Booleans are C's — comparisons produce 1 or 0, and anything
/// non-zero is true.
struct PluralFormsExpression {
    /// Where a `Plural-Forms` header could not be turned into an expression.
    enum ParseError: Error, CustomStringConvertible {
        case unexpectedCharacter(Character)
        case unexpectedEnd
        case unexpectedToken(String)
        case trailingInput(String)

        var description: String {
            switch self {
            case let .unexpectedCharacter(character):
                "unexpected character \(character.debugDescription) in the plural expression"
            case .unexpectedEnd:
                "the plural expression ends early"
            case let .unexpectedToken(token):
                "unexpected \(token) in the plural expression"
            case let .trailingInput(token):
                "the plural expression continues past its end at \(token)"
            }
        }
    }

    private indirect enum Node {
        case count
        case literal(Int)
        case not(Node)
        case binary(Operator, Node, Node)
        case ternary(Node, Node, Node)
    }

    private enum Operator: String {
        case or = "||"
        case and = "&&"
        case equal = "=="
        case notEqual = "!="
        case lessOrEqual = "<="
        case greaterOrEqual = ">="
        case less = "<"
        case greater = ">"
        case add = "+"
        case subtract = "-"
        case multiply = "*"
        case divide = "/"
        case remainder = "%"
    }

    private enum Token: Equatable {
        case number(Int)
        case count
        case oper(String)
        case leftParenthesis
        case rightParenthesis
        case question
        case colon
        case not

        var describedForError: String {
            switch self {
            case let .number(value): "\(value)"
            case .count: "n"
            case let .oper(symbol): symbol
            case .leftParenthesis: "("
            case .rightParenthesis: ")"
            case .question: "?"
            case .colon: ":"
            case .not: "!"
            }
        }
    }

    private let root: Node

    /// Parses the expression body — the text after `plural=`, with or without
    /// its trailing semicolon.
    init(_ source: String) throws {
        var parser = Parser(tokens: try Self.tokenize(source))
        root = try parser.parseExpression()
        try parser.expectEnd()
    }

    /// Parses the `plural=` half of a whole `Plural-Forms` header, or returns
    /// `nil` when the header carries none.
    init?(header: String) throws {
        guard let range = header.range(of: "plural=") else { return nil }
        var body = String(header[range.upperBound...])
        if let semicolon = body.firstIndex(of: ";") {
            body = String(body[..<semicolon])
        }
        try self.init(body)
    }

    /// Which `msgstr[…]` index the language uses for `count`.
    func form(for count: Int) -> Int {
        Self.evaluate(root, count: count)
    }

    /// The `msgstr[…]` indices that stand for a plain plural and nothing else.
    ///
    /// Two kinds of form are left out, because both carry a number the words
    /// show without printing a digit:
    ///
    /// - the form the language uses for one, whatever else it covers. Russian
    ///   reuses its singular for 21 and 101, and no single string can be right
    ///   for both 1 and 21 when the count is not on screen — one is the case
    ///   worth getting right.
    /// - a *true* dual: a form nothing but two selects. Arabic has one;
    ///   Russian's 2–4 form does not qualify, because 3 and 4 pick it too, so
    ///   it has to read like the plural it also stands for.
    ///
    /// The limit stops at 1000 by default: every expression gettext ships
    /// cycles on `n % 100` at the widest, so a thousand counts visit every
    /// branch.
    func formsThatOnlyMeanPlural(upTo limit: Int = 1000) -> Set<Int> {
        var forms = Set((2 ... limit).map(form(for:)))
        forms.remove(form(for: 1))
        let dual = form(for: 2)
        if !(3 ... limit).contains(where: { form(for: $0) == dual }) {
            forms.remove(dual)
        }
        return forms
    }

    // MARK: - Tokenizing

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character.isWhitespace {
                index = source.index(after: index)
                continue
            }
            if character.isNumber {
                var digits = ""
                while index < source.endIndex, source[index].isNumber {
                    digits.append(source[index])
                    index = source.index(after: index)
                }
                tokens.append(.number(Int(digits) ?? 0))
                continue
            }
            if character == "n" {
                tokens.append(.count)
                index = source.index(after: index)
                continue
            }
            let rest = source[index...]
            if let symbol = ["||", "&&", "==", "!=", "<=", ">="].first(where: { rest.hasPrefix($0) }) {
                tokens.append(.oper(symbol))
                index = source.index(index, offsetBy: symbol.count)
                continue
            }
            switch character {
            case "(": tokens.append(.leftParenthesis)
            case ")": tokens.append(.rightParenthesis)
            case "?": tokens.append(.question)
            case ":": tokens.append(.colon)
            case "!": tokens.append(.not)
            case "<", ">", "+", "-", "*", "/", "%": tokens.append(.oper(String(character)))
            default: throw ParseError.unexpectedCharacter(character)
            }
            index = source.index(after: index)
        }
        return tokens
    }

    // MARK: - Parsing

    private struct Parser {
        private let tokens: [Token]
        private var position = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        private var current: Token? {
            position < tokens.count ? tokens[position] : nil
        }

        private mutating func advance() {
            position += 1
        }

        private mutating func match(_ symbols: [String]) -> Operator? {
            guard case let .oper(symbol) = current, symbols.contains(symbol) else { return nil }
            advance()
            return Operator(rawValue: symbol)
        }

        mutating func expectEnd() throws {
            if let token = current {
                throw ParseError.trailingInput(token.describedForError)
            }
        }

        mutating func parseExpression() throws -> Node {
            let condition = try parseOr()
            guard current == .question else { return condition }
            advance()
            let whenTrue = try parseExpression()
            guard current == .colon else {
                throw current.map { ParseError.unexpectedToken($0.describedForError) } ?? .unexpectedEnd
            }
            advance()
            let whenFalse = try parseExpression()
            return .ternary(condition, whenTrue, whenFalse)
        }

        private mutating func parseOr() throws -> Node {
            var left = try parseAnd()
            while let symbol = match(["||"]) {
                left = .binary(symbol, left, try parseAnd())
            }
            return left
        }

        private mutating func parseAnd() throws -> Node {
            var left = try parseEquality()
            while let symbol = match(["&&"]) {
                left = .binary(symbol, left, try parseEquality())
            }
            return left
        }

        private mutating func parseEquality() throws -> Node {
            var left = try parseRelational()
            while let symbol = match(["==", "!="]) {
                left = .binary(symbol, left, try parseRelational())
            }
            return left
        }

        private mutating func parseRelational() throws -> Node {
            var left = try parseAdditive()
            while let symbol = match(["<", ">", "<=", ">="]) {
                left = .binary(symbol, left, try parseAdditive())
            }
            return left
        }

        private mutating func parseAdditive() throws -> Node {
            var left = try parseMultiplicative()
            while let symbol = match(["+", "-"]) {
                left = .binary(symbol, left, try parseMultiplicative())
            }
            return left
        }

        private mutating func parseMultiplicative() throws -> Node {
            var left = try parseUnary()
            while let symbol = match(["*", "/", "%"]) {
                left = .binary(symbol, left, try parseUnary())
            }
            return left
        }

        private mutating func parseUnary() throws -> Node {
            if current == .not {
                advance()
                return .not(try parseUnary())
            }
            return try parsePrimary()
        }

        private mutating func parsePrimary() throws -> Node {
            switch current {
            case .none:
                throw ParseError.unexpectedEnd
            case .count:
                advance()
                return .count
            case let .number(value):
                advance()
                return .literal(value)
            case .leftParenthesis:
                advance()
                let inner = try parseExpression()
                guard current == .rightParenthesis else {
                    throw current.map { ParseError.unexpectedToken($0.describedForError) } ?? .unexpectedEnd
                }
                advance()
                return inner
            case let .some(token):
                throw ParseError.unexpectedToken(token.describedForError)
            }
        }
    }

    // MARK: - Evaluating

    private static func evaluate(_ node: Node, count: Int) -> Int {
        switch node {
        case .count:
            count
        case let .literal(value):
            value
        case let .not(inner):
            evaluate(inner, count: count) == 0 ? 1 : 0
        case let .ternary(condition, whenTrue, whenFalse):
            evaluate(condition, count: count) != 0
                ? evaluate(whenTrue, count: count)
                : evaluate(whenFalse, count: count)
        case let .binary(symbol, left, right):
            evaluate(symbol, evaluate(left, count: count), evaluate(right, count: count))
        }
    }

    private static func evaluate(_ symbol: Operator, _ left: Int, _ right: Int) -> Int {
        switch symbol {
        case .or: (left != 0 || right != 0) ? 1 : 0
        case .and: (left != 0 && right != 0) ? 1 : 0
        case .equal: left == right ? 1 : 0
        case .notEqual: left != right ? 1 : 0
        case .lessOrEqual: left <= right ? 1 : 0
        case .greaterOrEqual: left >= right ? 1 : 0
        case .less: left < right ? 1 : 0
        case .greater: left > right ? 1 : 0
        case .add: left + right
        case .subtract: left - right
        case .multiply: left * right
        // gettext evaluates the header with unsigned arithmetic and never
        // divides by zero in practice; guard anyway so a malformed header
        // fails the test rather than the process.
        case .divide: right == 0 ? 0 : left / right
        case .remainder: right == 0 ? 0 : left % right
        }
    }
}
