// Regression test for the shell-death crash: the launcher runs the daemon under
// `setpriv --pdeathsig TERM`, so when omarchy-shell dies the daemon receives
// SIGTERM with its stdout/stderr pipes already readend-dead. The daemon must shut
// down cleanly (exit 0, management socket unlinked) — writing the stopped event
// or the panic hook must not turn EPIPE into a panic that aborts the process.

use std::io::{BufRead, BufReader};
use std::net::TcpListener;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::time::{Duration, Instant};

const PORT_CANDIDATES: usize = 8;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(10);

fn free_port() -> u16 {
    TcpListener::bind(("127.0.0.1", 0))
        .expect("bind an ephemeral port")
        .local_addr()
        .expect("bind local address")
        .port()
}

#[test]
fn sigterm_after_streams_die_shuts_down_cleanly() {
    let temp = tempfile::tempdir().expect("create temp directory");

    for attempt in 1..=PORT_CANDIDATES {
        let port = free_port();
        let socket_path = temp.path().join(format!("m{attempt}.sock"));
        let state_dir = temp.path().join(format!("state{attempt}"));
        std::fs::create_dir_all(&state_dir).expect("create state directory");
        let child = Command::new(env!("CARGO_BIN_EXE_localsend-controller"))
            .arg("--socket")
            .arg(&socket_path)
            .arg("daemon")
            .arg("--port")
            .arg(port.to_string())
            .arg("--state-directory")
            .arg(&state_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn the daemon");
        // Takes ownership; on a startup failure (port clash) it has reaped the
        // child already, so the next attempt spawns a fresh one.
        if let Some(status) = shutdown_scenario(child) {
            assert!(
                status.success(),
                "expected clean exit 0 after SIGTERM with both streams dead, got {status}"
            );
            assert!(
                !socket_path.exists(),
                "management socket survived the shutdown; the clean path did not run"
            );
            return;
        }
    }

    panic!("the daemon could not start on any candidate port; nothing asserted");
}

fn shutdown_scenario(mut child: Child) -> Option<ExitStatus> {
    // One thread owns the stdout read end: it waits for the startup "ready"
    // event, then exits so both pipes die mid-life, exactly like the launching
    // shell going away. The stderr read end has no reader at all.
    let stdout = child.stdout.take().expect("pipe stdout");
    let (line_tx, line_rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        let _ = reader.read_line(&mut line);
        let _ = line_tx.send(line);
        // The reader drops when this thread exits; both streams go dead.
    });

    let mut ready = false;
    let start = Instant::now();
    while start.elapsed() < STARTUP_TIMEOUT {
        match line_rx.recv_timeout(Duration::from_secs(1)) {
            Ok(line) => {
                if line.contains("\"event\":\"ready\"") {
                    ready = true;
                    break;
                }
            }
            // Child exited while starting up; the caller treats this as a port
            // clash and retries on another port.
            Err(RecvTimeoutError::Disconnected) => break,
            Err(RecvTimeoutError::Timeout) => {}
        }
    }
    if !ready {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    }
    drop(child.stderr.take());
    let child_pid = child.id();
    let (status_tx, status_rx) = mpsc::channel::<ExitStatus>();
    std::thread::spawn(move || {
        let _ = status_tx.send(child.wait().expect("wait for daemon"));
    });
    // Under setpriv --pdeathsig the kernel delivers this same SIGTERM when the
    // parent dies; the child sees an identical shutdown path either way.
    unsafe {
        libc::kill(child_pid as libc::pid_t, libc::SIGTERM);
    }
    match status_rx.recv_timeout(SHUTDOWN_TIMEOUT) {
        Ok(status) => Some(status),
        Err(_) => {
            // Shutdown hang: keep the tree clean even when the test fails.
            unsafe {
                libc::kill(child_pid as libc::pid_t, libc::SIGKILL);
            }
            let _ = status_rx.recv_timeout(SHUTDOWN_TIMEOUT);
            panic!("daemon did not shut down within {SHUTDOWN_TIMEOUT:?} after SIGTERM");
        }
    }
}
