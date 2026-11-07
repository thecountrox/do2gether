//! `--server` URL handling, the one HTTP call (`POST /rooms`) and the WebSocket connect. Both go
//! over TLS (rustls, the system trust store) for an `https://` server.

use std::io;
use std::sync::Arc;

use rustls::pki_types::ServerName;
use rustls::{ClientConfig, RootCertStore};
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_rustls::TlsConnector;
use tokio_tungstenite::{Connector, connect_async_tls_with_config};

use crate::session::Ws;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scheme {
    Http,
    Https,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerUrl {
    pub scheme: Scheme,
    /// `host:port`, as given (port defaults to 80 for http, 443 for https).
    pub authority: String,
    /// Path prefix without a trailing slash, e.g. `""` or `"/wt"`.
    pub base: String,
}

impl ServerUrl {
    /// `http://`, `https://`, or no scheme (http).
    pub fn parse(url: &str) -> Result<Self, String> {
        let (scheme, rest) = match url.split_once("://") {
            Some(("http", rest)) => (Scheme::Http, rest),
            Some(("https", rest)) => (Scheme::Https, rest),
            Some((other, _)) => {
                return Err(format!(
                    "{url}: unsupported scheme {other}://; use http(s)://"
                ));
            }
            None => (Scheme::Http, url),
        };
        let (authority, base) = rest.split_at(rest.find('/').unwrap_or(rest.len()));
        if authority.is_empty() {
            return Err(format!("{url}: no host"));
        }
        let authority = if authority.contains(':') {
            authority.to_owned()
        } else {
            let port = match scheme {
                Scheme::Http => 80,
                Scheme::Https => 443,
            };
            format!("{authority}:{port}")
        };
        Ok(ServerUrl {
            scheme,
            authority,
            base: base.trim_end_matches('/').to_owned(),
        })
    }

    pub fn ws_url(&self, room: &str, token: &str) -> String {
        let scheme = match self.scheme {
            Scheme::Http => "ws",
            Scheme::Https => "wss",
        };
        format!(
            "{scheme}://{}{}/ws?room={}&token={}",
            self.authority,
            self.base,
            encode_component(room),
            encode_component(token)
        )
    }

    pub async fn connect_ws(&self, room: &str, token: &str) -> Result<Ws, String> {
        let connector = match self.scheme {
            Scheme::Http => Connector::Plain,
            Scheme::Https => Connector::Rustls(tls_config()?),
        };
        let url = self.ws_url(room, token);
        let (ws, _) = connect_async_tls_with_config(url, None, false, Some(connector))
            .await
            .map_err(|e| e.to_string())?;
        Ok(ws)
    }

    /// `POST /rooms` → `(room_id, join_token)`.
    pub async fn create_room(&self) -> Result<(String, String), String> {
        let err = |e: io::Error| format!("POST {}{}/rooms: {e}", self.authority, self.base);
        // HTTP/1.0: the response is close-delimited, never chunked.
        let request = format!(
            "POST {}/rooms HTTP/1.0\r\nHost: {}\r\nContent-Length: 0\r\n\r\n",
            self.base, self.authority
        );
        let tcp = TcpStream::connect(&self.authority).await.map_err(err)?;
        let response = match self.scheme {
            Scheme::Http => exchange(tcp, &request).await,
            Scheme::Https => {
                let tls = TlsConnector::from(tls_config()?)
                    .connect(self.server_name()?, tcp)
                    .await
                    .map_err(err)?;
                exchange(tls, &request).await
            }
        }
        .map_err(err)?;
        let response = String::from_utf8_lossy(&response);
        let (head, body) = response
            .split_once("\r\n\r\n")
            .ok_or("POST /rooms: malformed HTTP response")?;
        let status = head.split_whitespace().nth(1).unwrap_or("");
        if status != "201" {
            return Err(format!("POST /rooms: HTTP {status}"));
        }
        let created: Value = serde_json::from_str(body).map_err(|e| format!("POST /rooms: {e}"))?;
        match (created["room_id"].as_str(), created["join_token"].as_str()) {
            (Some(room), Some(token)) => Ok((room.to_owned(), token.to_owned())),
            _ => Err(format!("POST /rooms: unexpected body {body}")),
        }
    }

    /// The host part of `authority`, as the TLS server name.
    fn server_name(&self) -> Result<ServerName<'static>, String> {
        let host = self
            .authority
            .rsplit_once(':')
            .map_or(self.authority.as_str(), |(host, _)| host);
        ServerName::try_from(host.to_owned()).map_err(|e| format!("{host}: {e}"))
    }
}

