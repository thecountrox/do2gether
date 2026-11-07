//! Command-line flags. Hand-rolled: ten flags do not justify a parser dependency.

use std::path::PathBuf;

pub const USAGE: &str = "\
usage: wt-play (--create | --room <id> --token <token>) [--file <path> | --simulate] [options]

  --server <url>      default http://127.0.0.1:8787
  --room <id>         join an existing room
  --token <token>     join token for --room
  --create            POST /rooms, then join it (prints room id + share line)
  --file <path>       media file (required unless --simulate)
  --name <name>       display name (default: hostname)
  --mpv <path>        default \"mpv\"
  --headless          pass --vo=null --ao=null --no-terminal to mpv (CI)
  --simulate          virtual player (wall clock) instead of mpv; used by tests

stdin: play | pause | seek <ms> | q";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Join {
    Create,
    Room { id: String, token: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Args {
    pub server: String,
    pub join: Join,
    pub file: Option<PathBuf>,
    pub name: String,
    pub mpv: String,
    pub headless: bool,
    pub simulate: bool,
}

/// `Ok(None)` means `--help`.
pub fn parse(argv: impl IntoIterator<Item = String>) -> Result<Option<Args>, String> {
    let mut argv = argv.into_iter();
    let (mut server, mut room, mut token, mut file, mut name, mut mpv) =
        (None, None, None, None, None, None);
    let (mut create, mut headless, mut simulate) = (false, false, false);
    while let Some(flag) = argv.next() {
        let mut value = || argv.next().ok_or(format!("{flag} needs a value"));
        match flag.as_str() {
            "--server" => server = Some(value()?),
            "--room" => room = Some(value()?),
            "--token" => token = Some(value()?),
            "--file" => file = Some(PathBuf::from(value()?)),
            "--name" => name = Some(value()?),
            "--mpv" => mpv = Some(value()?),
            "--create" => create = true,
            "--headless" => headless = true,
            "--simulate" => simulate = true,
            "-h" | "--help" => return Ok(None),
            other => return Err(format!("unknown argument {other:?}")),
        }
    }
    let join = match (create, room, token) {
        (true, None, None) => Join::Create,
        (false, Some(id), Some(token)) => Join::Room { id, token },
        (true, _, _) => return Err("--create cannot be combined with --room/--token".into()),
        (false, Some(_), None) => return Err("--room needs --token".into()),
        (false, None, Some(_)) => return Err("--token needs --room".into()),
        (false, None, None) => return Err("give --create or --room <id> --token <token>".into()),
    };
    if file.is_none() && !simulate {
        return Err("--file is required unless --simulate".into());
    }
    Ok(Some(Args {
        server: server.unwrap_or_else(|| "http://127.0.0.1:8787".into()),
        join,
        file,
        name: name.unwrap_or_else(hostname),
        mpv: mpv.unwrap_or_else(|| "mpv".into()),
        headless,
        simulate,
    }))
}

fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .or_else(|| std::env::var("HOSTNAME").ok())
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .map(|h| h.trim().to_owned())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "wt-play".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &str) -> Result<Option<Args>, String> {
        parse(s.split_whitespace().map(String::from))
    }

    #[test]
    fn flags_parse_and_conflicts_are_refused() {
        let a = args("--room r1 --token t --file /tmp/a.mp4 --name ann --headless")
            .unwrap()
            .unwrap();
        assert_eq!(a.server, "http://127.0.0.1:8787");
        assert_eq!(
            a.join,
            Join::Room {
                id: "r1".into(),
                token: "t".into()
            }
        );
        assert_eq!(a.name, "ann");
        assert_eq!(a.mpv, "mpv");
        assert!(a.headless && !a.simulate);
        assert_eq!(
            args("--create --simulate").unwrap().unwrap().join,
            Join::Create
        );
        assert_eq!(args("--help"), Ok(None));
        assert!(args("--create").is_err(), "no --file and no --simulate");
        assert!(args("--create --room r --token t --simulate").is_err());
        assert!(args("--room r --simulate").is_err());
        assert!(args("--simulate").is_err());
        assert!(args("--create --simulate --server").is_err());
        assert!(args("--create --simulate --bogus").is_err());
    }
}
