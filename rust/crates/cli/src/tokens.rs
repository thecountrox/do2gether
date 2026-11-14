//! Reading claims out of a join token without verifying it.
//!
//! The server is the only party that verifies signatures; a client only needs its own `sub` so it
//! can present the identity the token was minted for (the server rejects a mismatch with 4001).

/// The `sub` claim of a `<base64url(json)>.<sig>` join token, when the token carries one.
pub fn subject(token: &str) -> Option<String> {
    let payload = token.split('.').next()?;
    let bytes = b64url_decode(payload)?;
    let text = String::from_utf8(bytes).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    value
        .get("sub")?
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn b64url_decode(input: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len() * 3 / 4 + 3);
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    for ch in input.bytes() {
        let v = match ch {
            b'A'..=b'Z' => ch - b'A',
            b'a'..=b'z' => ch - b'a' + 26,
            b'0'..=b'9' => ch - b'0' + 52,
            b'-' | b'+' => 62,
            b'_' | b'/' => 63,
            b'=' => continue,
            _ => return None,
        } as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(payload: &str) -> String {
        format!("{payload}.sig")
    }

    #[test]
    fn reads_sub_when_present() {
        // {"room":"r1","exp":1,"sub":"ann"}
        let t = token("eyJyb29tIjoicjEiLCJleHAiOjEsInN1YiI6ImFubiJ9");
        assert_eq!(subject(&t).as_deref(), Some("ann"));
    }

    #[test]
    fn none_without_sub() {
        // {"room":"r1","exp":1}
        let t = token("eyJyb29tIjoicjEiLCJleHAiOjF9");
        assert_eq!(subject(&t), None);
    }

    #[test]
    fn garbage_is_ignored() {
        assert_eq!(subject("not-a-token"), None);
        assert_eq!(subject(""), None);
        assert_eq!(subject("...."), None);
    }
}
