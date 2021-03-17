import Foundation
import MongoSwift
import Nimble

// swiftlint:disable line_length
/// Protocol that allows a type to assert it matches a given value according to the specs' MATCHES function.
/// https://github.com/mongodb/specifications/tree/master/source/connection-monitoring-and-pooling/tests#spec-test-match-function
internal protocol Matchable {
    /// Returns whether this MATCHES the expected value according to the function defined in the spec.
    /// This assumes `expected` is NOT a placeholder value (i.e. 42/"42"). Use `matches` if `expected` may be a
    /// placeholder.
    /// https://github.com/mongodb/specifications/tree/master/source/connection-monitoring-and-pooling/tests#spec-test-match-function
    func contentMatches(expected: Self) -> Bool

    /// Determines if this value is considered a wildcard for the purposes of the MATCHES function.
    func isPlaceholder() -> Bool
}

// swiftlint:enable line_length

extension Matchable {
    internal func isPlaceholder() -> Bool {
        false
    }

    /// Returns whether this MATCHES the expected value according to the function defined in the spec.
    internal func matches<T: Matchable>(expected: T) -> Bool {
        guard !expected.isPlaceholder() else {
            return true
        }

        guard let expected = expected as? Self else {
            return false
        }
        return self.contentMatches(expected: expected)
    }
}

extension Matchable where Self: Equatable {
    internal func contentMatches(expected: Self) -> Bool {
        self == expected
    }
}

extension Int: Matchable {
    internal func isPlaceholder() -> Bool {
        self == 42
    }
}

extension String: Matchable {
    internal func isPlaceholder() -> Bool {
        self == "42"
    }
}

/// Extension that adds MATCHES functionality to `Array`.
extension Array: Matchable where Element: Matchable {
    internal func contentMatches(expected: [Element]) -> Bool {
        guard expected.count <= self.count else {
            return false
        }

        return zip(self, expected).allSatisfy { aV, eV in aV.matches(expected: eV) }
    }
}

/// Extension that adds MATCHES functionality to `Document`.
extension BSONDocument: Matchable {
    internal func contentMatches(expected: BSONDocument) -> Bool {
        for (eK, eV) in expected {
            // If the expected document has "key": null then the actual document must either have "key": null
            // or no reference to "key".
            guard let aV = self[eK] else {
                guard eV == .null else {
                    return false
                }
                continue
            }
            guard aV.matches(expected: eV) else {
                return false
            }
        }
        return true
    }
}

/// Extension that adds MATCHES functionality to `BSON`.
extension BSON: Matchable {
    internal func isPlaceholder() -> Bool {
        self.toInt()?.isPlaceholder() == true || self.stringValue?.isPlaceholder() == true
    }

    internal func contentMatches(expected: BSON) -> Bool {
        switch (self, expected) {
        case let (.document(actual), .document(expected)):
            return actual.matches(expected: expected)
        case let (.array(actual), .array(expected)):
            return actual.matches(expected: expected)
        default:
            if let selfInt = self.toInt(), let expectedInt = expected.toInt() {
                return selfInt == expectedInt
            }
            return self == expected
        }
    }
}

// swiftlint:disable line_length
/// A Nimble matcher for the MATCHES function defined in the spec.
/// https://github.com/mongodb/specifications/tree/master/source/connection-monitoring-and-pooling/tests#spec-test-match-function
internal func match<T: Matchable, V: Matchable>(_ expectedValue: V?) -> Predicate<T> {
    // swiftlint:enable line_length
    Predicate.define("match <\(stringify(expectedValue))>") { actualExpression, msg in
        let actualValue = try actualExpression.evaluate()
        switch (expectedValue, actualValue) {
        case (nil, _?):
            return PredicateResult(status: .fail, message: msg.appendedBeNilHint())
        case (nil, nil), (_, nil):
            return PredicateResult(status: .fail, message: msg)
        case let (expected?, actual?):
            let matches = actual.matches(expected: expected)
            return PredicateResult(bool: matches, message: msg)
        }
    }
}
