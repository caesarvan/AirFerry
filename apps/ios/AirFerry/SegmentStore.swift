import Foundation
import CryptoKit

/// One root transfer, compressed once and split into canonical protocol segments.
/// Only one segment's decoder is resident. Completed segments survive app restart.
final class SegmentStore {
    static let stride: UInt64 = 32 * 1024 * 1024 - 65_528
    static let limit: UInt64 = 256 * 1024 * 1024 // shared Rust MAX_ORIGINAL_BYTES
    struct Metadata: Codable, Equatable {
        let root: String
        let count: UInt32
        let compressed: UInt64
        let original: UInt64
        let compression: UInt8
        let crc: UInt32
        let crcKnown: Bool
        let sha: String
        let name: String
    }
    let meta: Metadata
    let folder: URL
    var completed: [UInt32: String] = [:]
    static func hash(_ handle: UnsafeMutableRawPointer, root: Bool) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if root { _ = airferry_receiver_root_sha256(handle, &bytes, 32) }
        else { _ = airferry_receiver_raw_sha256(handle, &bytes, 32) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    static func metadata(_ h: UnsafeMutableRawPointer, name: String) -> Metadata {
        Metadata(root: String(format: "%016llx%016llx", airferry_receiver_root_session_id_hi(h), airferry_receiver_root_session_id_lo(h)),
                 count: airferry_receiver_segment_count(h), compressed: airferry_receiver_root_original_size(h),
                 original: airferry_receiver_file_size(h), compression: airferry_receiver_compression(h),
                 crc: UInt32(airferry_receiver_crc32(h)), crcKnown: airferry_receiver_crc32_known(h) != 0,
                 sha: hash(h, root: true), name: name)
    }
    init(meta: Metadata, directory: URL) throws {
        guard meta.original <= Self.limit, meta.compressed > 0, meta.compressed <= Self.limit,
              UInt64(meta.count) == (meta.compressed - 1) / Self.stride + 1 else {
            throw ReceiveError.invalid("大文件超出当前协议 256 MiB 限额或分段信息无效。")
        }
        self.meta = meta
        folder = directory.appendingPathComponent(meta.root, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadataURL = folder.appendingPathComponent("metadata.json")
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            guard try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL)) == meta else {
                throw ReceiveError.invalid("同一任务的分段元数据冲突，已保留原有暂存。")
            }
        } else { try JSONEncoder().encode(meta).write(to: metadataURL, options: .atomic) }
        // Revalidate receipts against actual disk bytes before trusting persisted state.
        let receipt = folder.appendingPathComponent("receipts.json")
        let saved = (try? JSONDecoder().decode([UInt32: String].self, from: Data(contentsOf: receipt))) ?? [:]
        for (index, digest) in saved where index < meta.count {
            if let data = try? Data(contentsOf: segment(index)), UInt64(data.count) == length(index), Self.digest(data) == digest {
                completed[index] = digest
            }
        }
    }
    func segment(_ index: UInt32) -> URL { folder.appendingPathComponent("\(index).part") }
    func length(_ index: UInt32) -> UInt64 { min(Self.stride, meta.compressed - UInt64(index) * Self.stride) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func checkSpace(_ needed: UInt64) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        let available = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        guard available >= needed + 64 * 1024 * 1024 else { throw ReceiveError.invalid("磁盘空间不足，请释放空间后继续接收。") }
    }
    func store(_ index: UInt32, data: Data, sha: String) throws {
        guard index < meta.count, UInt64(data.count) == length(index), Self.digest(data) == sha else {
            throw ReceiveError.invalid("分段长度或 SHA256 校验失败，未保存。")
        }
        if let old = completed[index] {
            guard old == sha else { throw ReceiveError.invalid("重复分段哈希冲突。") }
            return
        }
        try checkSpace(UInt64(data.count))
        try data.write(to: segment(index), options: .atomic)
        let file = try FileHandle(forWritingTo: segment(index))
        try file.synchronize(); try file.close()
        completed[index] = sha
        try JSONEncoder().encode(completed).write(to: folder.appendingPathComponent("receipts.json"), options: .atomic)
    }
    func finish(to output: URL) throws {
        guard completed.count == Int(meta.count) else { throw ReceiveError.invalid("尚有缺失分段。") }
        try checkSpace(meta.compressed + meta.original)
        let input = folder.appendingPathComponent("compressed.partial")
        FileManager.default.createFile(atPath: input.path, contents: nil)
        let writer = try FileHandle(forWritingTo: input)
        do {
            for index in 0..<meta.count {
                let reader = try FileHandle(forReadingFrom: segment(index))
                do {
                    while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty { try writer.write(contentsOf: chunk) }
                    try reader.close()
                } catch { try? reader.close(); throw error }
            }
            try writer.synchronize(); try writer.close()
        } catch { try? writer.close(); throw error }
        defer { try? FileManager.default.removeItem(at: input) }
        let ok = input.path.withCString { src in output.path.withCString { dst in meta.sha.withCString { sha in
            airferry_decompress_stream_to_file(src, dst, meta.compression, Self.limit, meta.original, meta.crc, meta.crcKnown, sha)
        } } }
        guard ok == 1 else { throw ReceiveError.invalid("整文件解压、长度、CRC32 或 SHA256 校验失败；已保留分段供重试。") }
    }
}