/// Sends `request` and reads the response until the server closes.
async fn exchange(
    mut stream: impl AsyncRead + AsyncWrite + Unpin,
    request: &str,
) -> io::Result<Vec<u8>> {
    stream.write_all(request.as_bytes()).await?;
    stream.flush().await?;
    let mut response = Vec::new();
    stream.read_to_end(&mut response).await?;
    Ok(response)
}

/// Verifying client config: the system's root certificates, ring as the crypto provider.
fn tls_config() -> Result<Arc<ClientConfig>, String> {
    let native = rustls_native_certs::load_native_certs();
    let mut roots = RootCertStore::empty();
    roots.add_parsable_certificates(native.certs);
    if roots.is_empty() {
        return Err(format!(
            "no usable root certificates in the system trust store ({:?})",
            native.errors
        ));
    }
    let config =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .map_err(|e| format!("tls: {e}"))?
            .with_root_certificates(roots)
            .with_no_client_auth();
    Ok(Arc::new(config))
}

/// `encodeURIComponent`.
fn encode_component(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&b) {
                char::from(b).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_urls_map_to_ws_urls() {
        let u = ServerUrl::parse("http://127.0.0.1:8787").unwrap();
        assert_eq!(
            u.ws_url("r1", "a.b"),
            "ws://127.0.0.1:8787/ws?room=r1&token=a.b"
        );
        let u = ServerUrl::parse("http://example.com/wt/").unwrap();
        assert_eq!(u.authority, "example.com:80");
        assert_eq!(
            u.ws_url("r 1", "t"),
            "ws://example.com:80/wt/ws?room=r%201&token=t"
        );
        assert_eq!(ServerUrl::parse("localhost:9000").unwrap().base, "");
        assert!(ServerUrl::parse("wss://example.com").is_err());
        assert!(ServerUrl::parse("ftp://example.com").is_err());
        assert!(ServerUrl::parse("http:///x").is_err());
        assert!(ServerUrl::parse("https:///x").is_err());
    }

    #[test]
    fn https_urls_map_to_wss_urls() {
        let u = ServerUrl::parse("https://host").unwrap();
        assert_eq!(u.scheme, Scheme::Https);
        assert_eq!(u.authority, "host:443");
        assert_eq!(u.base, "");
        assert_eq!(u.ws_url("r1", "t"), "wss://host:443/ws?room=r1&token=t");
        assert_eq!(u.server_name().unwrap().to_str(), "host");

        let u = ServerUrl::parse("https://host/path/").unwrap();
        assert_eq!(
            (u.authority.as_str(), u.base.as_str()),
            ("host:443", "/path")
        );
        assert_eq!(
            u.ws_url("r1", "t"),
            "wss://host:443/path/ws?room=r1&token=t"
        );

        let u = ServerUrl::parse("https://host:8443").unwrap();
        assert_eq!(u.authority, "host:8443");
        assert_eq!(u.ws_url("r1", "t"), "wss://host:8443/ws?room=r1&token=t");
        assert_eq!(u.server_name().unwrap().to_str(), "host");

        let u = ServerUrl::parse("http://host:8787").unwrap();
        assert_eq!(u.scheme, Scheme::Http);
        assert_eq!(u.authority, "host:8787");
        assert_eq!(u.ws_url("r1", "t"), "ws://host:8787/ws?room=r1&token=t");
        assert_eq!(ServerUrl::parse("host").unwrap().scheme, Scheme::Http);
    }
}
