use live_sidestep_protocol::{Command, MAX_MESSAGE_BYTES, QUEUE_CAPACITY, decode};
use serde::Serialize;
use serde_json::Value;
use std::io::{self, BufRead, Write};
use std::sync::mpsc;
use std::time::Duration;

pub enum Incoming {
    Command(Command),
    Invalid(String),
    Eof,
}

struct Frame {
    bytes: Vec<u8>,
    terminal: bool,
}

#[derive(Clone)]
pub struct Output(mpsc::SyncSender<Frame>);

struct BoundedFrame(Vec<u8>);

impl Write for BoundedFrame {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > MAX_MESSAGE_BYTES.saturating_sub(self.0.len()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "native response exceeds 1 MiB",
            ));
        }
        self.0.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Output {
    pub fn start() -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Frame>(64);
        std::thread::spawn(move || {
            let stdout = io::stdout();
            let mut writer = stdout.lock();
            while let Ok(frame) = receiver.recv() {
                if writer.write_all(&frame.bytes).is_err()
                    || writer.write_all(b"\n").is_err()
                    || writer.flush().is_err()
                {
                    std::process::exit(2);
                }
                if frame.terminal {
                    std::process::exit(0);
                }
            }
        });
        Self(sender)
    }

    pub fn send(&self, message: Value) {
        self.enqueue(&message, false);
    }

    pub fn inspection(&self, request: u64, message: &impl Serialize) {
        let mut frame = BoundedFrame(Vec::with_capacity(4096));
        if serde_json::to_writer(&mut frame, message).is_err() {
            self.send(serde_json::json!({
                "type": "inspection_error", "request": request, "reason": "inspection exceeds 1 MiB"
            }));
        } else {
            self.send_frame(Frame {
                bytes: frame.0,
                terminal: false,
            });
        }
    }

    pub fn close(&self, reason: &str) {
        self.enqueue(&serde_json::json!({"type":"closed", "reason":reason}), true);
        // A peer that stopped reading cannot keep a closed window's process
        // alive. The writer flush and watchdog never wait on AppKit's thread.
        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(2));
            std::process::exit(0);
        });
    }

    fn enqueue(&self, message: &impl Serialize, terminal: bool) {
        let mut frame = BoundedFrame(Vec::with_capacity(256));
        if serde_json::to_writer(&mut frame, message).is_err() {
            std::process::exit(2);
        }
        self.send_frame(Frame {
            bytes: frame.0,
            terminal,
        });
    }

    fn send_frame(&self, frame: Frame) {
        // Overflow is explicit host death, not dropped actions or a blocking
        // send on the native UI thread.
        if self.0.try_send(frame).is_err() {
            std::process::exit(2);
        }
    }
}

pub fn start_input() -> mpsc::Receiver<Incoming> {
    let (sender, receiver) = mpsc::sync_channel(QUEUE_CAPACITY);
    std::thread::spawn(move || read_input(io::stdin().lock(), sender));
    receiver
}

fn read_input(mut reader: impl BufRead, sender: mpsc::SyncSender<Incoming>) {
    let mut bytes = Vec::with_capacity(4096);
    loop {
        bytes.clear();
        let mut oversized = false;
        let mut eof = false;
        loop {
            let buffer = match reader.fill_buf() {
                Ok(buffer) => buffer,
                Err(error) => {
                    let _ = sender.send(Incoming::Invalid(error.to_string()));
                    let _ = sender.send(Incoming::Eof);
                    return;
                }
            };
            if buffer.is_empty() {
                eof = true;
                break;
            }
            let newline = buffer.iter().position(|byte| *byte == b'\n');
            let payload = newline.unwrap_or(buffer.len());
            if !oversized {
                if payload > MAX_MESSAGE_BYTES.saturating_sub(bytes.len()) {
                    oversized = true;
                    bytes.clear();
                } else {
                    bytes.extend_from_slice(&buffer[..payload]);
                }
            }
            reader.consume(payload + usize::from(newline.is_some()));
            if newline.is_some() {
                break;
            }
        }
        if !bytes.is_empty() || oversized || !eof {
            let incoming = if oversized {
                Incoming::Invalid("message exceeds 1 MiB".into())
            } else if eof {
                Incoming::Invalid("unterminated command frame".into())
            } else {
                match decode(&bytes) {
                    Ok(command) => Incoming::Command(command),
                    Err(reason) => Incoming::Invalid(reason),
                }
            };
            if sender.send(incoming).is_err() {
                return;
            }
        }
        if eof {
            let _ = sender.send(Incoming::Eof);
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn frames(bytes: Vec<u8>) -> Vec<Incoming> {
        let (sender, receiver) = mpsc::sync_channel(8);
        read_input(Cursor::new(bytes), sender);
        receiver.into_iter().collect()
    }

    #[test]
    fn exact_limit_and_oversize_frames_do_not_desynchronize_successors() {
        let command = br#"{"type":"inspect","request":7}"#;
        let mut bytes = command.to_vec();
        bytes.resize(MAX_MESSAGE_BYTES, b' ');
        bytes.push(b'\n');
        bytes.extend(std::iter::repeat_n(b'x', MAX_MESSAGE_BYTES + 1));
        bytes.push(b'\n');
        bytes.extend_from_slice(b"{\"type\":\"shutdown\"}\n");
        let mut received = frames(bytes).into_iter();
        assert!(matches!(
            received.next(),
            Some(Incoming::Command(Command::Inspect { request: 7 }))
        ));
        assert!(matches!(received.next(), Some(Incoming::Invalid(_))));
        assert!(matches!(
            received.next(),
            Some(Incoming::Command(Command::Shutdown))
        ));
        assert!(matches!(received.next(), Some(Incoming::Eof)));
        assert!(received.next().is_none());
    }

    #[test]
    fn eof_does_not_accept_an_unterminated_command() {
        let received = frames(b"{\"type\":\"shutdown\"}".to_vec());
        assert!(matches!(
            &received[..],
            [Incoming::Invalid(_), Incoming::Eof]
        ));
    }

    #[test]
    fn output_serialization_stops_at_the_byte_limit() {
        let mut frame = BoundedFrame(Vec::new());
        frame.write_all(&vec![b'x'; MAX_MESSAGE_BYTES]).unwrap();
        assert!(frame.write_all(b"x").is_err());
        assert_eq!(frame.0.len(), MAX_MESSAGE_BYTES);
    }
}
