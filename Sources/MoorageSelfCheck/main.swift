import Foundation
import MTPKit
import DavKit

/// Terminal test harness: protocol codec round-trips, no device required.
/// `MoorageSelfCheck scan` instead lists MTP devices currently visible on USB.
/// Exit 0 = all pass.

if CommandLine.arguments.contains("scan") {
    let devices = MTPDeviceLocator.connectedDevices()
    if devices.isEmpty {
        print("No MTP devices visible on USB.")
    }
    for d in devices {
        print("\(d.name)  vid=0x\(String(d.vendorID, radix: 16)) pid=0x\(String(d.productID, radix: 16))  url=\(d.mtpURL.absoluteString)")
    }
    exit(devices.isEmpty ? 1 : 0)
}

if CommandLine.arguments.contains("probe") {
    // Step-by-step MTP connection walk against the first visible device,
    // printing exactly where it fails. Terminal-only diagnostics.
    let devices = MTPDeviceLocator.connectedDevices()
    guard let ref = devices.first else {
        print("probe: no MTP device visible"); exit(1)
    }
    print("probe: device \(ref.name) url=\(ref.mtpURL.absoluteString)")
    guard let service = MTPDeviceLocator.findInterfaceService(urlHost: ref.urlHost) else {
        print("probe: FAIL findInterfaceService"); exit(1)
    }
    print("probe: interface service found")
    let probeSemaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let transport = try USBTransport(interfaceService: service)
            print("probe: transport open (exclusive USB claim OK)")
            let device = MTPDevice(transport: transport)
            let info = try await device.connect()
            print("probe: session open, model=\(info.model) serial=\(info.serialNumber)")
            print("probe: ops supported: \(info.operationsSupported.count), GetPartialObject=\(info.supports(.getPartialObject))")
            let ids = try await device.storageIDs()
            print("probe: storages: \(ids.map { String(format: "0x%08x", $0) })")
            for id in ids {
                let storage = try await device.storageInfo(id)
                print("probe:   \(storage.description): \(storage.maxCapacity / 1_000_000) MB total, \(storage.freeSpace / 1_000_000) MB free")
                let handles = try await device.objectHandles(storageID: id, parentHandle: PTP.rootParentHandle)
                print("probe:   root has \(handles.count) object(s)")
                for handle in handles.prefix(10) {
                    if let objectInfo = try? await device.objectInfo(handle) {
                        print("probe:     \(objectInfo.isFolder ? "dir " : "file") \(objectInfo.filename) (\(objectInfo.compressedSize) bytes)")
                    }
                }
            }
            // Read tests: small file then a multi-KB file, direct MTP.
            if CommandLine.arguments.contains("read") {
                for id in ids {
                    let handles = try await device.objectHandles(storageID: id, parentHandle: PTP.rootParentHandle)
                    for handle in handles {
                        guard let objectInfo = try? await device.objectInfo(handle), !objectInfo.isFolder, objectInfo.compressedSize > 0 else { continue }
                        let want = Int(min(objectInfo.compressedSize, 64 << 10))
                        let started = Date()
                        do {
                            let data = try await device.readObject(handle: handle, offset: 0, length: want)
                            print("probe: read \(objectInfo.filename): got \(data.count)/\(want) bytes in \(String(format: "%.2f", -started.timeIntervalSinceNow))s")
                        } catch {
                            print("probe: read \(objectInfo.filename) FAILED after \(String(format: "%.2f", -started.timeIntervalSinceNow))s: \(error)")
                        }
                    }
                    // Walk one level into folders for larger files (fonts/Readme.txt).
                    for handle in handles {
                        guard let dirInfo = try? await device.objectInfo(handle), dirInfo.isFolder else { continue }
                        let inner = (try? await device.objectHandles(storageID: id, parentHandle: handle)) ?? []
                        for innerHandle in inner {
                            guard let objectInfo = try? await device.objectInfo(innerHandle), !objectInfo.isFolder, objectInfo.compressedSize > 8192 else { continue }
                            let want = Int(objectInfo.compressedSize)
                            let started = Date()
                            do {
                                let data = try await device.readObject(handle: innerHandle, offset: 0, length: want)
                                print("probe: read \(dirInfo.filename)/\(objectInfo.filename): got \(data.count)/\(want) in \(String(format: "%.2f", -started.timeIntervalSinceNow))s")
                            } catch {
                                print("probe: read \(dirInfo.filename)/\(objectInfo.filename) FAILED after \(String(format: "%.2f", -started.timeIntervalSinceNow))s: \(error)")
                            }
                            break
                        }
                    }
                }
            }
            await device.disconnect()
            print("probe: SUCCESS, full MTP conversation works")
        } catch {
            print("probe: FAIL, \(error)")
        }
        probeSemaphore.signal()
    }
    probeSemaphore.wait()
    exit(0)
}

