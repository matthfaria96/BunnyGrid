import Foundation

/// IEEE 754-2008 decimal128 (BID encoding), as BSON stores `NumberDecimal`. Kept as raw bits; converted to and
/// from text with the rules of the BSON Decimal128 spec.
public struct BSONDecimal128: Hashable, Sendable, CustomStringConvertible {
    public var high: UInt64
    public var low: UInt64

    private static let exponentBias = 6176
    private static let maxExponent = 6111
    private static let minExponent = -6176

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    /// Parses `1.5`, `-0.001`, `1E+3`, `Infinity`, `NaN`. nil for malformed text or more than 34 significant digits.
    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if s.first == "-" { negative = true; s = s.dropFirst() } else if s.first == "+" { s = s.dropFirst() }
        let lower = s.lowercased()
        if lower == "infinity" || lower == "inf" {
            high = (negative ? 0x8000_0000_0000_0000 : 0) | 0x7800_0000_0000_0000
            low = 0
            return
        }
        if lower == "nan" {
            high = 0x7C00_0000_0000_0000
            low = 0
            return
        }
        var digits: [UInt8] = []
        var exponent = 0
        var seenPoint = false
        var seenDigit = false
        var index = s.startIndex
        while index < s.endIndex {
            let c = s[index]
            if let d = c.wholeNumberValue, c.isASCII {
                seenDigit = true
                if !(digits.isEmpty && d == 0) { digits.append(UInt8(d)) }
                if seenPoint { exponent -= 1 }
            } else if c == "." && !seenPoint {
                seenPoint = true
            } else if c == "e" || c == "E" {
                let rest = s[s.index(after: index)...]
                guard let e = Int(rest.hasPrefix("+") ? rest.dropFirst() : rest) else { return nil }
                exponent += e
                index = s.endIndex
                break
            } else {
                return nil
            }
            index = s.index(after: index)
        }
        guard seenDigit else { return nil }
        // Trailing zeros past 34 digits can move into the exponent.
        while digits.count > 34, digits.last == 0 {
            digits.removeLast()
            exponent += 1
        }
        guard digits.count <= 34 else { return nil }
        // Clamp the exponent by padding or trimming zeros where possible.
        while exponent > Self.maxExponent, digits.count < 34, !digits.isEmpty {
            digits.append(0)
            exponent -= 1
        }
        if digits.isEmpty { exponent = min(max(exponent, Self.minExponent), Self.maxExponent) }
        guard exponent >= Self.minExponent, exponent <= Self.maxExponent else { return nil }
        var hi: UInt64 = 0, lo: UInt64 = 0
        for d in digits {
            (hi, lo) = Self.multiplyAdd(hi, lo, 10, UInt64(d))
        }
        let biased = UInt64(exponent + Self.exponentBias)
        high = (negative ? 0x8000_0000_0000_0000 : 0) | (biased << 49) | (hi & 0x0001_FFFF_FFFF_FFFF)
        low = lo
    }

    public var description: String {
        let negative = high & 0x8000_0000_0000_0000 != 0
        let combination = (high >> 58) & 0x1F
        if combination == 0x1F { return "NaN" }
        if combination == 0x1E { return negative ? "-Infinity" : "Infinity" }
        var exponent: Int
        var hi: UInt64, lo: UInt64
        if (high >> 61) & 0x3 == 0x3 {
            // Non-canonical form: the coefficient would exceed 10^34, so it reads as zero.
            exponent = Int((high >> 47) & 0x3FFF) - Self.exponentBias
            hi = 0
            lo = 0
        } else {
            exponent = Int((high >> 49) & 0x3FFF) - Self.exponentBias
            hi = high & 0x0001_FFFF_FFFF_FFFF
            lo = low
        }
        var digits = ""
        if hi == 0 && lo == 0 {
            digits = "0"
        } else {
            while hi != 0 || lo != 0 {
                let remainder: UInt64
                (hi, lo, remainder) = Self.divide(hi, lo, by: 10)
                digits.append(Character(String(remainder)))
            }
            digits = String(digits.reversed())
        }
        let adjusted = exponent + digits.count - 1
        var result = negative ? "-" : ""
        if exponent <= 0 && adjusted >= -6 {
            if exponent == 0 {
                result += digits
            } else {
                let pointPosition = digits.count + exponent
                if pointPosition > 0 {
                    let i = digits.index(digits.startIndex, offsetBy: pointPosition)
                    result += digits[..<i] + "." + digits[i...]
                } else {
                    result += "0." + String(repeating: "0", count: -pointPosition) + digits
                }
            }
        } else {
            result += String(digits.first!)
            if digits.count > 1 { result += "." + digits.dropFirst() }
            result += "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
        }
        return result
    }

    private static func multiplyAdd(_ hi: UInt64, _ lo: UInt64, _ m: UInt64, _ a: UInt64) -> (UInt64, UInt64) {
        let (loProductHigh, loProductLow) = lo.multipliedFullWidth(by: m)
        let (newLo, carry) = loProductLow.addingReportingOverflow(a)
        let newHi = hi &* m &+ loProductHigh &+ (carry ? 1 : 0)
        return (newHi, newLo)
    }

    private static func divide(_ hi: UInt64, _ lo: UInt64, by d: UInt64) -> (UInt64, UInt64, UInt64) {
        let qHi = hi / d
        let r = hi % d
        let (qLo, remainder) = d.dividingFullWidth((r, lo))
        return (qHi, qLo, remainder)
    }
}
