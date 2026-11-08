//! The room state machine. Synchronous: callers hold the room lock for one message at a time,
//! so every client's queue receives broadcasts in `seq` order.

use std::collections::{HashMap, VecDeque};
use std::fmt::Display;
use std::sync::Arc;

use tokio::sync::mpsc::UnboundedSender;
use wt_protocol::{
    ClientInfo, ClientMsg, INTENT_REJECTED, Intent, IntentError, Member, Meta, Observed, Playback,
    PresenceAction, QueueItem, ServerMsg, Snapshot, encode,
};

use crate::clock::server_now;
use crate::observability::Counters;
use crate::store::Store;

pub type ConnId = u64;

/// The latest `report` from one connection. Stored, never broadcast.
#[derive(Debug, Clone, PartialEq)]
pub struct Report {
    pub activity_id: Option<String>,
    pub observed: Observed,
    pub received_ms: i64,
}

struct Client {
    tx: UnboundedSender<Outgoing>,
    expected_sub: Option<String>,
    /// `None` until a valid `hello`.
    user_id: Option<String>,
    report: Option<Report>,
}

pub enum Outgoing {
    Text(String),
    IdentityMismatch,
    Expired,
    Full,
    Kicked,
}

/// One user, however many connections they have open.
struct Presence {
    member: Member,
    connections: usize,
}

pub struct Room {
    pub id: String,
    pub created_ms: i64,
    pub expires_ms: i64,
    pub host_id: Option<String>,
    pub host_name: Option<String>,
    pub guild_id: Option<String>,
    pub voice_channel_id: Option<String>,
    pub controls: String,
    pub locked: bool,
    pub degraded: bool,
    pub expired: bool,
    pub(crate) store: Option<Arc<Store>>,
    pub(crate) ttl_ms: i64,
    pub(crate) max_members: usize,
    /// Room state revision: bumped when playback, queue or meta changes.
    pub rev: u64,
    /// Envelope sequence: bumped on every broadcast, presence included.
    pub seq: u64,
    pub playback: Option<Playback>,
    pub queue: Vec<QueueItem>,
    pub(crate) corrections: u64,
    drift: VecDeque<f64>,
    pub(crate) counters: Option<Arc<Counters>>,
    clients: HashMap<ConnId, Client>,
    /// In join order; each `user_id` once.
    presence: Vec<Presence>,
    next_conn: ConnId,
}

impl Room {
    pub fn new(id: String) -> Self {
        Room {
            id,
            created_ms: server_now(),
            expires_ms: 0,
            host_id: None,
            host_name: None,
            guild_id: None,
            voice_channel_id: None,
            controls: "host".into(),
            locked: false,
            degraded: false,
            expired: false,
            store: None,
            ttl_ms: 24 * 60 * 60 * 1000,
            max_members: 50,
            rev: 0,
            seq: 0,
            playback: None,
            queue: Vec::new(),
            corrections: 0,
            drift: VecDeque::new(),
            counters: None,
            clients: HashMap::new(),
            presence: Vec::new(),
            next_conn: 0,
        }
    }

    /// Attached connections, including those that have not sent `hello` yet.
    pub fn client_count(&self) -> usize {
        self.clients.len()
    }

    pub fn member_count(&self) -> usize {
        self.presence.len()
    }

    pub fn members(&self) -> Vec<Member> {
        self.presence.iter().map(|p| p.member.clone()).collect()
    }

    pub(crate) fn drift_quantiles(&self) -> (Option<f64>, Option<f64>) {
        if self.drift.is_empty() {
            return (None, None);
        }
        let mut sorted: Vec<_> = self.drift.iter().copied().collect();
        sorted.sort_by(f64::total_cmp);
        let quantile = |q: f64| sorted[((sorted.len() - 1) as f64 * q).ceil() as usize];
        (Some(quantile(0.5)), Some(quantile(0.95)))
    }

    pub fn expire(&mut self) {
        self.expired = true;
        for client in self.clients.values() {
            let _ = client.tx.send(Outgoing::Expired);
        }
    }

    pub(crate) fn persist(&mut self) {
        if let Some(store) = &self.store
            && let Err(e) = store.save(self)
        {
            eprintln!("[db] room {} write failed: {e}", self.id);
            self.degraded = true;
        }
    }

    fn activity(&mut self) {
        self.expires_ms = server_now().saturating_add(self.ttl_ms);
        self.persist();
    }