if CommandLine.arguments.contains("--serve-demo") {
    // Demo tree for local mount verification: no device needed.
    let backend = InMemoryBackend()
    let seedSemaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await backend.seed(path: ["Internal Storage"], data: nil)
        await backend.seed(path: ["Internal Storage", "documents"], data: nil)
        await backend.seed(path: ["Internal Storage", "documents", "hello.txt"], data: Data("hello from moorage\n".utf8))
        await backend.seed(path: ["Internal Storage", "documents", "book.azw3"], data: Data(repeating: 0x42, count: 2_000_000))
        await backend.seed(path: ["Internal Storage", "music"], data: nil)
        seedSemaphore.signal()
    }
    seedSemaphore.wait()
    let server = DavServer(backend: backend)
    server.debugLogging = true
    try server.start()
    FileHandle.standardOutput.write(Data((server.url.absoluteString + "\n").utf8))
    RunLoop.main.run()
    exit(0)
}

var failures = 0

@MainActor
func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ok  \(label)")
    } else {
        print("FAIL  \(label)")
        failures += 1
    }
}

print("== PTP codec ==")

// Writer/reader round-trip
var w = PTPWriter()
w.u8(0xAB)
w.u16(0x1234)
w.u32(0xDEADBEEF)
w.u64(0x0123_4567_89AB_CDEF)
w.string("Pixel 9 Pro")
w.string("")
var r = PTPReader(w.data)
check((try? r.u8()) == 0xAB, "u8 round-trip")
check((try? r.u16()) == 0x1234, "u16 round-trip")
check((try? r.u32()) == 0xDEADBEEF, "u32 round-trip")
check((try? r.u64()) == 0x0123_4567_89AB_CDEF, "u64 round-trip")
check((try? r.string()) == "Pixel 9 Pro", "string round-trip")
check((try? r.string()) == "", "empty string round-trip")
check(r.remaining == 0, "reader consumed exactly")

// PTP string wire format: count includes NUL, UTF-16LE
var sw = PTPWriter()
sw.string("Ab")
check(Array(sw.data) == [3, 0x41, 0, 0x62, 0, 0, 0], "string wire format")

print("== Containers ==")

let cmd = PTPContainer.command(.openSession, transactionID: 7, params: [1])
let encoded = cmd.encoded()
check(encoded.count == 16, "command container size")
check(Array(encoded.prefix(4)) == [16, 0, 0, 0], "container length field")
if let parsed = try? PTPContainer.parse(encoded) {
    check(parsed.type == .command, "container type parse")
    check(parsed.code == PTP.Op.openSession.rawValue, "container code parse")
    check(parsed.transactionID == 7, "transaction ID parse")
    check(parsed.responseParams() == [1], "params parse")
} else {
    check(false, "container parse")
}

// Streaming header for >4 GiB payloads
let bigHeader = PTPContainer.header(type: .data, code: PTP.Op.sendObject.rawValue, transactionID: 9, payloadSize: 5 << 30)
check(Array(bigHeader.prefix(4)) == [0xFF, 0xFF, 0xFF, 0xFF], "length overflow marker")

// Truncated container must throw, not crash
check((try? PTPContainer.parse(Data([1, 2, 3]))) == nil, "truncated container rejected")

print("== Datasets ==")

// ObjectInfo round-trip through our own dataset builder
let dataset = MTPObjectInfo.makeDataset(
    storageID: 0x10001, parentHandle: 42, filename: "IMG_0001.jpg",
    size: 1_234_567, isFolder: false, modified: Date(timeIntervalSince1970: 1_700_000_000)
)
if let info = try? MTPObjectInfo.parse(dataset, handle: 99) {
    check(info.storageID == 0x10001, "dataset storageID")
    check(info.parentHandle == 42, "dataset parent")
    check(info.filename == "IMG_0001.jpg", "dataset filename")
    check(info.compressedSize == 1_234_567, "dataset size")
    check(!info.isFolder, "dataset file format")
    check(info.dateModified != nil, "dataset modified date")
} else {
    check(false, "ObjectInfo parse")
}

let folderSet = MTPObjectInfo.makeDataset(
    storageID: 1, parentHandle: PTP.rootParentHandle, filename: "DCIM",
    size: 0, isFolder: true, modified: nil
)
if let folder = try? MTPObjectInfo.parse(folderSet, handle: 1) {
    check(folder.isFolder, "folder format code")
} else {
    check(false, "folder dataset parse")
}

// >4 GiB sentinel
let bigSet = MTPObjectInfo.makeDataset(
    storageID: 1, parentHandle: 0, filename: "movie.mkv",
    size: 6 << 30, isFolder: false, modified: nil
)
if let big = try? MTPObjectInfo.parse(bigSet, handle: 2) {
    check(big.sizeNeedsPropQuery, "large file size sentinel")
} else {
    check(false, "large dataset parse")
}

print("== Error mapping ==")
check(MTPError(.response(.storeFull)).posixCode == ENOSPC, "storeFull -> ENOSPC")
check(MTPError(.response(.accessDenied)).posixCode == EACCES, "accessDenied -> EACCES")
check(MTPError(.deviceGone).posixCode == ENXIO, "deviceGone -> ENXIO")
check(MTPError(.deviceBusy("x")).posixCode == EBUSY, "busy -> EBUSY")

