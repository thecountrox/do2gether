//! `file:sha256p:<size>:<first32hex>:<last32hex>`: size + SHA-256 of the first 4 MiB + SHA-256 of
//! the last 4 MiB, each digest truncated to its first 32 hex digits (docs/00-spec.md, Hashing).

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

use sha2::{Digest, Sha256};

const CHUNK: u64 = 4 * 1024 * 1024;

pub fn item_ref(path: &Path) -> io::Result<String> {
    let mut f = File::open(path)?;
    let size = f.metadata()?.len();
    let head = hash_range(&mut f, 0, size.min(CHUNK))?;
    let tail_len = size.min(CHUNK);
    let tail = hash_range(&mut f, size - tail_len, tail_len)?;
    Ok(format!("file:sha256p:{size}:{head}:{tail}"))
}

/// The ref of an empty file: what `--simulate` without `--file` plays.
pub fn empty_item_ref() -> String {
    let h = hex32(&Sha256::digest(b""));
    format!("file:sha256p:0:{h}:{h}")
}

fn hash_range(f: &mut File, start: u64, len: u64) -> io::Result<String> {
    f.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::with_capacity(len as usize);
    f.take(len).read_to_end(&mut buf)?;
    Ok(hex32(&Sha256::digest(&buf)))
}

fn hex32(digest: &[u8]) -> String {
    digest[..16].iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use wt_protocol::is_item_ref;

    #[test]
    fn refs_match_the_grammar_and_cover_head_and_tail() {
        let empty = empty_item_ref();
        assert!(is_item_ref(&empty), "{empty}");
        assert_eq!(
            empty,
            "file:sha256p:0:e3b0c44298fc1c149afbf4c8996fb924:e3b0c44298fc1c149afbf4c8996fb924"
        );

        let path = std::env::temp_dir().join(format!("wt-media-test-{}", std::process::id()));
        let mut data = vec![0u8; (CHUNK + 10) as usize];
        std::fs::write(&path, &data).unwrap();
        let a = item_ref(&path).unwrap();
        *data.last_mut().unwrap() = 1;
        std::fs::write(&path, &data).unwrap();
        let b = item_ref(&path).unwrap();
        std::fs::remove_file(&path).unwrap();

        assert!(is_item_ref(&a), "{a}");
        assert!(a.starts_with(&format!("file:sha256p:{}:", CHUNK + 10)));
        let parts = |s: &str| s.rsplitn(3, ':').map(String::from).collect::<Vec<_>>();
        let (pa, pb) = (parts(&a), parts(&b));
        assert_eq!(pa[1], pb[1], "head unchanged");
        assert_ne!(pa[0], pb[0], "tail sees the last byte");
    }
}
