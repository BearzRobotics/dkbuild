// Lets pnpm install offline from the shared npm store (dkbuild's npmdeps,
// SPEC.md 7.4). pnpm has its own store format and no way to read npm's cache,
// so this serves the store as a minimal npm registry on 127.0.0.1: for every
// package in the pnpm-lock.yaml files given, the tarball path pnpm asks for
// (/<name>/-/<file>.tgz, as the lockfile's registry entries derive it) maps to
// the store file named by its integrity hash. pnpm checks every tarball
// against the lockfile again. Metadata requests get 404: a frozen lockfile
// needs none.
//
//   node pnpm-registry.js <port> <ready-file> pnpm-lock.yaml...
"use strict";
const fs = require("fs");
const http = require("http");
const store = process.env.DKBUILD_NPM_STORE || "/dkdeps/npm";
const [port, ready, ...locks] = process.argv.slice(2);

function storeFile(integrity) {
  let best = null;
  for (const part of integrity.split(/\s+/)) {
    const m = /^(sha512|sha256|sha1)-(.+)$/.exec(part);
    if (m && (!best || m[1] === "sha512")) best = { algo: m[1], hex: Buffer.from(m[2], "base64").toString("hex") };
  }
  if (!best) return null;
  return `${store}/content-v2/${best.algo}/${best.hex.slice(0, 2)}/${best.hex.slice(2, 4)}/${best.hex.slice(4)}`;
}

// The same reading as npmdeps.zig's collectPnpm: `packages:` entries and
// their `resolution: {integrity: ...}`.
const files = new Map();
for (const lock of locks) {
  let inPackages = false, key = null;
  for (const raw of fs.readFileSync(lock, "utf8").split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (!line) continue;
    if (line[0] !== " ") { inPackages = line === "packages:"; key = null; continue; }
    if (!inPackages) continue;
    if (/^  [^ ]/.test(line)) { key = line.slice(2).replace(/:$/, "").replace(/^['"]|['"]$/g, ""); continue; }
    const t = line.trim();
    if (!t.startsWith("resolution: {") || !key) continue;
    const integ = /integrity: ([^,}\s]+)/.exec(t);
    if (!integ || /tarball:/.test(t)) continue;
    const at = key.lastIndexOf("@");
    if (at <= 0) continue;
    const name = key.slice(0, at), ver = key.slice(at + 1);
    const base = name.includes("/") ? name.slice(name.lastIndexOf("/") + 1) : name;
    const f = storeFile(integ[1]);
    if (f) files.set(`/${name}/-/${base}-${ver}.tgz`, f);
  }
}

const server = http.createServer((req, res) => {
  const path = decodeURIComponent(req.url.split("?")[0]).replace(/%2f/gi, "/");
  const f = files.get(path);
  if (!f || !fs.existsSync(f)) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": "application/octet-stream", "content-length": fs.statSync(f).size });
  fs.createReadStream(f).pipe(res);
});
server.listen(Number(port), "127.0.0.1", () => {
  fs.writeFileSync(ready, `${files.size}\n`);
});
