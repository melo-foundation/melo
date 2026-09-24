// Probes the streaming backends the demo depends on. Run: node scripts/check-streaming.mjs
// Exits non-zero if no instance can serve search + audio stream bytes.
const UMA = "https://raw.githubusercontent.com/n-ce/Uma/main/list.json";
const FALLBACKS = [
  "https://invidious.schenkel.eti.br",
  "https://yt.omada.cafe",
  "https://invidious.kemonomimi.nl",
];
const TEST_ID = "dQw4w9WgXcQ";

const get = (url, ms = 10000, headers = {}) =>
  fetch(url, { signal: AbortSignal.timeout(ms), headers });

let instances = FALLBACKS;
try {
  const j = await (await get(UMA)).json();
  if (Array.isArray(j?.iv)) instances = [...new Set([...j.iv, ...FALLBACKS])];
  console.log(`Uma list: ok (${j.iv?.length ?? 0} instances)`);
} catch {
  console.log("Uma list: FAILED (using hardcoded fallbacks)");
}

let anyOk = false;
for (const inst of instances) {
  let status;
  try {
    const v = await (await get(`${inst}/api/v1/videos/${TEST_ID}?local=true`)).json();
    const audio = (v.adaptiveFormats || []).filter((f) => f.type?.startsWith("audio"));
    if (!audio.length) throw new Error("no audio formats");
    const s = await (await get(`${inst}/api/v1/search?q=daft+punk&type=video`)).json();
    if (!Array.isArray(s) || !s.length) throw new Error("search empty");
    const bytes = await get(audio[0].url, 15000, { Range: "bytes=0-65535" }).then((r) =>
      r.ok ? r.arrayBuffer() : Promise.reject(new Error(`stream HTTP ${r.status}`)),
    );
    status = `OK (${audio.length} formats, search ${s.length}, ${bytes.byteLength} bytes)`;
    anyOk = true;
  } catch (e) {
    status = `FAILED: ${e.message}`;
  }
  console.log(`${inst} -> ${status}`);
}

process.exit(anyOk ? 0 : 1);
