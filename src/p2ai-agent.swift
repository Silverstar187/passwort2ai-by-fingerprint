#!/usr/bin/env swift
//
// p2ai-agent — short-lived in-memory secret cache (master + per-entry).
//
//   p2ai-agent --mode session   [--ttl N]   (default)
//     - Reads master from stdin, holds it + entries in RAM.
//     - Touch-ID is only required to start the agent; subsequent fetches use
//       the cached master and (after first hit) the cached entry value.
//
//   p2ai-agent --mode per-entry [--ttl N]
//     - Does NOT cache the master. New entries always require a fresh
//       master (Touch-ID); already-fetched entries are cached and skip
//       Touch-ID until idle expires.
//     - No stdin needed at startup.
//
// Protocol (one command per connection, line-terminated):
//   GET                  → master (or MISS in per-entry mode)
//   GETENTRY <name>      → cached entry value or MISS
//   PUTENTRY <name>\n<value-bytes...>  → cache entry, replies "OK"
//                          (length-bytes prefix is implicit via close-on-finish:
//                           server reads until EOF after PUTENTRY <name>\n)
//   MODE                 → "session" | "per-entry"
//   STATUS               → "OK ttl_idle=N ttl_abs=N entries=N pid=N mode=X"
//   EXIT                 → cleanup + die
//
// Auto-locks on idle TTL, hard cap, screen-lock, screensaver, signals.

import Foundation
import Darwin

let DEFAULT_TTL: TimeInterval = 300
let HARD_LIMIT: TimeInterval = 1800

let stateDir = ("\(NSHomeDirectory())/.local/state/p2ai" as NSString).expandingTildeInPath
let sockPath = "\(stateDir)/agent.sock"
let pidPath  = "\(stateDir)/agent.pid"

enum AgentMode: String {
    case session    // master + entries cached
    case perEntry = "per-entry"  // entries only, master fetched fresh each new entry
}

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func ensureDir() {
    try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
}

func cleanup() {
    unlink(sockPath)
    unlink(pidPath)
}

// ---- Args ----
var idleTtl = DEFAULT_TTL
var mode: AgentMode = .session
let args = CommandLine.arguments.dropFirst()
var i = args.startIndex
while i < args.endIndex {
    switch args[i] {
    case "--ttl":
        i = args.index(after: i)
        guard i < args.endIndex, let v = Double(args[i]) else { die("--ttl needs seconds") }
        idleTtl = min(max(v, 30), HARD_LIMIT)
    case "--mode":
        i = args.index(after: i)
        guard i < args.endIndex, let m = AgentMode(rawValue: args[i]) else {
            die("--mode requires session|per-entry")
        }
        mode = m
    case "-h", "--help":
        print("p2ai-agent --mode session|per-entry [--ttl SECONDS]")
        exit(0)
    default:
        die("unknown arg: \(args[i])")
    }
    i = args.index(after: i)
}

// ---- Read master from stdin (session mode only) ----
var master: Data = Data()
if mode == .session {
    let stdin = FileHandle.standardInput
    guard let masterData = try? stdin.readToEnd(), !masterData.isEmpty else {
        die("no master on stdin (required for session mode)")
    }
    master = masterData
    if master.last == 0x0A { master.removeLast() }
}

// ---- Entry cache ----
// Lock-protected dict; Swift dispatch barrier covers concurrent access.
let cacheQueue = DispatchQueue(label: "p2ai.cache", attributes: .concurrent)
var entries: [String: Data] = [:]
func cachePut(_ key: String, _ val: Data) {
    cacheQueue.async(flags: .barrier) { entries[key] = val }
}
func cacheGet(_ key: String) -> Data? {
    var out: Data? = nil
    cacheQueue.sync { out = entries[key] }
    return out
}
func cacheCount() -> Int {
    var n = 0
    cacheQueue.sync { n = entries.count }
    return n
}

// ---- Single-instance: kill stale agent if any ----
ensureDir()
if let oldPidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
   let oldPid = Int32(oldPidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
   kill(oldPid, 0) == 0 {
    kill(oldPid, SIGTERM)
    usleep(150_000)
}
unlink(sockPath)
unlink(pidPath)

// ---- Bind Unix socket ----
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { die("socket: \(String(cString: strerror(errno)))") }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = sockPath.utf8CString
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
    die("socket path too long: \(sockPath)")
}
withUnsafeMutableBytes(of: &addr.sun_path) { dst in
    pathBytes.withUnsafeBufferPointer { src in
        dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: pathBytes.count))
    }
}

