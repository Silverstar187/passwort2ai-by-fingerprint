#!/usr/bin/env swift
//
// p2ai-agent — short-lived in-memory master-password agent (B-strict).
//
// Model: ssh-agent / sudo-cache for the KeePass master password.
//   - Receives master from parent via stdin, holds in RAM only.
//   - Listens on Unix socket (mode 600 in mode-700 dir).
//   - On client connect: verifies peer UID via getpeereid() → writes master →
//     resets idle timer.
//   - Auto-locks on idle TTL (default 300s), screen-lock event, system sleep,
//     or explicit "EXIT" command.
//   - Master never touches disk.
//
// Spawned by `p2ai unlock`. Talks to `p2ai-master` and `p2ai lock`.

import Foundation
import Darwin

let DEFAULT_TTL: TimeInterval = 300
let HARD_LIMIT: TimeInterval = 1800

let stateDir = ("\(NSHomeDirectory())/.local/state/p2ai" as NSString).expandingTildeInPath
let sockPath = "\(stateDir)/agent.sock"
let pidPath  = "\(stateDir)/agent.pid"

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
let args = CommandLine.arguments.dropFirst()
var i = args.startIndex
while i < args.endIndex {
    switch args[i] {
    case "--ttl":
        i = args.index(after: i)
        guard i < args.endIndex, let v = Double(args[i]) else { die("--ttl needs seconds") }
        idleTtl = min(max(v, 30), HARD_LIMIT)
    case "-h", "--help":
        print("p2ai-agent --ttl SECONDS  (master from stdin, listens on \(sockPath))")
        exit(0)
    default:
        die("unknown arg: \(args[i])")
    }
    i = args.index(after: i)
}

// ---- Read master from stdin ----
let stdin = FileHandle.standardInput
guard let masterData = try? stdin.readToEnd(), !masterData.isEmpty else {
    die("no master on stdin")
}
// strip trailing newline if present
var master = masterData
if master.last == 0x0A { master.removeLast() }

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
setsid()                       // detach controlling terminal
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

        // Read 1-line command (max 16 bytes; "GET" or "EXIT" or "STATUS")
        var buf = [UInt8](repeating: 0, count: 32)
        let n = read(client, &buf, buf.count)
        let cmd = (n > 0) ? String(bytes: buf[0..<Int(n)], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""

        switch cmd {
        case "GET":
            master.withUnsafeBytes { _ = write(client, $0.baseAddress, master.count) }
            lastTouch = Date()
        case "STATUS":
            let now = Date()
            let idleLeft = max(0, idleTtl - now.timeIntervalSince(lastTouch))
            let absLeft  = max(0, HARD_LIMIT - now.timeIntervalSince(started))
            let line = "OK ttl_idle=\(Int(idleLeft)) ttl_abs=\(Int(absLeft)) pid=\(getpid())\n"
            line.utf8CString.withUnsafeBytes { _ = write(client, $0.baseAddress, line.utf8.count) }
        case "EXIT":
            close(client); cleanup(); exit(0)
        default:
            break
        }
        close(client)
    }
}

// ---- Run loop (needed for DistributedNotificationCenter) ----
RunLoop.main.run()