    fn persist_member(&mut self, user_id: &str, name: Option<&str>) {
        if let Some(store) = &self.store
            && let Err(e) = store.member(self, user_id, name)
        {
            eprintln!("[db] room {} member write failed: {e}", self.id);
            self.degraded = true;
        }
    }

    /// The latest report from any connection of `user_id`.
    pub fn report_for(&self, user_id: &str) -> Option<&Report> {
        self.clients
            .values()
            .filter(|c| c.user_id.as_deref() == Some(user_id))
            .find_map(|c| c.report.as_ref())
    }

    pub fn attach(
        &mut self,
        tx: UnboundedSender<Outgoing>,
        expected_sub: Option<String>,
    ) -> ConnId {
        let conn = self.next_conn;
        self.next_conn += 1;
        let client = Client {
            tx,
            expected_sub,
            user_id: None,
            report: None,
        };
        self.clients.insert(conn, client);
        conn
    }

    pub fn detach(&mut self, conn: ConnId) {
        if self.expired {
            self.clients.remove(&conn);
            return;
        }
        let Some(user_id) = self.clients.remove(&conn).and_then(|c| c.user_id) else {
            return;
        };
        let Some(i) = self
            .presence
            .iter()
            .position(|p| p.member.user_id == user_id)
        else {
            return;
        };
        self.presence[i].connections -= 1;
        if self.presence[i].connections == 0 {
            let gone = self.presence.remove(i).member;
            self.broadcast_presence(&gone, PresenceAction::Leave, None);
        }
    }

    pub fn handle_message(&mut self, conn: ConnId, raw: &str, received_at: i64) {
        if self.expired {
            return;
        }
        let msg = match ClientMsg::parse(raw) {
            Ok(msg) => msg,
            Err(e) => return self.log(e),
        };
        let Some(client) = self.clients.get_mut(&conn) else {
            return;
        };
        if client.user_id.is_none() {
            match msg {
                ClientMsg::Hello(info) => self.on_hello(conn, info),
                other => self.log(format_args!("t={} before hello", other.kind())),
            }
            return;
        }
        match msg {
            ClientMsg::Hello(_) => self.log("t=hello after hello"),
            ClientMsg::ClockPing { ping_id, t0 } => {
                let pong = ServerMsg::ClockPong {
                    ping_id: &ping_id,
                    t0,
                    t1: received_at,
                    t2: server_now(),
                };
                self.send(conn, &pong);
            }
            ClientMsg::Intent { id, intent } => {
                let actor = client.user_id.clone().expect("hello completed");
                let op = intent.as_ref().map_or("invalid", |i| match i {
                    Intent::Play { .. } => "play",
                    Intent::Pause => "pause",
                    Intent::Seek { .. } => "seek",
                    Intent::Skip => "skip",
                    Intent::QueueAdd { .. } => "queue_add",
                    Intent::QueueRemove { .. } => "queue_remove",
                    Intent::SetControls { .. } => "set_controls",
                    Intent::Lock { .. } => "lock",
                    Intent::Kick { .. } => "kick",
                });
                let changes_playback = matches!(
                    &intent,
                    Ok(Intent::Play { .. } | Intent::Pause | Intent::Seek { .. } | Intent::Skip)
                );
                let host = self.host_id.as_deref() == Some(actor.as_str());
                if self.locked && !host && !matches!(&intent, Ok(Intent::Lock { .. })) {
                    self.reject_code(conn, id.as_deref(), "locked", "room locked", op);
                    return;
                }
                if let Ok(parsed) = &intent {
                    let restricted = matches!(
                        parsed,
                        Intent::SetControls { .. } | Intent::Lock { .. } | Intent::Kick { .. }
                    ) || (self.controls == "host"
                        && matches!(
                            parsed,
                            Intent::Play { .. }
                                | Intent::Pause
                                | Intent::Seek { .. }
                                | Intent::Skip
                        ));
                    if restricted && !host {
                        self.reject_code(conn, id.as_deref(), "not_host", "host only", op);
                        return;
                    }
                }
                if matches!(&intent, Ok(Intent::QueueAdd { .. })) && self.queue.len() >= 200 {
                    self.reject_limit(conn, id.as_deref(), op);
                    return;
                }
                match intent.and_then(|i| {
                    if let Intent::Kick { user_id } = i {
                        self.kick(&actor, &user_id)
                    } else {
                        self.apply(i, server_now()).map(|()| true)
                    }
                }) {
                    Ok(true) => {
                        self.record_intent(op, "ok");
                        if changes_playback {
                            self.corrections += 1;
                        }
                        self.broadcast_state();
                    }
                    Ok(false) => self.record_intent(op, "ok"),
                    Err(e) => self.reject(conn, id.as_deref(), e, op),
                }
            }
            ClientMsg::Report {
                activity_id,
                observed,
            } => {
                let drift_ms = observed.drift_ms;
                client.report = Some(Report {
                    activity_id,
                    observed,
                    received_ms: received_at,
                });
                if self.drift.len() == 500 {
                    self.drift.pop_front();
                }
                self.drift.push_back(drift_ms);
                let user_id = client.user_id.clone().unwrap_or_default();
                let report = client.report.clone().expect("just set");
                if let Some(store) = &self.store
                    && let Err(e) = store.report(self, &user_id, &report)
                {
                    eprintln!("[db] room {} report write failed: {e}", self.id);
                    self.degraded = true;
                }
            }
        }
    }

