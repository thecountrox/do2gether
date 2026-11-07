//! SQLite durability. Callers hold the room mutex while writing; memory remains authoritative.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, params};

use crate::clock::server_now;
use crate::room::{Report, Room};

pub struct Store(Mutex<Connection>);

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let db = Connection::open(path)?;
        db.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;",
        )?;
        let version: i64 = db.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version == 0 {
            db.execute_batch(
                "BEGIN;
                 CREATE TABLE rooms (id TEXT PRIMARY KEY, created_ms INTEGER NOT NULL,
                   host_id TEXT, host_name TEXT, guild_id TEXT, voice_channel_id TEXT,
                   controls TEXT NOT NULL, locked INTEGER NOT NULL, rev INTEGER NOT NULL,
                   seq INTEGER NOT NULL, playback_json TEXT NOT NULL, queue_json TEXT NOT NULL,
                   expires_ms INTEGER NOT NULL);
                 CREATE TABLE members (room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
                   user_id TEXT NOT NULL, name TEXT NOT NULL, joined_ms INTEGER NOT NULL,
                   PRIMARY KEY(room_id, user_id));
                 CREATE TABLE reports (room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
                   user_id TEXT NOT NULL, received_ms INTEGER NOT NULL, offset_ms REAL NOT NULL,
                   rtt_ms REAL NOT NULL, drift_ms REAL NOT NULL, source TEXT NOT NULL,
                   PRIMARY KEY(room_id, user_id));
                 PRAGMA user_version=1; COMMIT;",
            )?;
        } else if version != 1 {
            return Err(rusqlite::Error::InvalidQuery);
        }
        Ok(Self(Mutex::new(db)))
    }

    pub fn load(&self) -> rusqlite::Result<Vec<Room>> {
        let mut db = crate::lock(&self.0);
        let tx = db.transaction()?;
        tx.execute("DELETE FROM rooms WHERE expires_ms < ?1", [server_now()])?;
        // All sockets are gone on restart; presence is rebuilt from new connections.
        tx.execute("DELETE FROM members", [])?;
        let mut rooms = Vec::new();
        {
            let mut stmt = tx.prepare("SELECT id, created_ms, host_id, host_name, guild_id,
                voice_channel_id, controls, locked, rev, seq, playback_json, queue_json, expires_ms FROM rooms")?;
            let rows = stmt.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, bool>(7)?,
                    row.get::<_, u64>(8)?,
                    row.get::<_, u64>(9)?,
                    row.get::<_, String>(10)?,
                    row.get::<_, String>(11)?,
                    row.get::<_, i64>(12)?,
                ))
            })?;
            for row in rows {
                let (
                    id,
                    created_ms,
                    host_id,
                    host_name,
                    guild_id,
                    voice_channel_id,
                    controls,
                    locked,
                    rev,
                    seq,
                    playback,
                    queue,
                    expires_ms,
                ) = row?;
                match (
                    serde_json::from_str(&playback),
                    serde_json::from_str(&queue),
                ) {
                    (Ok(playback), Ok(queue)) => {
                        let mut room = Room::new(id);
                        room.created_ms = created_ms;
                        room.host_id = host_id;
                        room.host_name = host_name;
                        room.guild_id = guild_id;
                        room.voice_channel_id = voice_channel_id;
                        room.controls = controls;
                        room.locked = locked;
                        room.rev = rev;
                        room.seq = seq;
                        room.playback = playback;
                        room.queue = queue;
                        room.expires_ms = expires_ms;
                        rooms.push(room);
                    }
                    _ => eprintln!("[db] skipping room {id}: invalid playback or queue JSON"),
                }
            }
        }
        tx.commit()?;
        Ok(rooms)
    }

    pub fn save(&self, room: &Room) -> rusqlite::Result<()> {
        crate::lock(&self.0).execute(
            "INSERT INTO rooms (id, created_ms, host_id, host_name, guild_id, voice_channel_id,
              controls, locked, rev, seq, playback_json, queue_json, expires_ms)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
             ON CONFLICT(id) DO UPDATE SET host_id=excluded.host_id, host_name=excluded.host_name,
              guild_id=excluded.guild_id, voice_channel_id=excluded.voice_channel_id,
              controls=excluded.controls, locked=excluded.locked, rev=excluded.rev, seq=excluded.seq,
              playback_json=excluded.playback_json, queue_json=excluded.queue_json,
              expires_ms=excluded.expires_ms",
            params![room.id, room.created_ms, room.host_id, room.host_name, room.guild_id,
                room.voice_channel_id, room.controls, room.locked, room.rev, room.seq,
                serde_json::to_string(&room.playback).expect("playback serializes"),
                serde_json::to_string(&room.queue).expect("queue serializes"), room.expires_ms],
        )?;
        Ok(())
    }

    pub fn member(&self, room: &Room, user_id: &str, name: Option<&str>) -> rusqlite::Result<()> {
        let db = crate::lock(&self.0);
        if let Some(name) = name {
            db.execute(
                "INSERT INTO members (room_id,user_id,name,joined_ms) VALUES (?1,?2,?3,?4)
                ON CONFLICT(room_id,user_id) DO UPDATE SET name=excluded.name",
                params![room.id, user_id, name, server_now()],
            )?;
        } else {
            db.execute(
                "DELETE FROM members WHERE room_id=?1 AND user_id=?2",
                params![room.id, user_id],
            )?;
        }
        Ok(())
    }

    pub fn report(&self, room: &Room, user_id: &str, report: &Report) -> rusqlite::Result<()> {
        crate::lock(&self.0).execute(
            "INSERT INTO reports (room_id,user_id,received_ms,offset_ms,rtt_ms,drift_ms,source)
             VALUES (?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(room_id,user_id) DO UPDATE SET received_ms=excluded.received_ms,
              offset_ms=excluded.offset_ms,rtt_ms=excluded.rtt_ms,drift_ms=excluded.drift_ms,
              source=excluded.source",
            params![
                room.id,
                user_id,
                report.received_ms,
                report.observed.offset_ms,
                report.observed.rtt_ms,
                report.observed.drift_ms,
                report.observed.source
            ],
        )?;
        Ok(())
    }

    pub fn delete(&self, id: &str) -> rusqlite::Result<()> {
        crate::lock(&self.0).execute("DELETE FROM rooms WHERE id=?1", [id])?;
        Ok(())
    }

    pub fn exists(&self, id: &str) -> rusqlite::Result<bool> {
        crate::lock(&self.0)
            .query_row("SELECT 1 FROM rooms WHERE id=?1", [id], |r| {
                r.get::<_, i64>(0)
            })
            .optional()
            .map(|v| v.is_some())
    }
}
