// Makes npm install offline from the shared npm store (dkbuild's npmdeps,
// SPEC.md 7.4). The store holds every tarball in npm's cache content layout
// (content-v2/<algo>/<hex>); here a private npm cache gets that store as its
// content and an index entry for each tarball URL of the package-lock.json
// files given on the command line, keyed as npm's fetcher (make-fetch-happen)
// looks them up. `npm ci --offline` then finds every tarball in the cache and
// still checks it against the lockfile's integrity hash. The lockfiles are
// read, not changed.
//
//   node npm-offline.js <npm cache dir> package-lock.json...
"use strict";
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const store = process.env.DKBUILD_NPM_STORE || "/dkdeps/npm";
const [cacheDir, ...locks] = process.argv.slice(2);
const cacache = path.join(cacheDir, "_cacache");

function digest(integrity) {
  let best = null;
  for (const part of integrity.split(/\s+/)) {
    const m = /^(sha512|sha256|sha1)-(.+)$/.exec(part);
    if (m && (!best || m[1] === "sha512")) best = { algo: m[1], b64: m[2], hex: Buffer.from(m[2], "base64").toString("hex") };
  }
  return best;
}

fs.mkdirSync(cacache, { recursive: true });
const contentLink = path.join(cacache, "content-v2");
if (!fs.existsSync(contentLink)) fs.symlinkSync(path.join(store, "content-v2"), contentLink);

let added = 0;
function index(entry) {
  if (!entry || typeof entry !== "object") return;
  const url = entry.resolved;
  if (typeof url !== "string" || !/^https?:\/\//.test(url) || typeof entry.integrity !== "string") return;
  const d = digest(entry.integrity);
  if (!d) return;
  const file = path.join(store, "content-v2", d.algo, d.hex.slice(0, 2), d.hex.slice(2, 4), d.hex.slice(4));
  let size;
  try { size = fs.statSync(file).size; } catch { console.error(`not in the store: ${url}`); process.exitCode = 1; return; }
  const key = `make-fetch-happen:request-cache:${url}`;
  const record = JSON.stringify({
    key, integrity: `${d.algo}-${d.b64}`, time: 0, size,
    metadata: { url, reqHeaders: {}, resHeaders: {}, options: { compress: true } },
  });
  const h = crypto.createHash("sha256").update(key).digest("hex");
  const bucket = path.join(cacache, "index-v5", h.slice(0, 2), h.slice(2, 4), h.slice(4));
  fs.mkdirSync(path.dirname(bucket), { recursive: true });
  fs.appendFileSync(bucket, `\n${crypto.createHash("sha1").update(record).digest("hex")}\t${record}`);
  added++;
}
function walkV1(deps) {
  for (const k of Object.keys(deps || {})) { index(deps[k]); walkV1(deps[k].dependencies); }
}
for (const f of locks) {
  const lock = JSON.parse(fs.readFileSync(f, "utf8"));
  if (lock.packages) for (const k of Object.keys(lock.packages)) if (k !== "") index(lock.packages[k]);
  if (lock.dependencies) walkV1(lock.dependencies);
}
console.log(`npm cache ${cacheDir}: ${added} tarball(s) from the store`);