    fn on_hello(&mut self, conn: ConnId, info: ClientInfo) {
        let ClientInfo {
            id: user_id, name, ..
        } = info;
        if let Some(client) = self.clients.get(&conn)
            && client
                .expected_sub
                .as_deref()
                .is_some_and(|sub| sub != user_id)
        {
            let _ = client.tx.send(Outgoing::IdentityMismatch);
            return;
        }
        if self.presence.len() >= self.max_members
            && !self.presence.iter().any(|p| p.member.user_id == user_id)
        {
            if let Some(client) = self.clients.get(&conn) {
                let _ = client.tx.send(Outgoing::Full);
            }
            return;
        }
        if let Some(client) = self.clients.get_mut(&conn) {
            client.user_id = Some(user_id.clone());
        }
        let existing = self
            .presence
            .iter_mut()
            .find(|p| p.member.user_id == user_id);
        // A user's second connection joins silently; only their first is announced.
        let joined = match existing {
            Some(p) => {
                p.connections += 1;
                None
            }
            None => {
                let member = Member { user_id, name };
                self.presence.push(Presence {
                    member: member.clone(),
                    connections: 1,
                });
                Some(member)
            }
        };

        // Join first, so the welcome's seq is at least that of every event its snapshot reflects.
        if let Some(member) = joined {
            self.broadcast_presence(&member, PresenceAction::Join, Some(conn));
        }

        let welcome = ServerMsg::Welcome {
            snapshot: Snapshot {
                rev: self.rev,
                playback: self.playback.as_ref(),
                queue: &self.queue,
                presence: self.presence.iter().map(|p| &p.member).collect(),
                meta: self.meta(),
            },
            server_now: server_now(),
        };
        self.send(conn, &welcome);
    }

    /// Applies an accepted intent to playback/queue. On `Err` the room is untouched.
    fn apply(&mut self, intent: Intent, now: i64) -> Result<(), IntentError> {
        match intent {
            Intent::Play {
                item_ref,
                position_ms,
            } => {
                let item_ref = match item_ref {
                    Some(r) => r,
                    None => self
                        .playback
                        .as_ref()
                        .ok_or(IntentError::NothingPlaying)?
                        .item_ref
                        .clone(),
                };
                let resume_at = match &self.playback {
                    Some(pb) if pb.item_ref == item_ref => pb.position_at(now),
                    _ => 0,
                };
                self.playback = Some(Playback {
                    item_ref,
                    anchor_server_ms: now,
                    position_ms: position_ms.unwrap_or(resume_at),
                    rate: 1.0,
                    paused: false,
                });
            }
            Intent::Pause => {
                let pb = self.playback.as_mut().ok_or(IntentError::NothingPlaying)?;
                pb.position_ms = pb.position_at(now);
                pb.anchor_server_ms = now;
                pb.paused = true;
            }
            Intent::Seek { position_ms } => {
                let pb = self.playback.as_mut().ok_or(IntentError::NothingPlaying)?;
                pb.position_ms = position_ms;
                pb.anchor_server_ms = now;
            }
            Intent::QueueAdd { item_ref } => {
                self.queue.push(QueueItem { item_ref });
            }
            Intent::QueueRemove { item_ref } => {
                let i = self
                    .queue
                    .iter()
                    .position(|q| q.item_ref == item_ref)
                    .ok_or(IntentError::NotInQueue)?;
                self.queue.remove(i);
            }
            Intent::Skip if self.queue.is_empty() => {
                self.playback.take().ok_or(IntentError::NothingToSkip)?;
            }
            Intent::Skip => {
                let head = self.queue.remove(0);
                self.playback = Some(Playback {
                    item_ref: head.item_ref,
                    anchor_server_ms: now,
                    position_ms: 0,
                    rate: 1.0,
                    paused: false,
                });
            }
            Intent::SetControls { controls } => self.controls = controls,
            Intent::Lock { locked } => self.locked = locked,
            Intent::Kick { .. } => unreachable!("kick handled separately"),
        }
        Ok(())
    }