let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let bindRc = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.bind(fd, sa, addrLen)
    }
}
guard bindRc == 0 else { die("bind: \(String(cString: strerror(errno)))") }
chmod(sockPath, 0o600)
guard listen(fd, 8) == 0 else { die("listen: \(String(cString: strerror(errno)))") }

// No fork — Foundation marks fork() unavailable on macOS. Caller runs us
// with `&` and writes pid file from parent shell. We just listen.
setsid()
umask(0o077)
try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)

// ---- Idle timer + hard cap ----
let started = Date()
var lastTouch = Date()
let idleQueue = DispatchQueue(label: "p2ai.idle")
let idleTimer = DispatchSource.makeTimerSource(queue: idleQueue)
idleTimer.schedule(deadline: .now() + 1, repeating: 1)
idleTimer.setEventHandler {
    let now = Date()
    if now.timeIntervalSince(lastTouch) >= idleTtl ||
       now.timeIntervalSince(started)   >= HARD_LIMIT {
        cleanup()
        exit(0)
    }
}
idleTimer.resume()

// ---- Screen-lock + sleep auto-lock ----
let dnc = DistributedNotificationCenter.default()
let lockHandler: (Notification) -> Void = { _ in cleanup(); exit(0) }
dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: nil, using: lockHandler)
dnc.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: nil, using: lockHandler)

// ---- Signal handlers ----
signal(SIGTERM) { _ in cleanup(); exit(0) }
signal(SIGINT)  { _ in cleanup(); exit(0) }
signal(SIGHUP)  { _ in cleanup(); exit(0) }
signal(SIGPIPE, SIG_IGN)

// ---- Helpers ----
func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { buf in
        var written = 0
        let total = data.count
        while written < total {
            let n = write(fd, buf.baseAddress!.advanced(by: written), total - written)
            if n <= 0 { break }
            written += n
        }
    }
}

// Read one line (terminated by \n) from socket. Max 4096 bytes.
func readLine(_ fd: Int32) -> String? {
    var buf = [UInt8]()
    var c: UInt8 = 0
    while buf.count < 4096 {
        let n = read(fd, &c, 1)
        if n <= 0 { return nil }
        if c == 0x0A { break }
        buf.append(c)
    }
    return String(bytes: buf, encoding: .utf8)
}

// Read remaining bytes until EOF, max 1 MB.
func readToEof(_ fd: Int32) -> Data {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count < 1_048_576 {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    return data
}

// ---- Accept loop on background queue ----
let acceptQueue = DispatchQueue(label: "p2ai.accept")
acceptQueue.async {
    while true {
        let client = accept(fd, nil, nil)
        if client < 0 {
            if errno == EINTR { continue }
            cleanup(); exit(1)
        }

        // Verify peer is same UID
        var euid: uid_t = 0
        var egid: gid_t = 0
        if getpeereid(client, &euid, &egid) != 0 || euid != getuid() {
            close(client); continue
        }

        guard let line = readLine(client) else { close(client); continue }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let cmd = parts.isEmpty ? "" : String(parts[0])
        let arg = parts.count > 1 ? String(parts[1]) : ""

        switch cmd {
        case "GET":
            if mode == .session && !master.isEmpty {
                writeAll(client, master)
                lastTouch = Date()
            } else {
                writeAll(client, "MISS\n".data(using: .utf8)!)
            }

        case "GETENTRY":
            if let v = cacheGet(arg) {
                writeAll(client, v)
                lastTouch = Date()
            } else {
                writeAll(client, "MISS\n".data(using: .utf8)!)
            }

        case "PUTENTRY":
            // Read remainder of socket as the value bytes
            let val = readToEof(client)
            if !arg.isEmpty && !val.isEmpty {
                cachePut(arg, val)
                writeAll(client, "OK\n".data(using: .utf8)!)
                lastTouch = Date()
            } else {
                writeAll(client, "ERR empty\n".data(using: .utf8)!)
            }

        case "MODE":
            writeAll(client, "\(mode.rawValue)\n".data(using: .utf8)!)

        case "STATUS":
            let now = Date()
            let idleLeft = max(0, idleTtl - now.timeIntervalSince(lastTouch))
            let absLeft  = max(0, HARD_LIMIT - now.timeIntervalSince(started))
            let line = "OK ttl_idle=\(Int(idleLeft)) ttl_abs=\(Int(absLeft)) entries=\(cacheCount()) pid=\(getpid()) mode=\(mode.rawValue)\n"
            writeAll(client, line.data(using: .utf8)!)

        case "EXIT":
            close(client); cleanup(); exit(0)

        default:
            writeAll(client, "ERR unknown\n".data(using: .utf8)!)
        }
        close(client)
    }
}

// ---- Run loop (needed for DistributedNotificationCenter) ----
RunLoop.main.run()
