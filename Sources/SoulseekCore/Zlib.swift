import Foundation
import CZlib

/// Standard zlib streams, as used by the Soulseek protocol for search
/// responses, share lists and folder contents (Nicotine+ compression level 4).
public enum Zlib {
    public static func compress(_ data: Data) throws -> Data {
        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        let bytes = [UInt8](data)

        let result = bytes.withUnsafeBufferPointer { buffer -> Int32 in
            slsk_zlib_compress(buffer.baseAddress, bytes.count, &output, &outputLength)
        }

        guard result == 0, let buffer = output, outputLength > 0 else {
            throw SlskError.compressionFailed("status \(result)")
        }
        return Data(bytesNoCopy: buffer, count: outputLength, deallocator: .free)
    }

    public static func decompress(_ data: Data, maxOutput: Int = 448 * 1024 * 1024) throws -> Data {
        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        let bytes = [UInt8](data)

        let result = bytes.withUnsafeBufferPointer { buffer -> Int32 in
            slsk_zlib_decompress(buffer.baseAddress, bytes.count,
                                 &output, &outputLength, maxOutput)
        }

        guard result == 0, let buffer = output else {
            throw SlskError.compressionFailed("status \(result)")
        }
        return Data(bytesNoCopy: buffer, count: outputLength, deallocator: .free)
    }
}
