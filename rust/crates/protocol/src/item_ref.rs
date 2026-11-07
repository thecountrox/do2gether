/// The `item_ref` pattern from `protocol/room.schema.json`, verbatim. [`ItemRef::parse`] is a
/// hand-written matcher for exactly this pattern; tests assert the schema still says the same.
pub const ITEM_REF_PATTERN: &str = "^(file:sha256p:[0-9]+:[0-9a-f]{32}:[0-9a-f]{32}|yt:[A-Za-z0-9_-]{11}|ytm:[A-Za-z0-9_-]{11}|subsonic:[a-z0-9-]+/[A-Za-z0-9_-]+)$";

/// A parsed, versioned content reference. The algorithm lives inside the ref.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemRef<'a> {
    /// `file:sha256p:<size>:<first32hex>:<last32hex>`. `size` is the decimal digits as written
    /// (the schema does not bound it).
    File {
        size: &'a str,
        head: &'a str,
        tail: &'a str,
    },
    /// `yt:<videoId>`
    Yt { video_id: &'a str },
    /// `ytm:<videoId>`
    Ytm { video_id: &'a str },
    /// `subsonic:<serverId>/<trackId>`
    Subsonic {
        server_id: &'a str,
        track_id: &'a str,
    },
}

impl<'a> ItemRef<'a> {
    /// Parses `s` if and only if it matches [`ITEM_REF_PATTERN`].
    pub fn parse(s: &'a str) -> Option<Self> {
        if let Some(rest) = s.strip_prefix("file:sha256p:") {
            let mut parts = rest.split(':');
            let (size, head, tail) = (parts.next()?, parts.next()?, parts.next()?);
            let ok = parts.next().is_none()
                && is_run(size, |b| b.is_ascii_digit())
                && is_hex32(head)
                && is_hex32(tail);
            return ok.then_some(ItemRef::File { size, head, tail });
        }
        if let Some(video_id) = s.strip_prefix("yt:") {
            return is_video_id(video_id).then_some(ItemRef::Yt { video_id });
        }
        if let Some(video_id) = s.strip_prefix("ytm:") {
            return is_video_id(video_id).then_some(ItemRef::Ytm { video_id });
        }
        if let Some(rest) = s.strip_prefix("subsonic:") {
            let (server_id, track_id) = rest.split_once('/')?;
            let ok = is_run(server_id, |b| {
                b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'
            }) && is_run(track_id, is_id_byte);
            return ok.then_some(ItemRef::Subsonic {
                server_id,
                track_id,
            });
        }
        None
    }
}

/// True if `s` matches [`ITEM_REF_PATTERN`].
pub fn is_item_ref(s: &str) -> bool {
    ItemRef::parse(s).is_some()
}

/// Non-empty and every byte satisfies `pred`.
fn is_run(s: &str, pred: impl Fn(u8) -> bool) -> bool {
    !s.is_empty() && s.bytes().all(pred)
}

fn is_hex32(s: &str) -> bool {
    s.len() == 32
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn is_id_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

fn is_video_id(s: &str) -> bool {
    s.len() == 11 && s.bytes().all(is_id_byte)
}

#[cfg(test)]
mod tests {
    use super::*;

    const A32: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const B32: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn parses_every_scheme() {
        let file = format!("file:sha256p:1073741824:{A32}:{B32}");
        assert_eq!(
            ItemRef::parse(&file),
            Some(ItemRef::File {
                size: "1073741824",
                head: A32,
                tail: B32
            })
        );
        assert_eq!(
            ItemRef::parse("yt:dQw4w9WgXcQ"),
            Some(ItemRef::Yt {
                video_id: "dQw4w9WgXcQ"
            })
        );
        assert_eq!(
            ItemRef::parse("ytm:A_b-C_d-E_f"),
            Some(ItemRef::Ytm {
                video_id: "A_b-C_d-E_f"
            })
        );
        assert_eq!(
            ItemRef::parse("subsonic:navi-drome-2/Tr_0001-x"),
            Some(ItemRef::Subsonic {
                server_id: "navi-drome-2",
                track_id: "Tr_0001-x"
            })
        );
    }

    #[test]
    fn rejects_everything_the_pattern_rejects() {
        let a31 = &A32[1..];
        let upper = A32.to_uppercase();
        let bad = [
            String::new(),
            "file:sha256p:".into(),
            format!("file:sha256p::{A32}:{B32}"),
            format!("file:sha256p:-1:{A32}:{B32}"),
            format!("file:sha256p:12:{a31}:{B32}"),
            format!("file:sha256p:12:{A32}:{B32}0"),
            format!("file:sha256p:12:{upper}:{B32}"),
            format!("file:sha256p:12:{A32}:{B32}:"),
            format!("file:sha256:12:{A32}:{B32}"),
            "yt:dQw4w9WgXc".into(),
            "yt:dQw4w9WgXcQQ".into(),
            "yt:dQw4w9WgX.Q".into(),
            "yt:dQw4w9WgXcQ\n".into(),
            "YT:dQw4w9WgXcQ".into(),
            "ytm:".into(),
            "subsonic:navidrome".into(),
            "subsonic:/tr-1".into(),
            "subsonic:navidrome/".into(),
            "subsonic:Navidrome/tr-1".into(),
            "subsonic:navi_drome/tr-1".into(),
            "subsonic:navidrome/tr/1".into(),
            "subsonic:navidrome/tr-1é".into(),
            "http://example.com/a.mp4".into(),
        ];
        for s in bad {
            assert!(!is_item_ref(&s), "{s:?} should be rejected");
        }
    }
}
