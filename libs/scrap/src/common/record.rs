use crate::CodecFormat;
#[cfg(feature = "hwcodec")]
use hbb_common::anyhow::anyhow;
use hbb_common::{
    bail, chrono, log,
    message_proto::{message, video_frame, EncodedVideoFrame, Message},
    ResultType,
};
#[cfg(feature = "hwcodec")]
use hwcodec::mux::{MuxContext, Muxer};
use std::{
    fs::{File, OpenOptions},
    io,
    ops::{Deref, DerefMut},
    path::{Path, PathBuf},
    sync::mpsc::Sender,
    time::Instant,
};
use webm::mux::{self, Segment, Track, VideoTrack, Writer};

const MIN_SECS: u64 = 1;

fn sanitize_recording_peer_id(peer_id: &str) -> String {
    let safe: String = peer_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(64)
        .collect();
    if safe == "." || safe == ".." {
        "_".to_owned()
    } else {
        safe
    }
}

fn recording_session_path(base: &Path, peer_id: &str, date: &str) -> PathBuf {
    if base.as_os_str().is_empty() {
        return PathBuf::new();
    }

    base.join(sanitize_recording_peer_id(peer_id)).join(date)
}

fn filename_has_timestamp(name: &str) -> bool {
    let bytes = name.as_bytes();
    if bytes.windows(14).any(|window| window.iter().all(|b| b.is_ascii_digit())) {
        return true;
    }
    bytes.windows(10).any(|window| {
        window[4] == b'-'
            && window[7] == b'-'
            && window.iter().enumerate().all(|(index, byte)| {
                index == 4 || index == 7 || byte.is_ascii_digit()
            })
    })
}

fn apply_filename_timestamp(name: String, started: &str) -> String {
    if filename_has_timestamp(&name) {
        name
    } else {
        format!("{started}{name}")
    }
}

#[derive(Debug, Clone)]
pub struct RecorderContext {
    pub server: bool,
    pub id: String,
    pub dir: String,
    pub display_idx: usize,
    pub camera: bool,
    pub tx: Option<Sender<RecordState>>,
}

#[derive(Debug, Clone)]
pub struct RecorderContext2 {
    pub filename: String,
    pub width: usize,
    pub height: usize,
    pub format: CodecFormat,
}

impl RecorderContext2 {
    pub fn set_filename(&mut self, ctx: &RecorderContext, session_date: &str) -> ResultType<()> {
        let base_dir = PathBuf::from(&ctx.dir);
        let session_dir = recording_session_path(&base_dir, &ctx.id, session_date);
        let recording_dir = if session_dir.as_os_str().is_empty() {
            log::warn!(
                "Recording base directory is empty. Falling back to the previous recordings path."
            );
            base_dir.clone()
        } else if session_dir.exists() {
            session_dir
        } else {
            match std::fs::create_dir_all(&session_dir) {
                Ok(()) => session_dir,
                Err(err) => {
                    log::warn!(
                        "Failed to create recording session directory {:?}: {}. Falling back to the base directory.",
                        session_dir,
                        err
                    );
                    base_dir.clone()
                }
            }
        };
        if !recording_dir.exists() {
            if let Err(err) = std::fs::create_dir_all(&recording_dir) {
                log::warn!(
                    "Failed to create recording directory {:?}: {}.",
                    recording_dir,
                    err
                );
                return Err(err.into());
            }
        }
        let safe_peer_id = sanitize_recording_peer_id(&ctx.id);
        let file = if ctx.server { "incoming" } else { "outgoing" }.to_string()
            + "_"
            + &safe_peer_id
            + &chrono::Local::now().format("_%Y%m%d%H%M%S%3f_").to_string()
            + &format!(
                "{}{}_",
                if ctx.camera { "camera" } else { "display" },
                ctx.display_idx
            )
            + &self.format.to_string().to_lowercase()
            + if self.format == CodecFormat::VP9
                || self.format == CodecFormat::VP8
                || self.format == CodecFormat::AV1
            {
                ".webm"
            } else {
                ".mp4"
            };
        let started = chrono::Local::now().format("%Y-%m-%d_%H%M%S_").to_string();
        let file = apply_filename_timestamp(file, &started);
        self.filename = recording_dir
            .join(file)
            .to_string_lossy()
            .to_string();
        Ok(())
    }
}

unsafe impl Send for Recorder {}
unsafe impl Sync for Recorder {}

