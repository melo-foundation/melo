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
      const w = walls[String(p.videoId).replace(/\d+$/, "")];
      if (w) return reply(msg.id, { error: { code: w[0], message: w[1] } });
      return reply(msg.id, { result: { ok: false, error: "This video is unavailable" } });
    }
    default: return reply(msg.id, { result: {} });
  }
});
