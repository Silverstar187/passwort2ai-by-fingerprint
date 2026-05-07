#!/usr/bin/env swift
//
// p2ai-master — Touch-ID-gated KeePass master password.
//
//   p2ai-master setup                       Prompt + store master in keychain
//   p2ai-master                             Touch-ID, master to stdout
//   p2ai-master --pbcopy                    Touch-ID, master to clipboard
//   p2ai-master --reason "fetch 'Foo'"      Custom Touch-ID dialog reason
//   p2ai-master remove                      Delete keychain item
//
// Agent integration: if a running p2ai-agent socket is present, master is
// fetched from the agent (RAM cache) without a Touch-ID prompt. Otherwise the
// LAContext biometry prompt fires, master read from keychain.

import Foundation
import Security
import LocalAuthentication
import Darwin

let SERVICE = "passwort2ai-master"
let ACCOUNT = NSUserName()
let SOCK_PATH = ("\(NSHomeDirectory())/.local/state/p2ai/agent.sock" as NSString).expandingTildeInPath

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

// ---- Agent client: GET master via Unix socket if agent is running ----
func tryAgentFetch() -> String? {
    var st = stat()
    guard stat(SOCK_PATH, &st) == 0 else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = SOCK_PATH.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        pathBytes.withUnsafeBufferPointer { src in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: pathBytes.count))
        }
    }
    let connRc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connRc == 0 else { return nil }

    let cmd = "GET\n"
    cmd.utf8CString.withUnsafeBytes { _ = write(fd, $0.baseAddress, cmd.utf8.count) }

    var buf = [UInt8](repeating: 0, count: 4096)
    var collected = Data()
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        collected.append(buf, count: n)
        if collected.count > 65536 { break }
    }
    guard !collected.isEmpty else { return nil }
    return String(data: collected, encoding: .utf8)
}

func requireAuth(reason: String) {
    let ctx = LAContext()
    var err: NSError?
    var policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
    if !ctx.canEvaluatePolicy(policy, error: &err) {
        FileHandle.standardError.write("Biometry unavailable (\(err?.localizedDescription ?? "?")) — falling back to password\n".data(using: .utf8)!)
        policy = .deviceOwnerAuthentication
        var err2: NSError?
        guard ctx.canEvaluatePolicy(policy, error: &err2) else {
            die("No auth available: \(err2?.localizedDescription ?? "?")")
        }
    }
    let sema = DispatchSemaphore(value: 0)
    var ok = false
    var evalErr: Error?
    ctx.evaluatePolicy(policy, localizedReason: reason) { success, e in
        ok = success; evalErr = e; sema.signal()
    }
    sema.wait()
    guard ok else { die("Auth failed: \(evalErr?.localizedDescription ?? "cancelled")", 130) }
}

func storeMaster() {
    guard isatty(fileno(stdin)) != 0 else {
        die("No TTY — run in real terminal (Terminal.app / iTerm).")
    }
    FileHandle.standardError.write("""

    ┌─ Step 1 of 2: Master Password ────────────────────────────────┐
    │  Choose a strong password for your password database.         │
    │  This is the ONE password you need to remember.               │
    └───────────────────────────────────────────────────────────────┘

    """.data(using: .utf8)!)

    guard let cstr = getpass("  Master password (hidden): ") else { die("getpass null") }
    let pw = String(cString: cstr)
    guard !pw.isEmpty else { die("Empty input — aborted") }
    guard let cstr2 = getpass("  Repeat:                   ") else { die("getpass null") }
    let pw2 = String(cString: cstr2)
    guard pw == pw2 else { die("Passwords don't match — aborted") }

    let del: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SERVICE,
        kSecAttrAccount as String: ACCOUNT,
    ]
    SecItemDelete(del as CFDictionary)

    FileHandle.standardError.write("""

    ┌─ Step 2 of 2: Keychain Permission ────────────────────────────┐
    │  macOS will now ask for permission to save your password.     │
    │                                                               │
    │  → Click "Always Allow" so Touch ID works without re-asking. │
    └───────────────────────────────────────────────────────────────┘

    """.data(using: .utf8)!)

    // -A: allow access from any app without warning. Modern macOS does not
    // reliably honor -T <path> for unsigned Swift scripts (signature-based
    // identity check, not path). Without -A every fetch shows a PW prompt
    // and defeats the Touch-ID UX. The actual security gate is the in-process
    // LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics) call.
    let task = Process()
    task.launchPath = "/usr/bin/security"
    task.arguments = [
        "add-generic-password",
        "-s", SERVICE,
        "-a", ACCOUNT,
        "-w", pw,
        "-U",
        "-A",
        "-l", "Passwort2AI master (Touch-ID gated)",
        "-D", "KeePass master password",
    ]
    let errPipe = Pipe()
    task.standardError = errPipe
    do { try task.run() } catch { die("security launch failed: \(error)") }
    task.waitUntilExit()
    let stderrOut = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard task.terminationStatus == 0 else {
        die("security add-generic-password failed (\(task.terminationStatus)): \(stderrOut)")
    }
    FileHandle.standardError.write("  ✓ Stored in Keychain.\n\n".data(using: .utf8)!)
}