    fn kick(&mut self, actor: &str, user_id: &str) -> Result<bool, IntentError> {
        if actor == user_id {
            return Err(IntentError::CannotKickSelf);
        }
        let targets: Vec<_> = self
            .clients
            .iter()
            .filter(|(_, c)| c.user_id.as_deref() == Some(user_id))
            .map(|(id, _)| *id)
            .collect();
        if targets.is_empty() {
            return Err(IntentError::InvalidUserId);
        }
        for id in targets {
            if let Some(client) = self.clients.get(&id) {
                let _ = client.tx.send(Outgoing::Kicked);
            }
            self.detach(id);
        }
        Ok(false)
    }

    fn meta(&self) -> Meta<'_> {
        Meta {
            host_id: self.host_id.as_deref().unwrap_or(""),
            host_name: self.host_name.as_deref().unwrap_or(""),
            controls: &self.controls,
            locked: self.locked,
        }
    }

    fn record_intent(&self, op: &str, result: &'static str) {
        if let Some(counters) = &self.counters {
            counters.intent(op, result);
        }
    }

    fn reject(&self, conn: ConnId, req_id: Option<&str>, e: IntentError, op: &str) {
        eprintln!("[room {}] rejected intent: {e}", self.id);
        self.reject_code(conn, req_id, INTENT_REJECTED, &e.to_string(), op);
    }

    fn reject_code(
        &self,
        conn: ConnId,
        req_id: Option<&str>,
        code: &'static str,
        message: &str,
        op: &str,
    ) {
        self.record_intent(op, "reject");
        if let Some(counters) = &self.counters {
            counters.reject(code);
        }
        let reject = ServerMsg::Reject {
            code,
            message,
            req_id,
        };
        self.send(conn, &reject);
    }

    fn reject_limit(&self, conn: ConnId, req_id: Option<&str>, op: &str) {
        self.reject_code(conn, req_id, "limit", "queue is full", op);
    }

    pub(crate) fn broadcast_state(&mut self) {
        self.rev += 1;
        self.seq += 1;
        self.activity();
        self.broadcast_state_current();
    }

    fn broadcast_state_current(&mut self) {
        let state = ServerMsg::State {
            rev: self.rev,
            playback: self.playback.as_ref(),
            queue: &self.queue,
            meta: self.meta(),
        };
        self.fan_out(&self.encode(&state), None);
    }

    fn broadcast_presence(
        &mut self,
        member: &Member,
        action: PresenceAction,
        except: Option<ConnId>,
    ) {
        self.seq += 1;
        self.activity();
        match action {
            PresenceAction::Join => self.persist_member(&member.user_id, Some(&member.name)),
            PresenceAction::Leave => self.persist_member(&member.user_id, None),
        }
        let presence = ServerMsg::Presence {
            user_id: &member.user_id,
            name: &member.name,
            action,
        };
        self.fan_out(&self.encode(&presence), except);
    }

    fn encode(&self, msg: &ServerMsg<'_>) -> String {
        encode(&self.id, self.seq, server_now(), msg)
    }

    /// Unicast; does not bump `seq`.
    fn send(&self, conn: ConnId, msg: &ServerMsg<'_>) {
        if let Some(c) = self.clients.get(&conn) {
            // A closed receiver means the connection is going away; detach follows.
            let _ = c.tx.send(Outgoing::Text(self.encode(msg)));
        }
    }

    /// To every connection that has said `hello`, except `except`.
    fn fan_out(&self, data: &str, except: Option<ConnId>) {
        for (conn, c) in &self.clients {
            if c.user_id.is_some() && Some(*conn) != except {
                let _ = c.tx.send(Outgoing::Text(data.to_owned()));
            }
        }
    }

    fn log(&self, reason: impl Display) {
        eprintln!("[room {}] ignored: {reason}", self.id);
    }
}