pub trait RecorderApi {
    fn new(ctx: RecorderContext, ctx2: RecorderContext2) -> ResultType<Self>
    where
        Self: Sized;
    fn write_video(&mut self, frame: &EncodedVideoFrame) -> bool;
}

#[derive(Debug)]
pub enum RecordState {
    NewFile(String),
    NewFrame,
    WriteTail,
    RemoveFile,
}

pub struct Recorder {
    pub inner: Option<Box<dyn RecorderApi>>,
    ctx: RecorderContext,
    session_date: String,
    ctx2: Option<RecorderContext2>,
    pts: Option<i64>,
    check_failed: bool,
}

impl Deref for Recorder {
    type Target = Option<Box<dyn RecorderApi>>;

    fn deref(&self) -> &Self::Target {
        &self.inner
    }
}

impl DerefMut for Recorder {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.inner
    }
}

impl Recorder {
    pub fn new(ctx: RecorderContext) -> ResultType<Self> {
        Ok(Self {
            inner: None,
            ctx,
            session_date: chrono::Local::now().format("%Y-%m-%d").to_string(),
            ctx2: None,
            pts: None,
            check_failed: false,
        })
    }

    fn check(&mut self, w: usize, h: usize, format: CodecFormat) -> ResultType<()> {
        match self.ctx2 {
            Some(ref ctx2) => {
                if ctx2.width != w || ctx2.height != h || ctx2.format != format {
                    let mut ctx2 = RecorderContext2 {
                        width: w,
                        height: h,
                        format,
                        filename: Default::default(),
                    };
                    ctx2.set_filename(&self.ctx, &self.session_date)?;
                    self.ctx2 = Some(ctx2);
                    self.inner = None;
                }
            }
            None => {
                let mut ctx2 = RecorderContext2 {
                    width: w,
                    height: h,
                    format,
                    filename: Default::default(),
                };
                ctx2.set_filename(&self.ctx, &self.session_date)?;
                self.ctx2 = Some(ctx2);
                self.inner = None;
            }
        }
        let Some(ctx2) = &self.ctx2 else {
            bail!("ctx2 is None");
        };
        if self.inner.is_none() {
            self.inner = match format {
                CodecFormat::VP8 | CodecFormat::VP9 | CodecFormat::AV1 => Some(Box::new(
                    WebmRecorder::new(self.ctx.clone(), (*ctx2).clone())?,
                )),
                #[cfg(feature = "hwcodec")]
                _ => Some(Box::new(HwRecorder::new(
                    self.ctx.clone(),
                    (*ctx2).clone(),
                )?)),
                #[cfg(not(feature = "hwcodec"))]
                _ => bail!("unsupported codec type"),
            };
            // pts is None when new inner is created
            self.pts = None;
            self.send_state(RecordState::NewFile(ctx2.filename.clone()));
        }
        Ok(())
    }

    pub fn write_message(&mut self, msg: &Message, w: usize, h: usize) {
        if let Some(message::Union::VideoFrame(vf)) = &msg.union {
            if let Some(frame) = &vf.union {
                self.write_frame(frame, w, h).ok();
            }
        }
    }

    pub fn write_frame(
        &mut self,
        frame: &video_frame::Union,
        w: usize,
        h: usize,
    ) -> ResultType<()> {
        if self.check_failed {
            bail!("check failed");
        }
        let format = CodecFormat::from(frame);
        if format == CodecFormat::Unknown {
            bail!("unsupported frame type");
        }
        let res = self.check(w, h, format);
        if res.is_err() {
            self.check_failed = true;
            log::error!("check failed: {:?}", res);
            res?;
        }
        match frame {
            video_frame::Union::Vp8s(vp8s) => {
                for f in vp8s.frames.iter() {
                    self.check_pts(f.pts, f.key, w, h, format)?;
                    self.as_mut().map(|x| x.write_video(f));
                }
            }
            video_frame::Union::Vp9s(vp9s) => {
                for f in vp9s.frames.iter() {
                    self.check_pts(f.pts, f.key, w, h, format)?;
                    self.as_mut().map(|x| x.write_video(f));
                }
            }
            video_frame::Union::Av1s(av1s) => {
                for f in av1s.frames.iter() {
                    self.check_pts(f.pts, f.key, w, h, format)?;
                    self.as_mut().map(|x| x.write_video(f));
                }
            }
            #[cfg(feature = "hwcodec")]
            video_frame::Union::H264s(h264s) => {
                for f in h264s.frames.iter() {
                    self.check_pts(f.pts, f.key, w, h, format)?;
                    self.as_mut().map(|x| x.write_video(f));
                }
            }
            #[cfg(feature = "hwcodec")]
            video_frame::Union::H265s(h265s) => {
                for f in h265s.frames.iter() {
                    self.check_pts(f.pts, f.key, w, h, format)?;
                    self.as_mut().map(|x| x.write_video(f));
                }
            }
            _ => bail!("unsupported frame type"),
        }
        self.send_state(RecordState::NewFrame);
        Ok(())
    }

