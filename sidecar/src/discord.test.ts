import { describe, it, expect, afterEach } from "vitest";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { activityFor, socketPaths, createPresence, CLIENT_ID } from "./discord";

const track = { id: "dQw4w9WgXcQ", title: "Song", channel: "Artist", duration: 200, source: "" };

function frame(op: number, obj: unknown) {
  const data = Buffer.from(JSON.stringify(obj));
  const head = Buffer.alloc(8);
  head.writeInt32LE(op, 0); head.writeInt32LE(data.length, 4);
  return Buffer.concat([head, data]);
}

// A Discord that answers the handshake with READY (or `reject`) and records each SET_ACTIVITY.
function fakeDiscord(sockPath: string, { reject = false } = {}) {
  const got = { handshake: null as any, activities: [] as any[], closed: 0 };
  const server = net.createServer((c) => {
    let buf = Buffer.alloc(0);
    c.on("close", () => got.closed++);
    c.on("data", (d) => {
      buf = Buffer.concat([buf, d]);
      while (buf.length >= 8 && buf.length >= 8 + buf.readInt32LE(4)) {
        const op = buf.readInt32LE(0), len = buf.readInt32LE(4);
        const msg = JSON.parse(buf.subarray(8, 8 + len).toString());
        buf = buf.subarray(8 + len);
        if (op === 0) {
          got.handshake = msg;
          if (reject) { c.write(frame(2, { code: 4000, message: "Invalid Client ID" })); c.end(); }
          // split in two writes: frames must be reassembled
          else { const f = frame(1, { cmd: "DISPATCH", evt: "READY", data: { user: { username: "tester" } } }); c.write(f.subarray(0, 5)); setTimeout(() => c.write(f.subarray(5)), 20); }
        } else if (op === 1 && msg.cmd === "SET_ACTIVITY") {
          got.activities.push(msg.args.activity);
          c.write(frame(1, { cmd: "SET_ACTIVITY", nonce: msg.nonce, data: msg.args.activity }));
        }
      }
    });
  });
  return new Promise<{ server: net.Server; got: typeof got }>((r) => server.listen(sockPath, () => r({ server, got })));
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "melo-discord-"));
const cleanup: (() => void)[] = [];
afterEach(() => { while (cleanup.length) cleanup.pop()!(); });

