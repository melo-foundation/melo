// Discord status: "Listening to melo" with the track, its artwork and a progress
// bar, over the Discord desktop app's local IPC socket (Vesktop's arRPC too).
// Off unless the user turns on Settings → General → Discord status.
//
// Frames are an int32 LE opcode, an int32 LE length and JSON: 0 handshake,
// 1 frame, 2 close, 3 ping, 4 pong. plugins/discord-presence is the same as a plugin.
import net from "node:net";
import path from "node:path";

export const CLIENT_ID = "1561226911336894464";
// Discord takes 5 activity updates per 20 s
const MIN_INTERVAL_MS = 4000;
// a probe that found no Discord is not repeated sooner
const PROBE_BACKOFF_MS = 15000;

const OP = { HANDSHAKE: 0, FRAME: 1, CLOSE: 2, PING: 3, PONG: 4 };

export interface Track {
  id?: string; title?: string; channel?: string; duration?: number; source?: string;
  thumbnail?: string; album?: string; albumArt?: string; youtubeId?: string;
}
export type Activity = Record<string, unknown> | null;

function frame(op: number, obj: unknown): Buffer {
  const data = Buffer.from(JSON.stringify(obj));
  const head = Buffer.alloc(8);
  head.writeInt32LE(op, 0);
  head.writeInt32LE(data.length, 4);
  return Buffer.concat([head, data]);
}

// Every place a Discord build opens its socket: native, Flatpak, Snap, then the temp dirs.
export function socketPaths(env: NodeJS.ProcessEnv = process.env, platform: string = process.platform): string[] {
  if (platform === "win32") return Array.from({ length: 10 }, (_, i) => `\\\\?\\pipe\\discord-ipc-${i}`);
  const dirs: string[] = [];
  if (env.XDG_RUNTIME_DIR) {
    dirs.push(env.XDG_RUNTIME_DIR,
      path.join(env.XDG_RUNTIME_DIR, "app", "com.discordapp.Discord"),
      path.join(env.XDG_RUNTIME_DIR, "snap.discord"));
  }
  for (const k of ["TMPDIR", "TMP", "TEMP"]) if (env[k]) dirs.push(env[k]!);
  dirs.push("/tmp");
  const out: string[] = [];
  for (const d of [...new Set(dirs)]) for (let i = 0; i < 10; i++) out.push(path.join(d, `discord-ipc-${i}`));
  return out;
}

// Discord drops an activity whose text is under 2 characters
const text = (s: unknown, fallback: string) => {
  const t = String(s || fallback).slice(0, 128);
  return t.length >= 2 ? t : t.padEnd(2, "⠀");
};
const isWeb = (u?: string) => /^https?:\/\//.test(u || "");
// the YouTube video a track is: its own id, or an imported file's linked video; "" for none
function videoOf(t: Track): string {
  if (t.source && t.source !== "youtube") return "";
  if (t.id && !t.id.startsWith("local:")) return t.id;
  return t.youtubeId || "";
}

// melo's own art when Discord can fetch it, else the album cover, else the video's thumbnail
function artwork(t: Track): string | undefined {
  if (isWeb(t.thumbnail)) return t.thumbnail;
  if (isWeb(t.albumArt)) return t.albumArt;
  const v = videoOf(t);
  return v ? `https://i.ytimg.com/vi/${encodeURIComponent(v)}/hqdefault.jpg` : undefined;
}

// The activity for a track at `position` seconds, or null to clear it.
export function activityFor(t: Track | null, playing: boolean, position: number, now = Date.now()): Activity {
  if (!t || !playing) return null;
  const start = now - Math.max(0, position || 0) * 1000;
  const timestamps: Record<string, number> = { start: Math.round(start) };
  if ((t.duration ?? 0) > 0) timestamps.end = Math.round(start + t.duration! * 1000);
  const a: Record<string, unknown> = {
    type: 2,                     // Listening
    status_display_type: 2,      // the member list shows the title
    details: text(t.title, "Unknown track"),
    state: text(t.channel, "melo"),
    timestamps,
  };
  const v = videoOf(t);
  const link = v ? `https://www.youtube.com/watch?v=${encodeURIComponent(v)}` : "";
  // the title and the artwork open the video; the button for clients that do not link them
  if (link) a.details_url = link;
  const art = artwork(t);
  // the card prints large_text as its third line: the album, when the library knows it
  if (art) {
    const assets: Record<string, string> = { large_image: art };
    if (t.album) assets.large_text = text(t.album, "");
    if (link) assets.large_url = link;
    a.assets = assets;
  }
  if (link) a.buttons = [{ label: "Open on YouTube", url: link }];
  return a;
}

export interface PresenceOptions {
  clientId?: string; paths?: string[]; minIntervalMs?: number; probeBackoffMs?: number;
  log?: (msg: string) => void;
}

