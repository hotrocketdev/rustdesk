use crate::hbbs_http::create_http_client_with_url;
use bytes::Bytes;
use hbb_common::{
    bail,
    config::{self, Config},
    lazy_static, log, ResultType,
};
use reqwest::blocking::{Body, Client};
use scrap::record::RecordState;
use serde::Serialize;
use serde_json::Map;
use std::{
    collections::HashSet,
    fs::File,
    io::{prelude::*, SeekFrom},
    sync::{mpsc::Receiver, Mutex},
    time::{Duration, Instant},
};

const MAX_HEADER_LEN: usize = 1024;
const SHOULD_SEND_TIME: Duration = Duration::from_secs(1);
const SHOULD_SEND_SIZE: u64 = 1024 * 1024;
/// Upload progress is kept next to the recording as `<file>.upload`, so an upload cut short
/// (crash, kill, network) can be finished on the next start.
const PROGRESS_EXT: &str = ".upload";
/// Upload is off unless this option is "Y". Never default it on: production storage must be
/// confirmed before a build ships with it enabled.
pub const OPTION_ALLOW_UPLOAD_RECORDINGS: &str = "allow-upload-recordings";

lazy_static::lazy_static! {
    // Files an upload thread in this process is working on; the restart scan must skip them.
    static ref ACTIVE: Mutex<HashSet<String>> = Default::default();
}

pub fn is_enable() -> bool {
    config::option2bool(
        OPTION_ALLOW_UPLOAD_RECORDINGS,
        &Config::get_option(OPTION_ALLOW_UPLOAD_RECORDINGS),
    )
}

/// Starts an upload thread and returns the recorder's sender, or `None` when upload is off.
pub fn start(dir: String) -> Option<std::sync::mpsc::Sender<RecordState>> {
    if !is_enable() {
        return None;
    }
    let (tx, rx) = std::sync::mpsc::channel();
    run(rx, dir);
    Some(tx)
}

fn run(rx: Receiver<RecordState>, dir: String) {
    std::thread::spawn(move || {
        let api_server = crate::get_api_server(
            Config::get_option("api-server"),
            Config::get_option("custom-rendezvous-server"),
        );
        // This URL is used for TLS connectivity testing and fallback detection.
        let login_option_url = format!("{}/api/login-options", &api_server);
        let client = create_http_client_with_url(&login_option_url);
        let mut uploader = RecordUploader::new(client, api_server);
        uploader.token = crate::common::deskzap_runtime_token();
        uploader.resume_pending(&dir);
        loop {
            uploader.token = crate::common::deskzap_runtime_token();
            if let Err(e) = match rx.recv() {
                Ok(state) => match state {
                    RecordState::NewFile(filepath) => uploader.handle_new_file(filepath),
                    RecordState::NewFrame => {
                        if uploader.running {
                            // A failed part is retried on a later frame; it does not end the upload.
                            if let Err(e) = uploader.handle_frame(false) {
                                log::warn!("upload part failed, will retry: {}", e);
                                uploader.last_send = Instant::now();
                            }
                        }
                        Ok(())
                    }
                    RecordState::WriteTail => {
                        if uploader.running {
                            uploader.handle_tail()
                        } else {
                            Ok(())
                        }
                    }
                    RecordState::RemoveFile => {
                        if uploader.running {
                            uploader.handle_remove()
                        } else {
                            Ok(())
                        }
                    }
                },
                Err(e) => {
                    log::trace!("upload thread stop: {}", e);
                    break;
                }
            } {
                // The progress file stays, so the next start finishes this upload.
                uploader.release();
                log::error!("upload stop: {}", e);
            }
        }
    });
}

enum Reply {
    Ok,
    /// 409: the server already holds data for this file. Not an error to report.
    Conflict,
}

struct RecordUploader {
    client: Client,
    api_server: String,
    token: String,
    filepath: String,
    filename: String,
    /// Bytes the server has acknowledged.
    upload_size: u64,
    /// End of a part whose outcome is unknown (the request failed after the server may have
    /// applied it). The server holds either `upload_size` or `maybe_end`; the retry resends
    /// exactly that range, so a 409 says which.
    maybe_end: u64,
    running: bool,
    last_send: Instant,
}
impl RecordUploader {
    fn new(client: Client, api_server: String) -> Self {
        Self {
            client,
            api_server,
            token: Default::default(),
            filepath: Default::default(),
            filename: Default::default(),
            upload_size: 0,
            maybe_end: 0,
            running: false,
            last_send: Instant::now(),
        }
    }