print("== Device identity ==")
let ref = MTPDeviceRef(serial: "ABC123", name: "Pixel", vendorID: 0x18D1, productID: 0x4EE1, locationID: 0x14200000)
check(ref.mtpURL.absoluteString == "mtp://ABC123", "URL from serial")
let noSerial = MTPDeviceRef(serial: "", name: "Mystery", vendorID: 0x18D1, productID: 0x4EE1, locationID: 0x14200000)
check(noSerial.urlHost == "18d1.4ee1.14200000", "URL fallback identity")


// MARK: - DavKit checks (HTTP-level, in-memory backend, no mount needed)

func syncHTTP(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil) -> (status: Int, body: Data, headers: [AnyHashable: Any]) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    final class Box: @unchecked Sendable { var out: (Int, Data, [AnyHashable: Any]) = (0, Data(), [:]) }
    let box = Box()
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        let http = response as? HTTPURLResponse
        box.out = (http?.statusCode ?? 0, data ?? Data(), http?.allHeaderFields ?? [:])
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return box.out
}

print("== DavKit server ==")

let davBackend = InMemoryBackend()
let davSeedSemaphore = DispatchSemaphore(value: 0)
Task.detached {
    await davBackend.seed(path: ["Storage"], data: nil)
    await davBackend.seed(path: ["Storage", "docs"], data: nil)
    await davBackend.seed(path: ["Storage", "docs", "a.txt"], data: Data("0123456789".utf8))
    davSeedSemaphore.signal()
}
davSeedSemaphore.wait()

let davServer = DavServer(backend: davBackend)
do {
    try davServer.start()
    check(davServer.port > 0, "server bound to ephemeral port")
} catch {
    check(false, "server start failed: \(error)")
}
let base = davServer.url

let options = syncHTTP("OPTIONS", base)
check(options.status == 200, "OPTIONS 200")
check((options.headers["Dav"] as? String ?? options.headers["DAV"] as? String ?? "").contains("2"), "DAV class 2 advertised")

let propfindRoot = syncHTTP("PROPFIND", base, headers: ["Depth": "1"])
check(propfindRoot.status == 207, "PROPFIND root 207")
let rootXML = String(decoding: propfindRoot.body, as: UTF8.self)
check(rootXML.contains("Storage"), "PROPFIND lists Storage")
check(rootXML.contains("quota-available-bytes"), "quota props on root")

let fileURL = base.appendingPathComponent("Storage/docs/a.txt")
let getFull = syncHTTP("GET", fileURL)
check(getFull.status == 200 && getFull.body == Data("0123456789".utf8), "GET full contents")

let getRange = syncHTTP("GET", fileURL, headers: ["Range": "bytes=2-5"])
check(getRange.status == 206 && getRange.body == Data("2345".utf8), "GET range 2-5")

let putURL = base.appendingPathComponent("Storage/docs/new.bin")
let putBody = Data((0..<100_000).map { UInt8($0 & 0xFF) })
let put = syncHTTP("PUT", putURL, body: putBody)
check(put.status == 201, "PUT new file 201")
let getBack = syncHTTP("GET", putURL)
check(getBack.body == putBody, "PUT/GET round-trip (100 KB)")
let putAgain = syncHTTP("PUT", putURL, body: Data("x".utf8))
check(putAgain.status == 204, "PUT overwrite 204")

let mkcol = syncHTTP("MKCOL", base.appendingPathComponent("Storage/newdir"))
check(mkcol.status == 201, "MKCOL 201")

var moveHeaders = ["Destination": base.appendingPathComponent("Storage/newdir/moved.bin").absoluteString]
let move = syncHTTP("MOVE", putURL, headers: moveHeaders)
check(move.status == 201, "MOVE 201")
check(syncHTTP("GET", putURL).status == 404, "source gone after MOVE")
check(syncHTTP("GET", base.appendingPathComponent("Storage/newdir/moved.bin")).status == 200, "destination exists after MOVE")

let lock = syncHTTP("LOCK", fileURL, body: Data("<lockinfo/>".utf8))
check(lock.status == 200 && String(decoding: lock.body, as: UTF8.self).contains("locktoken"), "LOCK fake token")
check(syncHTTP("UNLOCK", fileURL).status == 204, "UNLOCK 204")

let delete = syncHTTP("DELETE", base.appendingPathComponent("Storage/newdir/moved.bin"))
check(delete.status == 204, "DELETE 204")
check(syncHTTP("GET", base.appendingPathComponent("Storage/newdir/moved.bin")).status == 404, "deleted file 404")

let wrongToken = syncHTTP("PROPFIND", URL(string: "http://127.0.0.1:\(davServer.port)/wrong-token/")!, headers: ["Depth": "0"])
check(wrongToken.status == 404, "unknown token rejected")

davServer.stop()

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
