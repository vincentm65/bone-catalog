use std::collections::VecDeque;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

const MAX: usize = 4 * 1024 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(15);

fn read_frame<R: Read>(reader: &mut R) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0u8; 4];
    match reader.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_le_bytes(header) as usize;
    if len > MAX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "native message exceeds 4 MiB",
        ));
    }
    let mut body = vec![0u8; len];
    reader.read_exact(&mut body)?;
    Ok(Some(body))
}

fn write_frame<W: Write>(writer: &mut W, body: &[u8]) -> io::Result<()> {
    if body.len() > MAX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "response exceeds 4 MiB",
        ));
    }
    writer.write_all(&(body.len() as u32).to_le_bytes())?;
    writer.write_all(body)?;
    writer.flush()
}

fn socket_path() -> PathBuf {
    env::var_os("BONE_FIREFOX_DOM_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            env::var_os("XDG_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join("bone-firefox-dom.sock")
        })
}

fn socket_server(path: &Path) -> io::Result<UnixListener> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if !metadata.file_type().is_socket() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "socket path is not a socket",
            ));
        }
        fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)?;
    set_owner_only(path)?;
    Ok(listener)
}

fn set_owner_only(path: &Path) -> io::Result<()> {
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_mode(0o600);
    fs::set_permissions(path, permissions)
}

enum Event {
    Native(Vec<u8>),
    Socket(Vec<u8>, UnixStream),
}

fn spawn_stdin_reader(tx: Sender<Event>) {
    thread::spawn(move || {
        let mut input = io::stdin().lock();
        loop {
            match read_frame(&mut input) {
                Ok(Some(body)) => {
                    if tx.send(Event::Native(body)).is_err() {
                        break;
                    }
                }
                Ok(None) | Err(_) => break,
            }
        }
    });
}

fn spawn_socket_reader(listener: UnixListener, tx: Sender<Event>) {
    thread::spawn(move || {
        for accepted in listener.incoming() {
            let Ok(mut stream) = accepted else { continue };
            if stream.set_read_timeout(Some(IO_TIMEOUT)).is_err()
                || stream.set_write_timeout(Some(IO_TIMEOUT)).is_err()
            {
                continue;
            }
            match read_socket_frame(&mut stream) {
                Ok(body) => {
                    if tx.send(Event::Socket(body, stream)).is_err() {
                        break;
                    }
                }
                Err(_) => continue,
            }
        }
    });
}

fn read_socket_frame<R: Read>(reader: &mut R) -> io::Result<Vec<u8>> {
    let mut header = [0u8; 4];
    reader.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header) as usize;
    if len > MAX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "socket request exceeds 4 MiB",
        ));
    }
    let mut body = vec![0u8; len];
    reader.read_exact(&mut body)?;
    Ok(body)
}

fn write_socket_frame(stream: &mut UnixStream, body: &[u8]) -> io::Result<()> {
    if body.len() > MAX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "socket response exceeds 4 MiB",
        ));
    }
    stream.write_all(&(body.len() as u32).to_be_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}

fn run() -> io::Result<()> {
    let path = socket_path();
    let listener = socket_server(&path)?;
    let (tx, rx): (Sender<Event>, Receiver<Event>) = mpsc::channel();
    spawn_stdin_reader(tx.clone());
    spawn_socket_reader(listener, tx);
    let mut output = io::stdout().lock();
    let mut queue: VecDeque<(Vec<u8>, UnixStream)> = VecDeque::new();
    let mut pending: Option<(UnixStream, Instant)> = None;
    // Native messaging has one ordered stdout stream. If a timed-out request
    // eventually produces a reply, discard exactly that reply before sending
    // the next queued request; socket clients remain independently correlated
    // by their connection and are never given another client's response.
    let mut discard_late_native = false;

    loop {
        let wait = pending
            .as_ref()
            .map(|(_, deadline)| deadline.saturating_duration_since(Instant::now()))
            .unwrap_or(Duration::from_millis(100));
        let event = match rx.recv_timeout(wait) {
            Ok(event) => event,
            Err(RecvTimeoutError::Timeout) => {
                if let Some((mut stream, _)) = pending.take() {
                    let body = serde_json::json!({
                        "ok": false,
                        "error": {"code": "native_timeout", "message": "native request timed out"}
                    })
                    .to_string()
                    .into_bytes();
                    let _ = write_socket_frame(&mut stream, &body);
                    discard_late_native = true;
                }
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => break,
        };
        match event {
            Event::Socket(body, stream) => queue.push_back((body, stream)),
            Event::Native(body) => {
                if discard_late_native {
                    discard_late_native = false;
                } else if let Some((mut stream, _)) = pending.take() {
                    let _ = write_socket_frame(&mut stream, &body);
                }
            }
        }
        if pending.is_none() && !discard_late_native {
            if let Some((body, stream)) = queue.pop_front() {
                write_frame(&mut output, &body)?;
                pending = Some((stream, Instant::now() + IO_TIMEOUT));
            }
        }
    }
    let _ = fs::remove_file(path);
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        let _ = writeln!(io::stderr(), "bone-firefox-dom bridge: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn native_framing_remains_little_endian() {
        let mut input = Cursor::new([3, 0, 0, 0, b'a', b'b', b'c']);
        assert_eq!(read_frame(&mut input).unwrap(), Some(b"abc".to_vec()));
    }

    #[test]
    fn socket_framing_is_big_endian_and_reads_fragmented_body_exactly() {
        let mut input = Cursor::new([0, 0, 0, 5, b'h', b'e', b'l', b'l', b'o']);
        assert_eq!(read_socket_frame(&mut input).unwrap(), b"hello");
    }

    #[test]
    fn socket_frame_rejects_oversized_length_before_allocating() {
        let mut input = Cursor::new((MAX as u32 + 1).to_be_bytes());
        let error = read_socket_frame(&mut input).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn socket_writer_emits_big_endian_length() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        write_socket_frame(&mut writer, b"ok").unwrap();
        let mut bytes = [0; 6];
        reader.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, &[0, 0, 0, 2, b'o', b'k']);
    }
}
