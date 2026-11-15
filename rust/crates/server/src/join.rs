//! Public, self-contained landing page for an invitation token.

use axum::extract::Path;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{Html, IntoResponse, Response};

use crate::tokens::{decode_token, verify_token};

fn escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn component(value: &str) -> String {
    value
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

fn document(content: &str) -> String {
    format!(
        r#"<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>watch-together invite</title><style>
*{{box-sizing:border-box}}body{{margin:0;min-height:100vh;display:grid;place-items:center;background:#10131a;color:#f1f3f8;font:16px system-ui,sans-serif;padding:1.25rem}}
main{{width:100%;max-width:36rem;background:#1b2030;border:1px solid #323b51;border-radius:1rem;padding:1.5rem;overflow-wrap:anywhere}}
h1{{font-size:1.6rem}}a.button,button{{display:inline-block;background:#8daeff;color:#111827;border:0;border-radius:.5rem;padding:.75rem 1rem;font:inherit;font-weight:600;cursor:pointer;text-decoration:none}}
button{{margin:.4rem .5rem .4rem 0}}code{{color:#c7d5ff}}.command{{line-height:1.6}}
</style></head><body><main>{content}</main><script>document.addEventListener('click',e=>{{let b=e.target.closest('button[data-copy]');if(b)navigator.clipboard.writeText(b.dataset.copy)}})</script></body></html>"#
    )
}

pub(crate) async fn page(Path(token): Path<String>, headers: HeaderMap) -> Response {
    // Decode for display independently of verification; only display claims after authentication.
    let claims = decode_token(&token);
    let Some(claims) = claims.filter(|claims| verify_token(&token, &claims.room).is_some()) else {
        return (
            StatusCode::BAD_REQUEST,
            Html(document(
                "<h1>this link expired</h1><p>Run /room invite again for a new link.</p>",
            )),
        )
            .into_response();
    };
    let room = escape(&claims.room);
    let token_html = escape(&token);
    let host = headers
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default();
    let scheme = if headers
        .get("x-forwarded-proto")
        .and_then(|v| v.to_str().ok())
        == Some("https")
    {
        "https"
    } else {
        "http"
    };
    let base = escape(&format!("{scheme}://{host}"));
    let deep_link = escape(&format!(
        "do2gether://join?room={}&token={}",
        component(&claims.room),
        component(&token)
    ));
    let content = format!(
        r#"<h1>Join room {room}</h1><p><a class="button" href="{deep_link}">Open the watch-together app</a></p>
<p>Room id: <code>{room}</code><br>Token: <code>{token_html}</code></p>
<button type="button" data-copy="{room}">Copy room id</button><button type="button" data-copy="{token_html}">Copy token</button>
<p class="command">or run: <code>wt-play --server {base} --room {room} --token {token_html} --file &lt;path&gt;</code></p>"#
    );
    (StatusCode::OK, Html(document(&content))).into_response()
}