describe("discord activity", () => {
  it("is Listening, with artwork, a link and a progress bar", () => {
    const a: any = activityFor(track, true, 50, 1_000_000);
    expect(a.type).toBe(2);
    expect(a.details).toBe("Song");
    expect(a.state).toBe("Artist");
    expect(a.timestamps).toEqual({ start: 950_000, end: 1_150_000 });
    const link = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";
    expect(a.assets).toEqual({ large_image: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", large_url: link });
    expect(a.details_url).toBe(link);
    expect(a.buttons[0].url).toBe(link);
    expect(activityFor(track, false, 50)).toBeNull();
    expect(activityFor(null, true, 0)).toBeNull();
    expect((activityFor({ ...track, title: "x" }, true, 0) as any).details.length).toBe(2);
  });
  it("shows a library track's album, and its cover over a local file", () => {
    const a: any = activityFor({ ...track, thumbnail: "file:///m/a.jpg", album: "Works", albumArt: "https://cdn.example/c.jpg" }, true, 0);
    expect(a.assets).toEqual({ large_image: "https://cdn.example/c.jpg", large_text: "Works",
                               large_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ" });
  });
  it("links an imported file through its linked video, and one without a video not at all", () => {
    const linked: any = activityFor({ ...track, id: "local:abc", youtubeId: "VID12345678" }, true, 0);
    expect(linked.details_url).toBe("https://www.youtube.com/watch?v=VID12345678");
    expect(linked.assets.large_image).toBe("https://i.ytimg.com/vi/VID12345678/hqdefault.jpg");
    const plain: any = activityFor({ ...track, id: "local:abc", thumbnail: "file:///m/a.jpg" }, true, 0);
    expect(plain.details_url).toBeUndefined();
    expect(plain.buttons).toBeUndefined();
    expect(plain.assets).toBeUndefined();
  });
  it("finds native, Flatpak and Snap Discord, and the Windows pipe", () => {
    const p = socketPaths({ XDG_RUNTIME_DIR: "/run/user/1000" }, "linux");
    expect(p).toContain("/run/user/1000/discord-ipc-0");
    expect(p).toContain("/run/user/1000/app/com.discordapp.Discord/discord-ipc-0");
    expect(p).toContain("/run/user/1000/snap.discord/discord-ipc-9");
    expect(socketPaths({}, "win32")[0]).toBe("\\\\?\\pipe\\discord-ipc-0");
  });
});

describe("discord presence", () => {
  it("stays off the socket until turned on, then shows the track already playing", async () => {
    const dir = tmp();
    const { server, got } = await fakeDiscord(path.join(dir, "discord-ipc-0"));
    const p = createPresence({ minIntervalMs: 0, paths: [path.join(dir, "discord-ipc-0")] });
    cleanup.push(() => { p.close(); server.close(); });
    p.event("trackChanged", { track });
    p.event("stateChanged", { playing: true, position: 30 });
    await sleep(150);
    expect(got.handshake).toBeNull();
    p.setEnabled(true);
    await sleep(200);
    expect(got.handshake.client_id).toBe(CLIENT_ID);
    expect(got.activities.at(-1).details).toBe("Song");
    expect(Math.abs(Date.now() - got.activities.at(-1).timestamps.start - 30_000)).toBeLessThan(1000);
  });
  it("follows pause, seek and stop; off drops the connection", async () => {
    const dir = tmp();
    fs.mkdirSync(path.join(dir, "app", "com.discordapp.Discord"), { recursive: true });
    const { server, got } = await fakeDiscord(path.join(dir, "app", "com.discordapp.Discord", "discord-ipc-0"));
    const logs: string[] = [];
    const p = createPresence({ minIntervalMs: 0, paths: socketPaths({ XDG_RUNTIME_DIR: dir }, "linux"), log: (m) => logs.push(m) });
    cleanup.push(() => { p.close(); server.close(); });
    p.setEnabled(true);
    p.event("trackChanged", { track: { ...track, duration: 0 } });
    p.event("stateChanged", { playing: true, position: 0, duration: 200 });
    await sleep(200);
    expect(logs).toContain("[discord] connected as tester");
    expect(got.activities.at(-1).timestamps.end - got.activities.at(-1).timestamps.start).toBe(200_000);
    p.event("seeked", { position: 100 });
    await sleep(80);
    expect(Math.abs(Date.now() - got.activities.at(-1).timestamps.start - 100_000)).toBeLessThan(1000);
    p.event("stateChanged", { playing: false, position: 100 });
    await sleep(80);
    expect(got.activities.at(-1)).toBeNull();
    p.event("stateChanged", { playing: true, position: 100 });
    p.event("stopped", {});
    await sleep(80);
    expect(got.activities.at(-1)).toBeNull();
    p.setEnabled(false);
    await sleep(80);
    expect(got.closed).toBe(1);
  });
  it("sends at most one update per interval, the last one wins", async () => {
    const dir = tmp();
    const { server, got } = await fakeDiscord(path.join(dir, "discord-ipc-0"));
    const p = createPresence({ minIntervalMs: 400, paths: [path.join(dir, "discord-ipc-0")] });
    cleanup.push(() => { p.close(); server.close(); });
    p.setEnabled(true);
    p.event("stateChanged", { playing: true, position: 0 });
    p.event("trackChanged", { track: { ...track, title: "Song 1" } });
    await sleep(150);
    expect(got.activities.length).toBe(1);
    for (let i = 2; i <= 6; i++) p.event("trackChanged", { track: { ...track, id: "id" + i, title: "Song " + i } });
    await sleep(100);
    expect(got.activities.length).toBe(1);
    await sleep(500);
    expect(got.activities.length).toBe(2);
    expect(got.activities.at(-1).details).toBe("Song 6");
  });
  it("logs a rejected Application ID", async () => {
    const dir = tmp();
    const { server } = await fakeDiscord(path.join(dir, "discord-ipc-0"), { reject: true });
    const logs: string[] = [];
    const p = createPresence({ minIntervalMs: 0, paths: [path.join(dir, "discord-ipc-0")], log: (m) => logs.push(m) });
    cleanup.push(() => { p.close(); server.close(); });
    p.setEnabled(true);
    p.event("trackChanged", { track });
    p.event("stateChanged", { playing: true, position: 0 });
    await sleep(200);
    expect(logs.some((l) => l.includes("Invalid Client ID") && l.includes("4000"))).toBe(true);
  });
  it("with no Discord running, does not probe again before the backoff", async () => {
    const dir = tmp();
    const p = createPresence({ minIntervalMs: 0, probeBackoffMs: 60_000, paths: [path.join(dir, "discord-ipc-0")] });
    p.setEnabled(true);
    p.event("stateChanged", { playing: true, position: 0 });
    p.event("trackChanged", { track });
    await sleep(100);
    const { server, got } = await fakeDiscord(path.join(dir, "discord-ipc-0"));
    cleanup.push(() => { p.close(); server.close(); });
    p.event("seeked", { position: 5 });
    await sleep(100);
    expect(got.handshake).toBeNull();
  });
});
