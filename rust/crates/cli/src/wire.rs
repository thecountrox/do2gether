//! Client side of the wire: outbound envelopes and the inbound messages the client acts on.

use serde_json::{Value, json};
use wt_protocol::Playback;

/// Builds outbound messages: `{v:1, t, room, seq, ts, from, ...}` with a per-client `seq`.
pub struct Outbox {
    room: String,
    from: String,
    seq: u64,
}

impl Outbox {
    pub fn new(room: &str, from: &str) -> Self {
        Outbox {
            room: room.to_owned(),
            from: from.to_owned(),
            seq: 0,
        }
    }

    /// `ts` is the sender's server-time estimate.
    fn envelope(&mut self, t: &str, ts: i64, body: Value) -> String {
        let mut msg = json!({
            "v": 1, "t": t, "room": self.room, "seq": self.seq, "ts": ts, "from": self.from,
        });
        self.seq += 1;
        if let (Some(fields), Value::Object(body)) = (msg.as_object_mut(), body) {
            fields.extend(body);
        }
        msg.to_string()
    }

    pub fn hello(&mut self, ts: i64, name: &str, source: &str) -> String {
        let client = json!({ "id": self.from, "name": name, "ver": env!("CARGO_PKG_VERSION") });
        let body = json!({ "proto": 1, "client": client, "caps": [format!("player:{source}")] });
        self.envelope("hello", ts, body)
    }

    pub fn clock_ping(&mut self, ts: i64, ping_id: &str, t0: i64) -> String {
        self.envelope("clock_ping", ts, json!({ "ping_id": ping_id, "t0": t0 }))
    }

    /// `id` is `i<seq>`, so a `reject.req_id` names the intent it refuses.
    pub fn intent(&mut self, ts: i64, op: &str, args: Value) -> String {
        let id = format!("i{}", self.seq);
        self.envelope("intent", ts, json!({ "id": id, "op": op, "args": args }))
    }

    pub fn report(
        &mut self,
        ts: i64,
        offset_ms: f64,
        rtt_ms: f64,
        drift_ms: f64,
        source: &str,
    ) -> String {
        let observed = json!({ "offset_ms": offset_ms, "rtt_ms": rtt_ms, "drift_ms": drift_ms, "source": source });
        self.envelope(
            "report",
            ts,
            json!({ "activity_id": null, "observed": observed }),
        )
    }
}

/// A server message the client acts on. Everything else (`event`, unknown `t`) is `Other`.
#[derive(Debug, Clone, PartialEq)]
pub enum Inbound {
    Welcome {
        rev: u64,
        playback: Option<Playback>,
        presence: usize,
    },
    State {
        rev: u64,
        playback: Option<Playback>,
    },
    Pong {
        ping_id: String,
        t1: f64,
        t2: f64,
    },
    Presence {
        name: String,
        joined: bool,
    },
    Reject {
        message: String,
    },
    Other,
}

impl Inbound {
    pub fn parse(text: &str) -> Inbound {
        let Ok(m) = serde_json::from_str::<Value>(text) else {
            return Inbound::Other;
        };
        if m["v"] != 1 {
            return Inbound::Other;
        }
        let playback = |v: &Value| serde_json::from_value::<Option<Playback>>(v.clone()).ok();
        let parsed = match m["t"].as_str().unwrap_or("") {
            "welcome" => {
                let s = &m["snapshot"];
                s["rev"]
                    .as_u64()
                    .zip(playback(&s["playback"]))
                    .map(|(rev, playback)| Inbound::Welcome {
                        rev,
                        playback,
                        presence: s["presence"].as_array().map_or(0, Vec::len),
                    })
            }
            "state" => m["rev"]
                .as_u64()
                .zip(playback(&m["playback"]))
                .map(|(rev, playback)| Inbound::State { rev, playback }),
            "clock_pong" => match (m["ping_id"].as_str(), m["t1"].as_f64(), m["t2"].as_f64()) {
                (Some(id), Some(t1), Some(t2)) => Some(Inbound::Pong {
                    ping_id: id.to_owned(),
                    t1,
                    t2,
                }),
                _ => None,
            },
            "presence" => Some(Inbound::Presence {
                name: m["name"]
                    .as_str()
                    .or(m["user_id"].as_str())
                    .unwrap_or("?")
                    .to_owned(),
                joined: m["action"] == "join",
            }),
            "reject" => Some(Inbound::Reject {
                message: m["message"].as_str().unwrap_or("rejected").to_owned(),
            }),
            _ => None,
        };
        parsed.unwrap_or(Inbound::Other)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::support::validate_message;

    fn valid(raw: &str) -> Value {
        let v: Value = serde_json::from_str(raw).unwrap();
        assert_eq!(validate_message(&v), Vec::<String>::new(), "{raw}");
        v
    }

    #[test]
    fn every_outbound_message_validates_against_the_schema() {
        let mut out = Outbox::new("k3x9a0qz", "wt-1-2");
        let ts = 1_762_500_000_000;
        let hello = valid(&out.hello(ts, "ann", "mpv"));
        assert_eq!(hello["caps"], json!(["player:mpv"]));
        valid(&out.clock_ping(ts, "p0", ts));
        let film =
            "file:sha256p:1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
        valid(&out.intent(ts, "play", json!({ "item_ref": film })));
        valid(&out.intent(ts, "pause", json!({})));
        let seek = valid(&out.intent(ts, "seek", json!({ "position_ms": 42000 })));
        assert_eq!(seek["id"], "i4");
        let report = valid(&out.report(ts, 0.4, 1.2, -3.0, "simulate"));
        assert_eq!(report["activity_id"], Value::Null);
        assert_eq!(report["seq"], 5, "seq is monotonic per client");
    }

    #[test]
    fn inbound_parsing_keeps_what_the_client_needs() {
        let state = r#"{"v":1,"t":"state","room":"r","seq":3,"ts":5,"from":"server","rev":2,
            "playback":{"item_ref":"yt:dQw4w9WgXcQ","anchor_server_ms":10,"position_ms":42000,"rate":1,"paused":false},
            "queue":[]}"#;
        match Inbound::parse(state) {
            Inbound::State {
                rev: 2,
                playback: Some(pb),
            } => assert_eq!(pb.position_at(1010), 43000),
            other => panic!("{other:?}"),
        }
        let welcome = r#"{"v":1,"t":"welcome","room":"r","seq":1,"ts":5,"from":"server",
            "snapshot":{"rev":0,"playback":null,"queue":[],"presence":[{"user_id":"a","name":"a"}]},"server_now":5}"#;
        assert_eq!(
            Inbound::parse(welcome),
            Inbound::Welcome {
                rev: 0,
                playback: None,
                presence: 1
            }
        );
        assert_eq!(Inbound::parse("{nope"), Inbound::Other);
        assert_eq!(
            Inbound::parse(r#"{"v":1,"t":"event","kind":"x","data":{}}"#),
            Inbound::Other
        );
        assert_eq!(
            Inbound::parse(r#"{"v":2,"t":"reject","message":"x"}"#),
            Inbound::Other
        );
    }
}
