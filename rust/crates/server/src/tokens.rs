//! HMAC-SHA256 join tokens: `base64url({"room","exp"}) "." base64url(HMAC(room:exp))`.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde::Serialize;
use serde_json::Value;
use sha2::Sha256;
use wt_protocol::as_safe_integer;

use crate::clock::server_now;

pub const TOKEN_TTL_MS: i64 = 10 * 60 * 1000;

#[derive(Serialize)]
struct Claims<'a> {
    room: &'a str,
    exp: i64,
}

fn mac(room: &str, exp: i64) -> Hmac<Sha256> {
    let secret = std::env::var("WT_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "dev-secret".into());
    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC takes keys of any length");
    mac.update(format!("{room}:{exp}").as_bytes());
    mac
}

pub fn sign_token(room: &str) -> String {
    sign_token_with_ttl(room, TOKEN_TTL_MS)
}

pub fn sign_token_with_ttl(room: &str, ttl_ms: i64) -> String {
    let exp = server_now() + ttl_ms;
    let claims = serde_json::to_vec(&Claims { room, exp }).expect("claims always serialize");
    let sig = mac(room, exp).finalize().into_bytes();
    format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(claims),
        URL_SAFE_NO_PAD.encode(sig)
    )
}

pub fn verify_token(token: &str, room_id: &str) -> bool {
    let Some((payload, sig)) = token.split_once('.') else {
        return false;
    };
    if sig.contains('.') {
        return false;
    }
    let Ok(payload) = URL_SAFE_NO_PAD.decode(payload) else {
        return false;
    };
    let Ok(Value::Object(claims)) = serde_json::from_slice::<Value>(&payload) else {
        return false;
    };
    let room = claims.get("room").and_then(Value::as_str);
    let exp = claims.get("exp").and_then(as_safe_integer);
    let (Some(room), Some(exp)) = (room, exp) else {
        return false;
    };
    // The decoder rejects padding and non-canonical trailing bits, so each signature has exactly
    // one accepted encoding and the constant-time byte comparison equals comparing the strings.
    let Ok(sig) = URL_SAFE_NO_PAD.decode(sig) else {
        return false;
    };
    if mac(room, exp).verify_slice(&sig).is_err() {
        return false;
    }
    room == room_id && exp > server_now()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_canonical_signature_encodings() {
        let token = sign_token("abcdefgh");
        assert!(verify_token(&token, "abcdefgh"));
        assert!(!verify_token(&format!("{token}="), "abcdefgh"), "padding");
        assert!(
            !verify_token(&format!("{token}.x"), "abcdefgh"),
            "three parts"
        );
        // 43 chars carry 258 bits for a 256-bit MAC: setting a discarded low bit must fail.
        const ALPHABET: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let (head, last) = token.split_at(token.len() - 1);
        let i = ALPHABET.find(last).unwrap();
        assert_eq!(i % 4, 0, "canonical encoding leaves the low bits clear");
        let alt = &ALPHABET[i + 1..i + 2];
        assert!(
            !verify_token(&format!("{head}{alt}"), "abcdefgh"),
            "trailing bits"
        );
    }
}
