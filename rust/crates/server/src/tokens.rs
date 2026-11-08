//! HMAC-SHA256 join tokens: `base64url({"room","exp","sub"?}) "." base64url(HMAC(room:exp:sub))`.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde::Serialize;
use serde_json::Value;
use sha2::Sha256;
use wt_protocol::as_safe_integer;

use crate::clock::server_now;

pub const TOKEN_TTL_MS: i64 = 10 * 60 * 1000;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Claims {
    pub room: String,
    pub exp: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sub: Option<String>,
}

fn mac(room: &str, exp: i64, sub: Option<&str>) -> Hmac<Sha256> {
    let secret = std::env::var("WT_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "dev-secret".into());
    let mut mac =
        Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC takes keys of any length");
    mac.update(format!("{room}:{exp}:{}", sub.unwrap_or("")).as_bytes());
    mac
}

pub fn sign_token(room: &str) -> String {
    sign_token_for(room, None)
}

pub fn sign_token_for(room: &str, sub: Option<&str>) -> String {
    sign_token_for_with_ttl(room, sub, TOKEN_TTL_MS)
}

pub fn sign_token_with_ttl(room: &str, ttl_ms: i64) -> String {
    sign_token_for_with_ttl(room, None, ttl_ms)
}

pub fn sign_token_for_with_ttl(room: &str, sub: Option<&str>, ttl_ms: i64) -> String {
    let exp = server_now() + ttl_ms;
    let claims = serde_json::to_vec(&Claims {
        room: room.to_owned(),
        exp,
        sub: sub.map(str::to_owned),
    })
    .expect("claims always serialize");
    let sig = mac(room, exp, sub).finalize().into_bytes();
    format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(claims),
        URL_SAFE_NO_PAD.encode(sig)
    )
}

/// Read claims without authenticating them. Never use this to authorize a connection.
pub fn decode_token(token: &str) -> Option<Claims> {
    let (payload, sig) = token.split_once('.')?;
    if sig.contains('.') {
        return None;
    }
    let Ok(payload) = URL_SAFE_NO_PAD.decode(payload) else {
        return None;
    };
    let Ok(Value::Object(claims)) = serde_json::from_slice::<Value>(&payload) else {
        return None;
    };
    let room = claims.get("room")?.as_str()?.to_owned();
    let exp = as_safe_integer(claims.get("exp")?)?;
    let sub = match claims.get("sub") {
        Some(value) => Some(value.as_str()?.to_owned()),
        None => None,
    };
    Some(Claims { room, exp, sub })
}

pub fn verify_token(token: &str, room_id: &str) -> Option<Claims> {
    let claims = decode_token(token)?;
    let (_, sig) = token.split_once('.')?;
    // The decoder rejects padding and non-canonical trailing bits, so each signature has exactly
    // one accepted encoding and the constant-time byte comparison equals comparing the strings.
    let Ok(sig) = URL_SAFE_NO_PAD.decode(sig) else {
        return None;
    };
    let current = mac(&claims.room, claims.exp, claims.sub.as_deref())
        .verify_slice(&sig)
        .is_ok();
    // Tokens issued before `sub` existed signed `room:exp`; accept only that unbound form.
    let legacy = claims.sub.is_none()
        && legacy_mac(&claims.room, claims.exp)
            .verify_slice(&sig)
            .is_ok();
    if !current && !legacy {
        return None;
    }
    (claims.room == room_id && claims.exp > server_now()).then_some(claims)
}

fn legacy_mac(room: &str, exp: i64) -> Hmac<Sha256> {
    let secret = std::env::var("WT_SECRET")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "dev-secret".into());
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key");
    mac.update(format!("{room}:{exp}").as_bytes());
    mac
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_non_canonical_signature_encodings() {
        let token = sign_token("abcdefgh");
        assert!(verify_token(&token, "abcdefgh").is_some());
        assert!(
            verify_token(&format!("{token}="), "abcdefgh").is_none(),
            "padding"
        );
        assert!(
            verify_token(&format!("{token}.x"), "abcdefgh").is_none(),
            "three parts"
        );
        // 43 chars carry 258 bits for a 256-bit MAC: setting a discarded low bit must fail.
        const ALPHABET: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let (head, last) = token.split_at(token.len() - 1);
        let i = ALPHABET.find(last).unwrap();
        assert_eq!(i % 4, 0, "canonical encoding leaves the low bits clear");
        let alt = &ALPHABET[i + 1..i + 2];
        assert!(
            verify_token(&format!("{head}{alt}"), "abcdefgh").is_none(),
            "trailing bits"
        );
    }

    #[test]
    fn bound_unbound_tampered_and_expired() {
        let bound = sign_token_for("abcdefgh", Some("ann"));
        assert_eq!(
            verify_token(&bound, "abcdefgh").unwrap().sub.as_deref(),
            Some("ann")
        );
        let unbound = sign_token("abcdefgh");
        assert_eq!(verify_token(&unbound, "abcdefgh").unwrap().sub, None);
        let (payload, _) = unbound.split_once('.').unwrap();
        let legacy_sig = legacy_mac("abcdefgh", decode_token(&unbound).unwrap().exp)
            .finalize()
            .into_bytes();
        let legacy = format!("{payload}.{}", URL_SAFE_NO_PAD.encode(legacy_sig));
        assert_eq!(verify_token(&legacy, "abcdefgh").unwrap().sub, None);
        let (payload, sig) = bound.split_once('.').unwrap();
        let mut claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).unwrap()).unwrap();
        claims["sub"] = Value::String("bob".into());
        let tampered = format!("{}.{}", URL_SAFE_NO_PAD.encode(claims.to_string()), sig);
        assert_eq!(decode_token(&tampered).unwrap().sub.as_deref(), Some("bob"));
        assert!(verify_token(&tampered, "abcdefgh").is_none());
        assert!(
            verify_token(
                &sign_token_for_with_ttl("abcdefgh", Some("ann"), -1),
                "abcdefgh"
            )
            .is_none()
        );
    }
}