    fn send<Q, B>(&self, query: &Q, body: B) -> ResultType<Reply>
    where
        Q: Serialize + ?Sized,
        B: Into<Body>,
    {
        if self.token.is_empty() {
            bail!("no device runtime token, recording not uploaded");
        }
        match self
            .client
            .post(format!("{}/api/record", self.api_server))
            .bearer_auth(&self.token)
            .query(query)
            .body(body)
            .send()
        {
            Ok(resp) => {
                let status = resp.status();
                if status.as_u16() == 409 {
                    return Ok(Reply::Conflict);
                }
                if let Ok(m) = resp.json::<Map<String, serde_json::Value>>() {
                    if let Some(e) = m.get("error") {
                        bail!(e.to_string());
                    }
                }
                if !status.is_success() {
                    bail!("upload rejected: {}", status);
                }
                Ok(Reply::Ok)
            }
            Err(e) => bail!(e.to_string()),
        }
    }

    fn progress_path(&self) -> String {
        format!("{}{}", self.filepath, PROGRESS_EXT)
    }

    fn save_progress(&self) {
        std::fs::write(
            self.progress_path(),
            format!("{} {}\n", self.upload_size, self.maybe_end),
        )
        .ok();
    }

    fn load_progress(&mut self) {
        let text = std::fs::read_to_string(self.progress_path()).unwrap_or_default();
        let mut it = text.split_whitespace().filter_map(|v| v.parse::<u64>().ok());
        self.upload_size = it.next().unwrap_or(0);
        self.maybe_end = it.next().unwrap_or(0);
    }

    /// Stop working on the current file, leaving its progress file for a later resume.
    fn release(&mut self) {
        ACTIVE.lock().unwrap().remove(&self.filepath);
        self.running = false;
    }

    /// The file is fully handled: nothing left to resume.
    fn finish(&mut self) {
        std::fs::remove_file(self.progress_path()).ok();
        self.release();
    }

    fn handle_new_file(&mut self, filepath: String) -> ResultType<()> {
        match std::path::PathBuf::from(&filepath).file_name() {
            Some(filename) => match filename.to_owned().into_string() {
                Ok(filename) => {
                    self.filename = filename;
                    self.filepath = filepath;
                    self.load_progress();
                    self.running = true;
                    self.last_send = Instant::now();
                    ACTIVE.lock().unwrap().insert(self.filepath.clone());
                    match self.send(&[("type", "new"), ("file", &self.filename)], Bytes::new())? {
                        // The server holds nothing: first attempt, or it lost the partial.
                        Reply::Ok => {
                            self.upload_size = 0;
                            self.maybe_end = 0;
                        }
                        // An earlier attempt left data there: carry on from the saved progress.
                        Reply::Conflict => {
                            log::info!("upload of {} resumes at {}", self.filename, self.upload_size)
                        }
                    }
                    self.save_progress();
                    Ok(())
                }
                Err(_) => bail!("can't parse filename:{:?}", filename),
            },
            None => bail!("can't parse filepath:{}", filepath),
        }
    }

    fn handle_frame(&mut self, flush: bool) -> ResultType<()> {
        if !flush && self.last_send.elapsed() < SHOULD_SEND_TIME {
            return Ok(());
        }
        let mut file = File::open(&self.filepath)?;
        let len = file.metadata()?.len();
        // After an unknown outcome, resend exactly the same range.
        let retrying = self.maybe_end > self.upload_size;
        let end = if retrying { self.maybe_end } else { len };
        if end <= self.upload_size {
            return Ok(());
        }
        if !flush && !retrying && end - self.upload_size < SHOULD_SEND_SIZE {
            return Ok(());
        }
        let mut buf = vec![0u8; (end - self.upload_size) as usize];
        file.seek(SeekFrom::Start(self.upload_size))?;
        file.read_exact(&mut buf)?;
        // Persist before sending: if the process dies mid-request, the next start knows the
        // server may already hold this range.
        self.maybe_end = end;
        self.save_progress();
        let reply = self.send(
            &[
                ("type", "part"),
                ("file", &self.filename),
                ("offset", &self.upload_size.to_string()),
                ("length", &buf.len().to_string()),
            ],
            buf,
        )?;
        // A 409 while retrying means the unanswered attempt had been applied.
        let applied = match reply {
            Reply::Ok => true,
            Reply::Conflict => retrying,
        };
        if !applied {
            bail!("server offset does not match {}", self.upload_size);
        }
        self.upload_size = end;
        self.maybe_end = 0;
        self.save_progress();
        self.last_send = Instant::now();
        Ok(())
    }