    fn check_pts(
        &mut self,
        pts: i64,
        key: bool,
        w: usize,
        h: usize,
        format: CodecFormat,
    ) -> ResultType<()> {
        // https://stackoverflow.com/questions/76379101/how-to-create-one-playable-webm-file-from-two-different-video-tracks-with-same-c
        if self.pts.is_none() && !key {
            bail!("first frame is not key frame");
        }
        let old_pts = self.pts;
        self.pts = Some(pts);
        if old_pts.clone().unwrap_or_default() > pts {
            log::info!("pts {:?} -> {}, change record filename", old_pts, pts);
            self.inner = None;
            self.ctx2 = None;
            let res = self.check(w, h, format);
            if res.is_err() {
                self.check_failed = true;
                log::error!("check failed: {:?}", res);
                res?;
            }
            self.pts = Some(pts);
        }
        Ok(())
    }

    fn send_state(&self, state: RecordState) {
        self.ctx.tx.as_ref().map(|tx| tx.send(state));
    }
}

struct WebmRecorder {
    vt: VideoTrack,
    webm: Option<Segment<Writer<File>>>,
    ctx: RecorderContext,
    ctx2: RecorderContext2,
    key: bool,
    written: bool,
    start: Instant,
}

impl RecorderApi for WebmRecorder {
    fn new(ctx: RecorderContext, ctx2: RecorderContext2) -> ResultType<Self> {
        let out = match {
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&ctx2.filename)
        } {
            Ok(file) => file,
            Err(ref e) if e.kind() == io::ErrorKind::AlreadyExists => File::create(&ctx2.filename)?,
            Err(e) => return Err(e.into()),
        };
        let mut webm = match mux::Segment::new(mux::Writer::new(out)) {
            Some(v) => v,
            None => bail!("Failed to create webm mux"),
        };
        let vt = webm.add_video_track(
            ctx2.width as _,
            ctx2.height as _,
            None,
            if ctx2.format == CodecFormat::VP9 {
                mux::VideoCodecId::VP9
            } else if ctx2.format == CodecFormat::VP8 {
                mux::VideoCodecId::VP8
            } else {
                mux::VideoCodecId::AV1
            },
        );
        if ctx2.format == CodecFormat::AV1 {
            // [129, 8, 12, 0] in 3.6.0, but zero works
            let codec_private = vec![0, 0, 0, 0];
            if !webm.set_codec_private(vt.track_number(), &codec_private) {
                bail!("Failed to set codec private");
            }
        }
        Ok(WebmRecorder {
            vt,
            webm: Some(webm),
            ctx,
            ctx2,
            key: false,
            written: false,
            start: Instant::now(),
        })
    }

    fn write_video(&mut self, frame: &EncodedVideoFrame) -> bool {
        if frame.key {
            self.key = true;
        }
        if self.key {
            let ok = self
                .vt
                .add_frame(&frame.data, frame.pts as u64 * 1_000_000, frame.key);
            if ok {
                self.written = true;
            }
            ok
        } else {
            false
        }
    }
}

impl Drop for WebmRecorder {
    fn drop(&mut self) {
        let _ = std::mem::replace(&mut self.webm, None).map_or(false, |webm| webm.finalize(None));
        let mut state = RecordState::WriteTail;
        if !self.written || self.start.elapsed().as_secs() < MIN_SECS {
            std::fs::remove_file(&self.ctx2.filename).ok();
            state = RecordState::RemoveFile;
        }
        self.ctx.tx.as_ref().map(|tx| tx.send(state));
    }
}

#[cfg(feature = "hwcodec")]
struct HwRecorder {
    muxer: Option<Muxer>,
    ctx: RecorderContext,
    ctx2: RecorderContext2,
    written: bool,
    key: bool,
    start: Instant,
}

