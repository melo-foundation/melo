// tst_playfailure's sidecar: answers yt/getStream by video id, logs every request
// to $MELO_FAKE_LOG.
import { createInterface } from "readline";
import { appendFileSync } from "fs";
const log = process.env.MELO_FAKE_LOG;
let settings = { prefetchPercent: 0, crossfadeSeconds: 0, silenceSkip: false, ui: {} };
const walls = {
  guestwall: [-32040, "YouTube is refusing guest playback from this address."],
  browserwall: [-32041, "YouTube is refusing playback from this address, even with your browser's account."],
  signin: [-32010, "Your sign-in has expired."],
  network: [-32030, "Network error"],
};
const reply = (id, body) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, ...body }) + "\n");
createInterface({ input: process.stdin }).on("line", (line) => {
  const msg = JSON.parse(line);
  appendFileSync(log, JSON.stringify({ m: msg.method, p: msg.params ?? {} }) + "\n");
  if (msg.id === undefined) return;
  const p = msg.params ?? {};
  switch (msg.method) {
    case "settings/get": return reply(msg.id, { result: settings });
    case "settings/set": Object.assign(settings, p.patch ?? {}); return reply(msg.id, { result: settings });
    case "ytdlp/setChannel": settings.ytdlpChannel = p.channel; return reply(msg.id, { result: { ok: true } });
    case "yt/getStream": {
      // short<n>: a 2 s file said to be 100 s long, 6 s on a fresh resolve; dropped<n>: the
      // same, and the relay says it gave up on it; whole<n>: the 2 s file at its own length
      const kind = String(p.videoId).replace(/\d+$/, "");
      const url = p.fresh && kind !== "whole" ? process.env.MELO_FAKE_LONG_URL : process.env.MELO_FAKE_SHORT_URL;
      if (kind === "short" || kind === "whole" || kind === "dropped") {
        reply(msg.id, { result: { ok: true, url, duration: kind === "whole" ? 2 : 100 } });
        if (kind === "dropped")
          process.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: "stream/dropped", params: { url, videoId: p.videoId, at: 4321 } }) + "\n");
        return;
      }
      // broken<n>: a file that is not there, so the pipeline errors on every resolve
      if (kind === "broken")
        return reply(msg.id, { result: { ok: true, url: "file:///nonexistent/melo-broken.wav", duration: 100 } });
      const w = walls[kind];
      if (w) return reply(msg.id, { error: { code: w[0], message: w[1] } });
      return reply(msg.id, { result: { ok: false, error: "This video is unavailable" } });
    }
    default: return reply(msg.id, { result: {} });
  }
});