func removeMaster() {
    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SERVICE,
        kSecAttrAccount as String: ACCOUNT,
    ]
    let status = SecItemDelete(q as CFDictionary)
    if status == errSecSuccess { print("Removed.") }
    else if status == errSecItemNotFound { print("Nothing to remove.") }
    else { die("SecItemDelete failed: \(status)") }
}

func pbcopy(_ s: String) {
    let p = Process()
    p.launchPath = "/usr/bin/pbcopy"
    let pipe = Pipe()
    p.standardInput = pipe
    do { try p.run() } catch { die("pbcopy launch failed: \(error)") }
    pipe.fileHandleForWriting.write(s.data(using: .utf8)!)
    try? pipe.fileHandleForWriting.close()
    p.waitUntilExit()
}

func fetchMaster(toClipboard: Bool, reason: String, allowAgent: Bool) {
    // Agent fast-path. tryAgentFetch returns "MISS\n" in per-entry mode (master
    // not cached) — must NOT pass that through as the master, or keepassxc-cli
    // gets "MISS" as the password and fails with "invalid credentials".
    if allowAgent, let raw = tryAgentFetch() {
        let pw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pw.isEmpty && pw != "MISS" {
            if toClipboard { pbcopy(pw); FileHandle.standardError.write("Master in clipboard (agent).\n".data(using: .utf8)!) }
            else { print(pw) }
            return
        }
        // Fall through to Keychain + Touch-ID
    }

    let probe: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SERVICE,
        kSecAttrAccount as String: ACCOUNT,
        kSecReturnData as String: false,
    ]
    var probeRes: AnyObject?
    let probeStatus = SecItemCopyMatching(probe as CFDictionary, &probeRes)
    if probeStatus == errSecItemNotFound { die("Not stored. Run `p2ai-master setup`.") }

    requireAuth(reason: reason)

    let q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: SERVICE,
        kSecAttrAccount as String: ACCOUNT,
        kSecReturnData as String: true,
    ]
    var item: AnyObject?
    let status = SecItemCopyMatching(q as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data, let pw = String(data: data, encoding: .utf8) else {
        die("Fetch failed: \(status) (\(SecCopyErrorMessageString(status, nil) as String? ?? "?"))")
    }
    if toClipboard { pbcopy(pw); FileHandle.standardError.write("Master in clipboard.\n".data(using: .utf8)!) }
    else { print(pw) }
}

// ---- Arg parsing ----
var mode: String? = nil
var toClipboard = false
var reason = "unlock KeePass master"
var allowAgent = true

let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "setup", "remove", "rm":
        mode = a
    case "--pbcopy", "-c":
        toClipboard = true
    case "--reason", "-r":
        i += 1
        guard i < args.count else { die("--reason needs value") }
        reason = args[i]
    case "--no-agent":
        allowAgent = false
    case "-h", "--help":
        print("""
        p2ai-master — Touch-ID-gated KeePass master password.
          p2ai-master                              master to stdout (agent-aware)
          p2ai-master --pbcopy                     master to clipboard
          p2ai-master --reason "fetch 'Foo'"       custom Touch-ID dialog reason
          p2ai-master --no-agent                   force Touch-ID, ignore agent
          p2ai-master setup                        one-time enrollment
          p2ai-master remove                       delete keychain item
        """)
        exit(0)
    default:
        die("unknown arg: \(a)  (try -h)")
    }
    i += 1
}

switch mode {
case "setup":           storeMaster()
case "remove", "rm":    removeMaster()
default:                fetchMaster(toClipboard: toClipboard, reason: reason, allowAgent: allowAgent)
}
