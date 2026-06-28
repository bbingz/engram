import Foundation

/// Pure vector helpers for the local brute-force semantic store. Vectors are
/// stored L2-normalized, so cosine similarity reduces to a dot product on the
/// hot path; `cosine` still divides by norms to stay correct for any input.
public enum VectorMath {
    public static func l2Normalize(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Dot product over the shared prefix. Equals cosine for normalized inputs.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var sum: Float = 0
        var i = 0
        while i < n {
            sum += a[i] * b[i]
            i += 1
        }
        return sum
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var dotp: Float = 0
        var na: Float = 0
        var nb: Float = 0
        var i = 0
        while i < n {
            dotp += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
            i += 1
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dotp / denom : 0
    }

    /// Little-endian Float32 BLOB encoding (also the sqlite-vec on-disk layout,
    /// so a future migration to a vec0 table can reuse these bytes verbatim).
    public static func encode(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 4)
        for value in v {
            var le = value.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) -> [Float] {
        guard data.count.isMultiple(of: 4) else { return [] }
        let count = data.count / 4
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                out[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return out
    }

    public static func decode(_ data: Data, expectedCount: Int) -> [Float]? {
        guard expectedCount > 0 else { return nil }
        guard expectedCount <= Int.max / 4 else { return nil }
        guard data.count == expectedCount * 4 else { return nil }
        let decoded = decode(data)
        guard decoded.count == expectedCount else { return nil }
        return decoded
    }
}
