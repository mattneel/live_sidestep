use live_sidestep_protocol::{MAX_MESSAGE_BYTES, QUEUE_CAPACITY, decode};
use parking_lot::{Condvar, Mutex};
use rustler::types::map::MapIterator;
use rustler::{
    Atom, Binary, Encoder, Env, LocalPid, Monitor, OwnedBinary, OwnedEnv, Resource, ResourceArc,
    Term,
};
use std::collections::VecDeque;
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;

const MAILBOX_CAPACITY: usize = 64;
type CommandQueue = Arc<(Mutex<VecDeque<Vec<u8>>>, Condvar)>;
type Credits = Arc<(Mutex<usize>, Condvar)>;

mod atoms {
    rustler::atoms! { ok, error, busy, closed, live_sidestep_native }
}

struct Bridge {
    queue: CommandQueue,
    credits: Credits,
    child: Arc<Mutex<Child>>,
    closed: Arc<AtomicBool>,
    threads: Mutex<Vec<JoinHandle<()>>>,
}

impl Bridge {
    // Resource drop/owner death only signal teardown; explicit close joins on DirtyIo.
    fn stop(&self) {
        self.closed.store(true, Ordering::Release);
        {
            let mut queue = self.queue.0.lock();
            queue.clear();
            self.queue.1.notify_all();
        }
        {
            let _credits = self.credits.0.lock();
            self.credits.1.notify_all();
        }
        if let Some(mut child) = self.child.try_lock() {
            let _ = child.kill();
        }
    }

    fn shutdown(&self) {
        self.stop();
        for thread in self.threads.lock().drain(..) {
            let _ = thread.join();
        }
        let _ = self.child.lock().wait();
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        self.stop();
    }
}

#[rustler::resource_impl]
impl Resource for Bridge {
    fn down(&self, _env: Env<'_>, _pid: LocalPid, _monitor: Monitor) {
        self.stop();
    }
}

fn deliver(environment: &mut OwnedEnv, owner: &LocalPid, id: u64, bytes: &[u8]) -> bool {
    environment
        .send_and_clear(owner, |env| {
            let Some(mut binary) = OwnedBinary::new(bytes.len()) else {
                return (
                    atoms::live_sidestep_native(),
                    id,
                    "{\"type\":\"closed\",\"reason\":\"allocation failed\"}",
                )
                    .encode(env);
            };
            binary.as_mut_slice().copy_from_slice(bytes);
            (atoms::live_sidestep_native(), id, binary.release(env)).encode(env)
        })
        .is_ok()
}

fn reserve(credits: &Credits, closed: &AtomicBool) -> bool {
    let mut count = credits.0.lock();
    while *count >= MAILBOX_CAPACITY && !closed.load(Ordering::Acquire) {
        credits.1.wait(&mut count);
    }
    if closed.load(Ordering::Acquire) {
        return false;
    }
    *count += 1;
    true
}

fn read_frame(reader: &mut impl BufRead, buffer: &mut Vec<u8>) -> std::io::Result<bool> {
    buffer.clear();
    let count = reader
        .take((MAX_MESSAGE_BYTES + 1) as u64)
        .read_until(b'\n', buffer)?;
    if count == 0 {
        return Ok(false);
    }
    if buffer.last() != Some(&b'\n') {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "unterminated or oversized native frame",
        ));
    }
    buffer.pop();
    Ok(true)
}