// The connection and the player state it mirrors. Player events update the state
// whether or not it is on, so turning it on mid-track shows the track at once.
export function createPresence(opts: PresenceOptions = {}) {
  const clientId = opts.clientId ?? CLIENT_ID;
  const minInterval = opts.minIntervalMs ?? MIN_INTERVAL_MS;
  const backoff = opts.probeBackoffMs ?? PROBE_BACKOFF_MS;
  const paths = opts.paths ?? socketPaths();
  const log = opts.log ?? (() => {});

  let on = false;
  let sock: net.Socket | null = null, ready = false, probing = false, lastMiss = -Infinity;
  let inbox = Buffer.alloc(0);
  // undefined: nothing to send
  let wanted: Activity | undefined, sent: Activity | undefined;
  let sentAt = -Infinity, timer: NodeJS.Timeout | null = null;
  let last: Track | null = null, playing = false, position = 0, positionAt = Date.now();
  const positionNow = () => position + (playing ? (Date.now() - positionAt) / 1000 : 0);

  function onFrame(op: number, msg: any) {
    if (op === OP.PING) { sock?.write(frame(OP.PONG, msg)); return; }
    if (op === OP.CLOSE) { log(`[discord] closed: ${msg.message || ""} (${msg.code ?? "?"})`); sock?.destroy(); return; }
    if (op !== OP.FRAME) return;
    if (msg.evt === "READY") {
      ready = true;
      log(`[discord] connected${msg.data?.user?.username ? " as " + msg.data.user.username : ""}`);
      flush();
    } else if (msg.evt === "ERROR") {
      log(`[discord] ${msg.cmd || "error"}: ${msg.data?.message || ""} (${msg.data?.code ?? "?"})`);
    }
  }

  function onData(chunk: Buffer) {
    inbox = Buffer.concat([inbox, chunk]);
    while (inbox.length >= 8) {
      const op = inbox.readInt32LE(0), len = inbox.readInt32LE(4);
      if (inbox.length < 8 + len) return;
      let msg: unknown = {};
      try { msg = JSON.parse(inbox.subarray(8, 8 + len).toString()); } catch { /* a bad frame is skipped */ }
      inbox = inbox.subarray(8 + len);
      onFrame(op, msg);
    }
  }

  function connect(i = 0) {
    if (!on) { probing = false; return; }
    if (i >= paths.length) { probing = false; lastMiss = Date.now(); return; }
    probing = true;
    const s = net.createConnection(paths[i]);
    // a missing socket errors asynchronously: try the next path
    s.once("error", () => { if (sock !== s) connect(i + 1); });
    s.on("connect", () => {
      if (!on) { s.destroy(); probing = false; return; }
      probing = false; sock = s; inbox = Buffer.alloc(0);
      s.on("error", () => {});
      s.on("data", onData);
      s.write(frame(OP.HANDSHAKE, { v: 1, client_id: clientId }));
    });
    s.on("close", () => {
      if (sock !== s) return;
      sock = null; ready = false; sent = undefined;
      // what was showing goes when Discord drops the socket; show it again on reconnect
      if (on && wanted === undefined && last) wanted = activityFor(last, playing, positionNow());
    });
  }

  function flush() {
    if (!on || wanted === undefined) return;
    if (!sock || !ready) {
      if (!sock && !probing && Date.now() - lastMiss >= backoff) connect();
      return;
    }
    const wait = sentAt + minInterval - Date.now();
    if (wait > 0) { if (!timer) timer = setTimeout(() => { timer = null; flush(); }, wait); return; }
    const activity = wanted;
    wanted = undefined;
    if (JSON.stringify(activity) === JSON.stringify(sent)) return;
    sent = activity; sentAt = Date.now();
    sock.write(frame(OP.FRAME, { cmd: "SET_ACTIVITY", nonce: String(sentAt), args: { pid: process.pid, activity } }));
  }

  function update() { wanted = activityFor(last, playing, positionNow()); flush(); }
  // a stream's duration can arrive after its trackChanged
  const takeDuration = (e: any) => { if (last && e?.duration > 0) last = { ...last, duration: e.duration }; };

  return {
    // melo's player events, as plugins get them
    event(type: string, e: any) {
      if (type === "trackChanged") { last = e?.track ?? null; position = 0; positionAt = Date.now(); }
      else if (type === "stateChanged") { takeDuration(e); playing = !!e?.playing; position = e?.position || 0; positionAt = Date.now(); }
      else if (type === "seeked") { takeDuration(e); position = e?.position || 0; positionAt = Date.now(); }
      else if (type === "stopped") { last = null; playing = false; }
      else return;
      if (on) update();
    },
    // off drops the connection, and Discord clears the status with it
    setEnabled(v: boolean) {
      if (v === on) return;
      on = v;
      if (on) { lastMiss = -Infinity; update(); return; }
      wanted = undefined; sent = undefined;
      if (timer) { clearTimeout(timer); timer = null; }
      sock?.destroy(); sock = null; ready = false;
    },
    close() { this.setEnabled(false); },
  };
}