    fn handle_tail(&mut self) -> ResultType<()> {
        // A retried range may still leave bytes behind it.
        self.handle_frame(true)?;
        self.handle_frame(true)?;
        let mut file = File::open(&self.filepath)?;
        let mut buf = vec![0u8; MAX_HEADER_LEN];
        let length = file.read(&mut buf)?;
        buf.truncate(length);
        if let Reply::Conflict = self.send(
            &[
                ("type", "tail"),
                ("file", &self.filename),
                ("offset", "0"),
                ("length", &length.to_string()),
            ],
            buf,
        )? {
            bail!("server refused the recording tail");
        }
        log::info!("upload success, file: {}", self.filename);
        self.finish();
        Ok(())
    }

    fn handle_remove(&mut self) -> ResultType<()> {
        self.send(
            &[("type", "remove"), ("file", &self.filename)],
            Bytes::new(),
        )?;
        self.finish();
        Ok(())
    }

    /// Finish uploads cut short by a crash or kill: every `*.upload` file in `dir` that no
    /// thread in this process is working on.
    fn resume_pending(&mut self, dir: &str) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path().to_string_lossy().into_owned();
            let Some(media) = path.strip_suffix(PROGRESS_EXT) else {
                continue;
            };
            if ACTIVE.lock().unwrap().contains(media) {
                continue;
            }
            if !std::path::Path::new(media).exists() {
                std::fs::remove_file(&path).ok();
                continue;
            }
            log::info!("resuming interrupted upload: {}", media);
            let result = self
                .handle_new_file(media.to_owned())
                .and_then(|_| self.handle_tail());
            if let Err(e) = result {
                self.release();
                log::warn!("resume of {} failed, will retry next start: {}", media, e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        collections::HashMap,
        io::{BufRead, BufReader},
        net::{TcpListener, TcpStream},
        sync::Arc,
    };

    /// Stand-in for the control-plane receiver: the same new/part/tail/remove and 409 rules.
    #[derive(Default)]
    struct Server {
        stored: Mutex<Vec<u8>>,
        announced: Mutex<bool>,
        finalised: Mutex<bool>,
        auth: Mutex<Vec<String>>,
        /// Apply this many parts, then apply one more but drop the connection without replying.
        drop_after: Mutex<Option<usize>>,
    }

    fn serve(server: Arc<Server>) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                handle(&server, stream);
            }
        });
        format!("http://{}", addr)
    }

    fn handle(server: &Server, mut stream: TcpStream) {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let target = line.split_whitespace().nth(1).unwrap().to_owned();
        let (mut len, mut auth) = (0usize, String::new());
        loop {
            let mut h = String::new();
            reader.read_line(&mut h).unwrap();
            let h = h.trim_end().to_owned();
            if h.is_empty() {
                break;
            }
            let lower = h.to_lowercase();
            if let Some(v) = lower.strip_prefix("content-length:") {
                len = v.trim().parse().unwrap();
            }
            if lower.starts_with("authorization:") {
                auth = h["authorization:".len()..].trim().to_owned();
            }
        }
        let mut body = vec![0u8; len];
        reader.read_exact(&mut body).unwrap();
        server.auth.lock().unwrap().push(auth);
        let q: HashMap<String, String> = target
            .split_once('?')
            .map(|(_, q)| q)
            .unwrap_or("")
            .split('&')
            .filter_map(|kv| kv.split_once('='))
            .map(|(k, v)| (k.to_owned(), v.to_owned()))
            .collect();
        let mut stored = server.stored.lock().unwrap();
        let status = match q["type"].as_str() {
            "new" => {
                if !stored.is_empty() {
                    409
                } else {
                    *server.announced.lock().unwrap() = true;
                    200
                }
            }
            "part" => {
                let offset: usize = q["offset"].parse().unwrap();
                if !*server.announced.lock().unwrap() || offset != stored.len() {
                    409
                } else {
                    stored.extend_from_slice(&body);
                    let mut drop_after = server.drop_after.lock().unwrap();
                    if let Some(n) = drop_after.as_mut() {
                        if *n == 0 {
                            *drop_after = None;
                            return; // applied, connection dropped, no reply
                        }
                        *n -= 1;
                    }
                    200
                }
            }
            "tail" => {
                stored[..body.len()].copy_from_slice(&body);
                *server.finalised.lock().unwrap() = true;
                200
            }
            _ => 400,
        };
        let _ = write!(stream, "HTTP/1.1 {} X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status);
    }

    fn uploader(url: &str) -> RecordUploader {
        let mut u = RecordUploader::new(Client::new(), url.to_owned());
        u.token = "runtime-token".to_owned();
        u
    }

    fn source(name: &str, len: usize) -> (String, Vec<u8>) {
        let dir = std::env::temp_dir().join(format!("dz-rec-{}-{}", name, std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("incoming_test.webm");
        let data: Vec<u8> = (0..len).map(|i| (i * 7 % 251) as u8).collect();
        std::fs::write(&path, &data).unwrap();
        (path.to_string_lossy().into_owned(), data)
    }

    #[test]
    fn upload_sends_bearer_token_and_matches_source() {
        let server = Arc::new(Server::default());
        let url = serve(server.clone());
        let (path, data) = source("bearer", 3 * 1024 * 1024 + 17);
        let mut u = uploader(&url);
        u.handle_new_file(path.clone()).unwrap();
        u.handle_tail().unwrap();
        assert!(*server.finalised.lock().unwrap());
        assert_eq!(*server.stored.lock().unwrap(), data);
        let auth = server.auth.lock().unwrap();
        assert!(auth.len() >= 3);
        assert!(auth.iter().all(|a| a == "Bearer runtime-token"), "{:?}", auth);
        assert!(!std::path::Path::new(&format!("{}{}", path, PROGRESS_EXT)).exists());
    }

    #[test]
    fn no_token_sends_nothing() {
        let server = Arc::new(Server::default());
        let url = serve(server.clone());
        let (path, _) = source("notoken", 10);
        let mut u = uploader(&url);
        u.token.clear();
        assert!(u.handle_new_file(path).is_err());
        assert!(server.auth.lock().unwrap().is_empty());
    }

    #[test]
    fn lost_reply_resumes_without_duplicating_bytes() {
        let server = Arc::new(Server::default());
        *server.drop_after.lock().unwrap() = Some(0); // first part applied, reply lost
        let url = serve(server.clone());
        let (path, data) = source("lostreply", 2 * 1024 * 1024);
        let mut u = uploader(&url);
        u.handle_new_file(path).unwrap();
        assert!(u.handle_frame(true).is_err());
        u.handle_tail().unwrap(); // retry -> 409 -> treated as applied
        assert_eq!(*server.stored.lock().unwrap(), data);
        assert!(*server.finalised.lock().unwrap());
    }

    #[test]
    fn restart_finishes_an_interrupted_upload() {
        let server = Arc::new(Server::default());
        *server.drop_after.lock().unwrap() = Some(0);
        let url = serve(server.clone());
        let (path, data) = source("restart", 2 * 1024 * 1024);
        let dir = std::path::Path::new(&path).parent().unwrap().to_owned();
        {
            let mut killed = uploader(&url);
            killed.handle_new_file(path.clone()).unwrap();
            assert!(killed.handle_frame(true).is_err());
            // process dies here: only the progress file survives
            killed.release();
        }
        let mut restarted = uploader(&url);
        restarted.resume_pending(dir.to_str().unwrap());
        assert_eq!(*server.stored.lock().unwrap(), data);
        assert!(*server.finalised.lock().unwrap());
        assert!(!std::path::Path::new(&format!("{}{}", path, PROGRESS_EXT)).exists());
    }
}