fn write_commands(
    queue: CommandQueue,
    credits: Credits,
    closed: Arc<AtomicBool>,
    child: Arc<Mutex<Child>>,
    mut stdin: impl Write,
) {
    loop {
        let message = {
            let mut pending = queue.0.lock();
            while pending.is_empty() && !closed.load(Ordering::Acquire) {
                queue.1.wait(&mut pending);
            }
            if closed.load(Ordering::Acquire) {
                break;
            }
            let Some(message) = pending.pop_front() else {
                break;
            };
            message
        };
        if stdin
            .write_all(&message)
            .and_then(|_| stdin.write_all(b"\n"))
            .and_then(|_| stdin.flush())
            .is_err()
        {
            closed.store(true, Ordering::Release);
            let _ = child.lock().kill();
            let _credits = credits.0.lock();
            credits.1.notify_all();
            break;
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_native<'a>(
    env: Env<'a>,
    executable: String,
    owner: LocalPid,
    id: u64,
    environment: MapIterator<'a>,
) -> Term<'a> {
    open_bridge(env, executable, owner, id, environment).encode(env)
}

fn open_bridge(
    env: Env<'_>,
    executable: String,
    owner: LocalPid,
    id: u64,
    environment: MapIterator<'_>,
) -> Result<ResourceArc<Bridge>, String> {
    // ERTS maintains its own environment; libc inheritance misses System.put_env
    // and resurrects variables removed with System.delete_env. Never mutate the
    // process-global environment from a NIF.
    let mut command = Command::new(executable);
    command.env_clear();
    for (key, value) in environment {
        let key: Binary<'_> = key.decode().map_err(|_| "invalid host environment key")?;
        let value: Binary<'_> = value
            .decode()
            .map_err(|_| "invalid host environment value")?;
        command.env(
            OsStr::from_bytes(key.as_slice()),
            OsStr::from_bytes(value.as_slice()),
        );
    }
    let mut child = command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|error| error.to_string())?;
    let stdin = child.stdin.take().expect("piped stdin");
    let stdout = child.stdout.take().expect("piped stdout");
    let bridge = ResourceArc::new(Bridge {
        queue: Arc::new((
            Mutex::new(VecDeque::with_capacity(QUEUE_CAPACITY)),
            Condvar::new(),
        )),
        credits: Arc::new((Mutex::new(0), Condvar::new())),
        child: Arc::new(Mutex::new(child)),
        closed: Arc::new(AtomicBool::new(false)),
        threads: Mutex::new(Vec::with_capacity(2)),
    });
    let queue = bridge.queue.clone();
    let credits = bridge.credits.clone();
    let closed = bridge.closed.clone();
    let child = bridge.child.clone();
    let writer = std::thread::Builder::new()
        .name("live-sidestep-writer".into())
        .spawn(move || write_commands(queue, credits, closed, child, stdin));
    match writer {
        Ok(thread) => bridge.threads.lock().push(thread),
        Err(error) => {
            bridge.shutdown();
            return Err(error.to_string());
        }
    }
    let child = bridge.child.clone();
    let closed = bridge.closed.clone();
    let queue = bridge.queue.clone();
    let credits = bridge.credits.clone();
    let reader = std::thread::Builder::new()
        .name("live-sidestep-events".into())
        .spawn(move || {
            let mut environment = OwnedEnv::new();
            let mut reader = BufReader::new(stdout);
            let mut line = Vec::new();
            while matches!(read_frame(&mut reader, &mut line), Ok(true)) {
                if !reserve(&credits, &closed) || !deliver(&mut environment, &owner, id, &line) {
                    break;
                }
            }
            closed.store(true, Ordering::Release);
            {
                let _pending = queue.0.lock();
                queue.1.notify_all();
            }
            {
                let _pending = credits.0.lock();
                credits.1.notify_all();
            }
            {
                let mut child = child.lock();
                let _ = child.kill();
                let _ = child.wait();
            }
            // One final lifecycle notification is outside credits, so a closed pipe always wakes the owner.
            deliver(
                &mut environment,
                &owner,
                id,
                b"{\"type\":\"closed\",\"reason\":\"host exited\"}",
            );
        });
    match reader {
        Ok(thread) => bridge.threads.lock().push(thread),
        Err(error) => {
            bridge.shutdown();
            return Err(error.to_string());
        }
    }
    if bridge.monitor(Some(env), &owner).is_none() {
        bridge.shutdown();
        return Err("cannot monitor host owner".into());
    }
    Ok(bridge)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn submit<'a>(env: Env<'a>, resource: ResourceArc<Bridge>, message: Binary<'a>) -> Term<'a> {
    if resource.closed.load(Ordering::Acquire) {
        return (atoms::error(), atoms::closed()).encode(env);
    }
    if let Err(reason) = decode(message.as_slice()) {
        return (atoms::error(), reason).encode(env);
    }
    let Some(mut queue) = resource.queue.0.try_lock() else {
        return (atoms::error(), atoms::busy()).encode(env);
    };
    if resource.closed.load(Ordering::Acquire) {
        return (atoms::error(), atoms::closed()).encode(env);
    }
    if queue.len() >= QUEUE_CAPACITY {
        return (atoms::error(), atoms::busy()).encode(env);
    }
    queue.push_back(message.as_slice().to_vec());
    resource.queue.1.notify_one();
    atoms::ok().encode(env)
}

#[rustler::nif]
fn ack(resource: ResourceArc<Bridge>) -> Atom {
    let mut count = resource.credits.0.lock();
    *count = count.saturating_sub(1);
    resource.credits.1.notify_one();
    atoms::ok()
}

#[rustler::nif(schedule = "DirtyIo")]
fn close(resource: ResourceArc<Bridge>) -> Atom {
    resource.shutdown();
    atoms::ok()
}

rustler::init!("Elixir.LiveSidestep.Native");

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, ErrorKind};
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn frame_payload_limit_includes_no_delimiter() {
        let mut bytes = vec![b'x'; MAX_MESSAGE_BYTES];
        bytes.push(b'\n');
        let mut input = Cursor::new(bytes);
        let mut frame = Vec::new();
        assert!(read_frame(&mut input, &mut frame).unwrap());
        assert_eq!(frame.len(), MAX_MESSAGE_BYTES);
        assert!(!read_frame(&mut input, &mut frame).unwrap());
        let mut oversized = vec![b'x'; MAX_MESSAGE_BYTES + 1];
        oversized.push(b'\n');
        assert_eq!(
            read_frame(&mut Cursor::new(oversized), &mut frame)
                .unwrap_err()
                .kind(),
            ErrorKind::InvalidData
        );
        assert_eq!(
            read_frame(&mut Cursor::new(b"partial"), &mut frame)
                .unwrap_err()
                .kind(),
            ErrorKind::InvalidData
        );
    }

    #[test]
    fn shutdown_releases_a_reader_waiting_for_mailbox_credit() {
        let credits = Arc::new((Mutex::new(MAILBOX_CAPACITY), Condvar::new()));
        let closed = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel();
        let c = credits.clone();
        let flag = closed.clone();
        let worker = std::thread::spawn(move || {
            tx.send(reserve(&c, &flag)).unwrap();
        });
        closed.store(true, Ordering::Release);
        let guard = credits.0.lock();
        credits.1.notify_all();
        drop(guard);
        assert!(!rx.recv_timeout(Duration::from_secs(1)).unwrap());
        worker.join().unwrap();
        assert_eq!(*credits.0.lock(), MAILBOX_CAPACITY);
    }
}