#[cfg(feature = "hwcodec")]
impl RecorderApi for HwRecorder {
    fn new(ctx: RecorderContext, ctx2: RecorderContext2) -> ResultType<Self> {
        let muxer = Muxer::new(MuxContext {
            filename: ctx2.filename.clone(),
            width: ctx2.width,
            height: ctx2.height,
            is265: ctx2.format == CodecFormat::H265,
            framerate: crate::hwcodec::DEFAULT_FPS as _,
        })
        .map_err(|_| anyhow!("Failed to create hardware muxer"))?;
        Ok(HwRecorder {
            muxer: Some(muxer),
            ctx,
            ctx2,
            written: false,
            key: false,
            start: Instant::now(),
        })
    }

    fn write_video(&mut self, frame: &EncodedVideoFrame) -> bool {
        if frame.key {
            self.key = true;
        }
        if self.key {
            let ok = self
                .muxer
                .as_mut()
                .map(|m| m.write_video(&frame.data, frame.key).is_ok())
                .unwrap_or_default();
            if ok {
                self.written = true;
            }
            ok
        } else {
            false
        }
    }
}

#[cfg(feature = "hwcodec")]
impl Drop for HwRecorder {
    fn drop(&mut self) {
        self.muxer.as_mut().map(|m| m.write_tail().ok());
        let mut state = RecordState::WriteTail;
        if !self.written || self.start.elapsed().as_secs() < MIN_SECS {
            // The process cannot access the file because it is being used by another process
            self.muxer = None;
            std::fs::remove_file(&self.ctx2.filename).ok();
            state = RecordState::RemoveFile;
        }
        self.ctx.tx.as_ref().map(|tx| tx.send(state));
    }
}

#[cfg(test)]
mod recording_session_path_tests {
    use super::{apply_filename_timestamp, recording_session_path};
    use std::path::{Path, PathBuf};

    const DATE: &str = "2026-10-19";

    #[test]
    fn recording_session_path_uses_peer_and_date() {
        assert_eq!(
            recording_session_path(Path::new("recordings"), "device-01", DATE),
            PathBuf::from("recordings").join("device-01").join(DATE)
        );
    }

    #[test]
    fn recording_session_path_removes_path_separators_from_peer_id() {
        assert_eq!(
            recording_session_path(Path::new("recordings"), "device/one", DATE),
            PathBuf::from("recordings").join("deviceone").join(DATE)
        );
    }

    #[test]
    fn recording_session_path_prevents_dot_segment_traversal() {
        assert_eq!(
            recording_session_path(Path::new("recordings"), "..", DATE),
            PathBuf::from("recordings").join("_").join(DATE)
        );
        assert_eq!(
            recording_session_path(Path::new("recordings"), ".", DATE),
            PathBuf::from("recordings").join("_").join(DATE)
        );
    }

    #[test]
    fn recording_session_path_removes_spaces_and_unicode_from_peer_id() {
        assert_eq!(
            recording_session_path(Path::new("recordings"), "séance one", DATE),
            PathBuf::from("recordings").join("sanceone").join(DATE)
        );
    }

    #[test]
    fn recording_session_path_collapses_parent_traversal() {
        let base = Path::new("recordings");
        let path = recording_session_path(base, "a/../../etc", DATE);
        assert_eq!(path, PathBuf::from("recordings").join("a....etc").join(DATE));
        assert!(path.starts_with(base));
    }

    #[test]
    fn recording_session_path_limits_peer_id_to_64_chars() {
        let peer_id = "a".repeat(80);
        assert_eq!(
            recording_session_path(Path::new("recordings"), &peer_id, DATE),
            PathBuf::from("recordings").join("a".repeat(64)).join(DATE)
        );
    }

    #[test]
    fn apply_filename_timestamp_keeps_existing_timestamp() {
        let name = "outgoing_abc_20261019120000000_display0_vp9.webm".to_owned();
        assert_eq!(
            apply_filename_timestamp(name.clone(), "2026-10-19_120000_"),
            name
        );
    }

    #[test]
    fn apply_filename_timestamp_prepends_when_missing() {
        assert_eq!(
            apply_filename_timestamp("outgoing_abc.webm".to_owned(), "2026-10-19_120000_"),
            "2026-10-19_120000_outgoing_abc.webm"
        );
    }

    #[test]
    fn recording_session_path_allows_empty_peer_id() {
        assert_eq!(
            recording_session_path(Path::new("recordings"), "", DATE),
            PathBuf::from("recordings").join(DATE)
        );
    }

    #[test]
    fn recording_session_path_returns_empty_path_for_empty_base() {
        assert_eq!(
            recording_session_path(Path::new(""), "device-01", DATE),
            PathBuf::new()
        );
    }
}
