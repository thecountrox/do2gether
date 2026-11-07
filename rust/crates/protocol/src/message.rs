//! Inbound parsing (client → server) and outbound encoding (server → client).
//!
//! Inbound parsing is hand-written over `serde_json::Value` rather than derived, so that it
//! keeps the reference server's exact acceptance rules: `42000.0` is a valid integer, an absent
//! `item_ref` differs from `item_ref: null`, and envelope fields other than `v`/`t` are not
//! checked.

use serde::Serialize;
use serde_json::{Map, Value};
use thiserror::Error;

use crate::item_ref::is_item_ref;
use crate::types::{MAX_SAFE_INTEGER, Member, Observed, Playback, QueueItem};

/// `reject.code` for a refused intent.
pub const INTENT_REJECTED: &str = "intent_rejected";

/// An integer within JS's safe range, with `Number.isSafeInteger` semantics (so `42000.0` counts).
pub fn as_safe_integer(v: &Value) -> Option<i64> {
    let Value::Number(n) = v else { return None };
    if let Some(i) = n.as_i64() {
        return (i.unsigned_abs() <= MAX_SAFE_INTEGER as u64).then_some(i);
    }
    let f = n.as_f64()?;
    (f.fract() == 0.0 && f.abs() <= MAX_SAFE_INTEGER as f64).then_some(f as i64)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientInfo {
    pub id: String,
    pub name: String,
    pub ver: String,
}

/// A client message the server acts on.
#[derive(Debug, Clone, PartialEq)]
pub enum ClientMsg {
    Hello(ClientInfo),
    ClockPing {
        ping_id: String,
        t0: i64,
    },
    /// A known op. `intent` is `Err` when its args are refused; the server answers with `reject`.
    Intent {
        id: Option<String>,
        intent: Result<Intent, IntentError>,
    },
    Report {
        activity_id: Option<String>,
        observed: Observed,
    },
}

/// Why a client message is ignored (logged, never answered, connection kept).
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ParseError {
    #[error("malformed JSON")]
    MalformedJson,
    #[error("not a v1 envelope")]
    NotV1Envelope,
    #[error("t={0}")]
    UnknownType(String),
    #[error("invalid {0}")]
    Invalid(&'static str),
    #[error("intent with unknown op {0}")]
    UnknownOp(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Intent {
    /// `item_ref: None` resumes the current item.
    Play {
        item_ref: Option<String>,
        position_ms: Option<i64>,
    },
    Pause,
    Seek {
        position_ms: i64,
    },
    QueueAdd {
        item_ref: String,
    },
    QueueRemove {
        item_ref: String,
    },
    Skip,
}

/// Why an intent is refused. The `Display` text is the `reject.message`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum IntentError {
    #[error("args must be an object")]
    ArgsNotObject,
    #[error("item_ref is not a valid item_ref")]
    InvalidItemRef,
    #[error("position_ms must be a non-negative integer")]
    InvalidPosition,
    #[error("nothing is playing")]
    NothingPlaying,
    #[error("item_ref is not in the queue")]
    NotInQueue,
    #[error("queue is empty and nothing is playing")]
    NothingToSkip,
}

impl ClientMsg {
    pub fn parse(raw: &str) -> Result<Self, ParseError> {
        let msg: Value = serde_json::from_str(raw).map_err(|_| ParseError::MalformedJson)?;
        let Value::Object(msg) = msg else {
            return Err(ParseError::NotV1Envelope);
        };
        let t = match (msg.get("v").and_then(as_safe_integer), msg.get("t")) {
            (Some(1), Some(Value::String(t))) => t.as_str(),
            _ => return Err(ParseError::NotV1Envelope),
        };
        match t {
            "hello" => parse_hello(&msg),
            "clock_ping" => parse_clock_ping(&msg),
            "intent" => parse_intent(&msg),
            "report" => parse_report(&msg),
            other => Err(ParseError::UnknownType(truncate(other))),
        }
    }

    /// The wire `t`, for logs.
    pub fn kind(&self) -> &'static str {
        match self {
            ClientMsg::Hello(_) => "hello",
            ClientMsg::ClockPing { .. } => "clock_ping",
            ClientMsg::Intent { .. } => "intent",
            ClientMsg::Report { .. } => "report",
        }
    }
}

impl Intent {
    /// `None` if `op` is not a v1 intent op; otherwise the intent or why its args are refused.
    pub fn parse(op: &str, args: Option<&Value>) -> Option<Result<Self, IntentError>> {
        let args = || {
            args.and_then(Value::as_object)
                .ok_or(IntentError::ArgsNotObject)
        };
        let parsed = match op {
            "play" => args().and_then(|a| {
                Ok(Intent::Play {
                    item_ref: a.get("item_ref").map(item_ref).transpose()?,
                    position_ms: a.get("position_ms").map(position).transpose()?,
                })
            }),
            "pause" => args().map(|_| Intent::Pause),
            "seek" => args().and_then(|a| {
                Ok(Intent::Seek {
                    position_ms: position(a.get("position_ms").unwrap_or(&Value::Null))?,
                })
            }),
            "queue_add" => args().and_then(|a| {
                Ok(Intent::QueueAdd {
                    item_ref: item_ref(a.get("item_ref").unwrap_or(&Value::Null))?,
                })
            }),
            // Removal matches by equality, so anything that is not a string is simply not queued.
            "queue_remove" => args().and_then(|a| match a.get("item_ref") {
                Some(Value::String(r)) => Ok(Intent::QueueRemove {
                    item_ref: r.clone(),
                }),
                _ => Err(IntentError::NotInQueue),
            }),
            "skip" => args().map(|_| Intent::Skip),
            _ => return None,
        };
        Some(parsed)
    }
}

fn item_ref(v: &Value) -> Result<String, IntentError> {
    match v {
        Value::String(s) if is_item_ref(s) => Ok(s.clone()),
        _ => Err(IntentError::InvalidItemRef),
    }
}

fn position(v: &Value) -> Result<i64, IntentError> {
    as_safe_integer(v)
        .filter(|p| *p >= 0)
        .ok_or(IntentError::InvalidPosition)
}

fn truncate(s: &str) -> String {
    s.chars().take(32).collect()
}

fn parse_hello(msg: &Map<String, Value>) -> Result<ClientMsg, ParseError> {
    let invalid = ParseError::Invalid("hello");
    if msg.get("proto").and_then(as_safe_integer) != Some(1) {
        return Err(invalid);
    }
    let info = msg.get("client").and_then(Value::as_object);
    let field = |k: &str| info.and_then(|i| i.get(k)).and_then(Value::as_str);
    match (field("id"), field("name"), field("ver")) {
        (Some(id), Some(name), Some(ver)) if !id.is_empty() => Ok(ClientMsg::Hello(ClientInfo {
            id: id.into(),
            name: name.into(),
            ver: ver.into(),
        })),
        _ => Err(invalid),
    }
}

fn parse_clock_ping(msg: &Map<String, Value>) -> Result<ClientMsg, ParseError> {
    match (msg.get("ping_id"), msg.get("t0").and_then(as_safe_integer)) {
        (Some(Value::String(ping_id)), Some(t0)) => Ok(ClientMsg::ClockPing {
            ping_id: ping_id.clone(),
            t0,
        }),
        _ => Err(ParseError::Invalid("clock_ping")),
    }
}

fn parse_intent(msg: &Map<String, Value>) -> Result<ClientMsg, ParseError> {
    let op = msg.get("op").and_then(Value::as_str);
    let intent = op
        .and_then(|op| Intent::parse(op, msg.get("args")))
        .ok_or_else(|| ParseError::UnknownOp(truncate(op.unwrap_or("(none)"))))?;
    let id = msg.get("id").and_then(Value::as_str).map(str::to_owned);
    Ok(ClientMsg::Intent { id, intent })
}

fn parse_report(msg: &Map<String, Value>) -> Result<ClientMsg, ParseError> {
    const INVALID: ParseError = ParseError::Invalid("report");
    let activity_id = match msg.get("activity_id") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(_) => return Err(INVALID),
    };
    let o = msg
        .get("observed")
        .and_then(Value::as_object)
        .ok_or(INVALID)?;
    let num = |k: &str| o.get(k).and_then(Value::as_f64);
    match (
        num("offset_ms"),
        num("rtt_ms"),
        num("drift_ms"),
        o.get("source").and_then(Value::as_str),
    ) {
        (Some(offset_ms), Some(rtt_ms), Some(drift_ms), Some(source)) => Ok(ClientMsg::Report {
            activity_id,
            observed: Observed {
                offset_ms,
                rtt_ms,
                drift_ms,
                source: source.into(),
            },
        }),
        _ => Err(INVALID),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PresenceAction {
    Join,
    Leave,
}

#[derive(Debug, Serialize)]
pub struct Snapshot<'a> {
    pub rev: u64,
    pub playback: Option<&'a Playback>,
    pub queue: &'a [QueueItem],
    pub presence: Vec<&'a Member>,
}

/// A server message body; [`encode`] wraps it in the envelope.
#[derive(Debug, Serialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ServerMsg<'a> {
    Welcome {
        snapshot: Snapshot<'a>,
        server_now: i64,
    },
    ClockPong {
        ping_id: &'a str,
        t0: i64,
        t1: i64,
        t2: i64,
    },
    State {
        rev: u64,
        playback: Option<&'a Playback>,
        queue: &'a [QueueItem],
    },
    Presence {
        user_id: &'a str,
        name: &'a str,
        action: PresenceAction,
    },
    Reject {
        code: &'a str,
        message: &'a str,
        #[serde(skip_serializing_if = "Option::is_none")]
        req_id: Option<&'a str>,
    },
}

#[derive(Serialize)]
struct Envelope<'a> {
    v: u8,
    room: &'a str,
    seq: u64,
    ts: i64,
    from: &'a str,
    #[serde(flatten)]
    msg: &'a ServerMsg<'a>,
}

