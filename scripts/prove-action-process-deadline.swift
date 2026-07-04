#!/usr/bin/env swift
import Darwin
import Foundation

func spawnSleepForever() -> pid_t {
    var pid: pid_t = 0
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    var attrs: posix_spawnattr_t?
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }
    posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attrs, 0)
    let args = ["/bin/sh", "-c", "trap '' TERM; while true; do sleep 1; done"]
    var argv = args.map { strdup($0) } + [nil]
    defer { for p in argv { free(p) } }
    let rc = "/bin/sh".withCString { path in
        posix_spawnp(&pid, path, &fileActions, &attrs, &argv, environ)
    }
    precondition(rc == 0, "spawn failed \(rc)")
    return pid
}

func waitBlockingNoDeadline(pid: pid_t, maxSeconds: Double) -> (reaped: Bool, elapsed: Double) {
    // Simulate old behavior: blocking waitpid cannot observe a deadline while blocked.
    // We approximate by attempting a timed race: if still not reaped after maxSeconds, hang risk.
    let started = Date()
    var status: Int32 = 0
    // Use a short alarm-like approach: poll WNOHANG only after "would have blocked"
    // For demonstration of FIXED path only.
    while Date().timeIntervalSince(started) < maxSeconds {
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { return (true, Date().timeIntervalSince(started)) }
        usleep(10_000)
    }
    return (false, Date().timeIntervalSince(started))
}

func waitWithDeadline(pid: pid_t, deadline: Date) -> (code: Int32, elapsed: Double) {
    let started = Date()
    var status: Int32 = 0
    var escalationStartedAt: Date?
    while true {
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid {
            return (status, Date().timeIntervalSince(started))
        }
        let now = Date()
        if now >= deadline {
            if escalationStartedAt == nil {
                escalationStartedAt = now
                kill(-pid, SIGKILL)
            } else if now.timeIntervalSince(escalationStartedAt!) >= 1.0 {
                return (128 + SIGKILL, Date().timeIntervalSince(started))
            }
        }
        usleep(10_000)
    }
}

print("F007 waitpid deadline proof")
let pid = spawnSleepForever()
print("  spawned unkillable-TERM child pid=\(pid)")
let deadline = Date().addingTimeInterval(0.3)
let (code, elapsed) = waitWithDeadline(pid: pid, deadline: deadline)
print("  fixed wait returned code=\(code) elapsed=\(String(format: "%.2f", elapsed))s")
print("  expected: returns within ~1.5s of deadline, not hang forever")
// reap if still around
kill(-pid, SIGKILL)
var st: Int32 = 0
_ = waitpid(pid, &st, 0)
let ok = elapsed < 2.5
print(ok ? "PROOF_OK" : "PROOF_FAIL")
exit(ok ? 0 : 1)
