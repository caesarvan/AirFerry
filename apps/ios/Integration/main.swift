import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let expected = try Data(contentsOf: root.appendingPathComponent("expected.bin"))
for algorithm in 0...2 {
    let receiver = Receiver(outputDirectory: root)
    let frames = [UInt8](try Data(contentsOf: root.appendingPathComponent("\(algorithm).frames")))
    var offset = 0
    var recovered: URL?
    while offset < frames.count && recovered == nil {
        let length = frames[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        let frame = Data(frames[offset..<offset+length]); offset += length
        let (_, url) = try receiver.ingest(frame)
        recovered = url
    }
    precondition(recovered != nil)
    let actual = try Data(contentsOf: recovered!)
    precondition(actual == expected)
    precondition(recovered!.deletingLastPathComponent().deletingLastPathComponent() == root)
    print("Swift → Rust → recovery + length/CRC + safe export passed: algorithm \(algorithm)")
}

let largeExpected = try Data(contentsOf: root.appendingPathComponent("large.bin"), options: .mappedIfSafe)
for algorithm in 0...2 {
    var receiver = Receiver(outputDirectory: root)
    let frames = try Data(contentsOf: root.appendingPathComponent("large-\(algorithm).frames"), options: .mappedIfSafe)
    var offset = 0
    var recovered: URL?
    var restarted = false
    while offset < frames.count && recovered == nil {
        let length = frames[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }; offset += 4
        let frame = Data(frames[offset..<offset+length]); offset += length
        let (message, url) = try receiver.ingest(frame)
        recovered = url
        if algorithm == 0 && !restarted && message.contains("已保存 1/") {
            receiver = Receiver(outputDirectory: root) // process restart: only disk receipts survive
            restarted = true
        }
    }
    guard let recovered else { fatalError("large transfer incomplete: \(algorithm)") }
    let actual = try Data(contentsOf: recovered, options: .mappedIfSafe)
    precondition(actual == largeExpected)
    if algorithm == 0 { precondition(restarted) }
    print("65 MiB segmented recovery + SHA256 passed: algorithm \(algorithm)")
}

let testMeta = SegmentStore.Metadata(root: "integrity-test", count: 1, compressed: 3, original: 3, compression: 0, crc: 0, crcKnown: false, sha: String(repeating: "0", count: 64), name: "test.bin")
let store = try SegmentStore(meta: testMeta, directory: root)
do {
    try store.store(0, data: Data([1, 2, 3]), sha: String(repeating: "0", count: 64))
    fatalError("bad segment hash accepted")
} catch is ReceiveError {}
let bytes = Data([1, 2, 3])
try store.store(0, data: bytes, sha: SegmentStore.digest(bytes))
try Data([3, 2, 1]).write(to: store.segment(0), options: .atomic)
let reopened = try SegmentStore(meta: testMeta, directory: root)
precondition(reopened.completed.isEmpty)
print("Tampered segment rejection and persisted segment revalidation passed")
try reopened.store(0, data: bytes, sha: SegmentStore.digest(bytes))
do {
    try reopened.finish(to: reopened.folder.appendingPathComponent("invalid-output.partial"))
    fatalError("bad root SHA256 accepted")
} catch is ReceiveError {}
precondition(!FileManager.default.fileExists(atPath: reopened.folder.appendingPathComponent("invalid-output.partial").path))
print("Wrong whole-file SHA256 rejected without publishing output")