/// Serializes `msg` in a v1 envelope from `"server"`.
pub fn encode(room: &str, seq: u64, ts: i64, msg: &ServerMsg<'_>) -> String {
    let envelope = Envelope {
        v: 1,
        room,
        seq,
        ts,
        from: "server",
        msg,
    };
    serde_json::to_string(&envelope).expect("server messages always serialize")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const FILM: &str =
        "file:sha256p:1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn parse(v: Value) -> Result<ClientMsg, ParseError> {
        ClientMsg::parse(&v.to_string())
    }

    fn intent(op: &str, args: Value) -> Result<ClientMsg, ParseError> {
        parse(json!({ "v": 1, "t": "intent", "op": op, "args": args }))
    }

    fn refused(e: IntentError) -> Result<ClientMsg, ParseError> {
        Ok(ClientMsg::Intent {
            id: None,
            intent: Err(e),
        })
    }

    #[test]
    fn envelope_errors_are_ignorable() {
        assert_eq!(ClientMsg::parse("{nope"), Err(ParseError::MalformedJson));
        assert_eq!(ClientMsg::parse(""), Err(ParseError::MalformedJson));
        for raw in [
            "null",
            "[]",
            "42",
            r#"{"t":"hello"}"#,
            r#"{"v":2,"t":"hello"}"#,
            r#"{"v":1,"t":7}"#,
        ] {
            assert_eq!(
                ClientMsg::parse(raw),
                Err(ParseError::NotV1Envelope),
                "{raw}"
            );
        }
        assert_eq!(
            parse(json!({ "v": 1, "t": "state" })),
            Err(ParseError::UnknownType("state".into()))
        );
        assert_eq!(
            intent("explode", json!({})),
            Err(ParseError::UnknownOp("explode".into()))
        );
    }

    #[test]
    fn integers_follow_number_is_safe_integer() {
        let ping =
            |t0: Value| parse(json!({ "v": 1.0, "t": "clock_ping", "ping_id": "p", "t0": t0 }));
        let ok = |t0| {
            Ok(ClientMsg::ClockPing {
                ping_id: "p".into(),
                t0,
            })
        };
        assert_eq!(ping(json!(1000)), ok(1000));
        assert_eq!(ping(json!(1000.0)), ok(1000));
        assert_eq!(ping(json!(-5)), ok(-5));
        assert_eq!(ping(json!(MAX_SAFE_INTEGER)), ok(MAX_SAFE_INTEGER));
        for bad in [
            json!(MAX_SAFE_INTEGER + 1),
            json!(1.5),
            json!("1"),
            json!(null),
        ] {
            assert_eq!(ping(bad), Err(ParseError::Invalid("clock_ping")));
        }
    }

    #[test]
    fn intent_args_are_validated_like_the_reference() {
        let ok = |i| {
            Ok(ClientMsg::Intent {
                id: None,
                intent: Ok(i),
            })
        };
        assert_eq!(
            intent("play", json!({})),
            ok(Intent::Play {
                item_ref: None,
                position_ms: None
            })
        );
        assert_eq!(
            intent("play", json!({ "item_ref": FILM, "position_ms": 5.0 })),
            ok(Intent::Play {
                item_ref: Some(FILM.into()),
                position_ms: Some(5)
            })
        );
        assert_eq!(
            intent("play", json!({ "item_ref": null })),
            refused(IntentError::InvalidItemRef)
        );
        assert_eq!(
            intent("play", json!({ "position_ms": -1 })),
            refused(IntentError::InvalidPosition)
        );
        assert_eq!(
            intent("seek", json!({})),
            refused(IntentError::InvalidPosition)
        );
        assert_eq!(
            intent("queue_add", json!({ "item_ref": "x" })),
            refused(IntentError::InvalidItemRef)
        );
        assert_eq!(
            intent("queue_remove", json!({ "item_ref": 3 })),
            refused(IntentError::NotInQueue)
        );
        assert_eq!(
            intent("pause", json!("nope")),
            refused(IntentError::ArgsNotObject)
        );
        assert_eq!(
            parse(json!({ "v": 1, "t": "intent", "op": "skip", "args": {}, "id": "r1" })),
            Ok(ClientMsg::Intent {
                id: Some("r1".into()),
                intent: Ok(Intent::Skip)
            })
        );
    }

    #[test]
    fn hello_and_report_validation() {
        let hello = |proto: Value, id: &str| {
            parse(
                json!({ "v": 1, "t": "hello", "proto": proto, "client": { "id": id, "name": "n", "ver": "1" } }),
            )
        };
        assert!(matches!(hello(json!(1), "alice"), Ok(ClientMsg::Hello(_))));
        assert_eq!(hello(json!(2), "alice"), Err(ParseError::Invalid("hello")));
        assert_eq!(hello(json!(1), ""), Err(ParseError::Invalid("hello")));

        let observed = json!({ "offset_ms": 1.5, "rtt_ms": 12, "drift_ms": -3, "source": "mpv" });
        let report = |activity_id: Option<Value>| {
            let mut m = json!({ "v": 1, "t": "report", "observed": observed });
            if let Some(a) = activity_id {
                m["activity_id"] = a;
            }
            parse(m)
        };
        for (activity_id, expected) in [
            (None, None),
            (Some(json!(null)), None),
            (Some(json!("watch@1")), Some("watch@1".to_string())),
        ] {
            match report(activity_id) {
                Ok(ClientMsg::Report {
                    activity_id,
                    observed,
                }) => {
                    assert_eq!(activity_id, expected);
                    assert_eq!(observed.rtt_ms, 12.0);
                }
                other => panic!("unexpected {other:?}"),
            }
        }
        assert_eq!(report(Some(json!(7))), Err(ParseError::Invalid("report")));
    }

    #[test]
    fn encode_wraps_the_body_in_a_server_envelope() {
        let msg = ServerMsg::Reject {
            code: INTENT_REJECTED,
            message: "nothing is playing",
            req_id: None,
        };
        let v: Value = serde_json::from_str(&encode("r1", 3, 10, &msg)).unwrap();
        assert_eq!(
            v,
            json!({ "v": 1, "t": "reject", "room": "r1", "seq": 3, "ts": 10, "from": "server",
                    "code": "intent_rejected", "message": "nothing is playing" })
        );
    }
}
