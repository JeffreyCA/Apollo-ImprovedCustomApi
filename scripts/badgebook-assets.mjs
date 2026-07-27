#!/usr/bin/env node
//
// badgebook-assets.mjs — build-time asset pipeline for the profile "Badge Book".
//
// Reads the two extracted Reddit catalogues (achievements + Trophy Case) from
// scripts/badgebook-data/, downloads each collectible's 1024px source PNG,
// downscales it to an icon-sized PNG (~200px) and optimizes it, then writes:
//
//   resources/BadgeBook/a_<id>.png     one achievement icon per catalogue entry
//   resources/BadgeBook/t_<id>.png     one trophy icon per catalogue entry
//   resources/BadgeBook/badgebook-catalog.json   compact runtime metadata
//
// The whole resources/ tree ships inside ApolloReborn.bundle, so at runtime the
// achievements book renders instantly and fully offline. Live / uncatalogued
// trophies fall back to their remote image_url (kept in the catalogue) via the
// app's async image pipeline.
//
// Requirements (macOS dev box): ImageMagick (`magick`) and `oxipng` (optional,
// skipped if absent). Node 18+ for global fetch.
//
// Usage:
//   node scripts/badgebook-assets.mjs            # incremental (skips existing icons)
//   node scripts/badgebook-assets.mjs --force    # re-download + re-encode everything
//   node scripts/badgebook-assets.mjs --max 160  # override the downscale target (px)
//
import { readFile, writeFile, mkdir, rm, stat } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(__dirname, "..");
const DATA_DIR = join(__dirname, "badgebook-data");
const OUT_DIR = join(REPO_ROOT, "resources", "BadgeBook");

const argv = new Map();
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === "--force") argv.set("force", true);
  else if (a === "--max") argv.set("max", Number(process.argv[++i]));
}
const FORCE = argv.get("force") === true;
const MAX_PX = argv.get("max") || 200;
const CONCURRENCY = 8;
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15";

async function tool(name) {
  try { await execFileAsync(name, ["--version"]); return true; }
  catch { return false; }
}

async function fetchBuffer(url, attempt = 1) {
  try {
    const res = await fetch(url, { headers: { "User-Agent": UA }, signal: AbortSignal.timeout(30000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const buf = Buffer.from(await res.arrayBuffer());
    // Rate-limited CDN responses are HTTP 200 with a tiny blank PNG — the bug
    // that once shipped 40 invisible badges. Treat them as failures and retry.
    if (buf.length < 2048) throw new Error(`suspiciously small response (${buf.length}B) — likely a rate-limit placeholder`);
    return buf;
  } catch (err) {
    if (attempt < 5) {
      await new Promise((r) => setTimeout(r, 700 * attempt));
      return fetchBuffer(url, attempt + 1);
    }
    throw err;
  }
}

// Download -> downscale -> optimize a single collectible. Returns the written
// filename, or null on failure (caller keeps the remote image_url as fallback).
async function processOne(entry, prefix, haveOxipng) {
  const fileName = `${prefix}_${entry.id}.png`;
  const outPath = join(OUT_DIR, fileName);
  if (!FORCE) {
    // A real 200px badge icon is never under ~1KB; smaller means a previous run
    // wrote a blank placeholder — re-process it instead of skipping.
    try { if ((await stat(outPath)).size > 1024) return fileName; } catch { /* missing */ }
  }
  if (!entry.image_url) return null;

  const tmp = join(tmpdir(), `bb_${prefix}_${entry.id}_${process.pid}.src`);
  try {
    const buf = await fetchBuffer(entry.image_url);
    await writeFile(tmp, buf);
    // Fit within MAX_PX x MAX_PX, preserve aspect + alpha; strip metadata; and
    // quantize to a 256-colour alpha palette (PNG8). These are flat badge
    // illustrations, so 256 colours is visually lossless at icon size but ~4x
    // smaller than truecolour (≈10KB vs ≈44KB each).
    await execFileAsync("magick", [
      tmp, "-strip", "-resize", `${MAX_PX}x${MAX_PX}>`, "-colors", "256",
      "-define", "png:compression-level=9", `PNG8:${outPath}`,
    ]);
    if (haveOxipng) {
      try { await execFileAsync("oxipng", ["-o", "2", "--strip", "safe", "-q", outPath]); }
      catch { /* optimization is best-effort */ }
    }
    // Content-based blank check (byte size would false-positive on legitimately
    // tiny icons): Reddit's "ghost" placeholder art quantizes to a fully
    // transparent image, which must not ship as if it were real badge art.
    const { stdout: meanAlpha } = await execFileAsync("magick", [outPath, "-format", "%[fx:mean.a]", "info:"]);
    if (parseFloat(meanAlpha) < 0.02) {
      await rm(outPath, { force: true });
      throw new Error(`encoded icon is blank/ghost (mean alpha ${parseFloat(meanAlpha).toFixed(4)})`);
    }
    return fileName;
  } catch (err) {
    process.stderr.write(`  ! ${prefix}_${entry.id}: ${err.message}\n`);
    return null;
  } finally {
    await rm(tmp, { force: true });
  }
}

// Simple concurrency-limited map.
async function pool(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0, done = 0;
  await new Promise((resolve) => {
    const launch = () => {
      if (next >= items.length) { if (done === items.length) resolve(); return; }
      const i = next++;
      worker(items[i], i).then((r) => {
        results[i] = r;
        done++;
        if (++processed % 25 === 0 || done === items.length) {
          process.stderr.write(`  ...${done}/${items.length}\n`);
        }
        launch();
      });
    };
    let processed = 0;
    for (let k = 0; k < Math.min(limit, items.length); k++) launch();
  });
  return results;
}

async function main() {
  if (!(await tool("magick"))) {
    process.stderr.write("ERROR: ImageMagick `magick` not found (brew install imagemagick).\n");
    process.exit(1);
  }
  const haveOxipng = await tool("oxipng");
  if (!haveOxipng) process.stderr.write("note: oxipng not found; skipping extra PNG optimization.\n");

  await mkdir(OUT_DIR, { recursive: true });

  const badges = JSON.parse(await readFile(join(DATA_DIR, "reddit_badges.json"), "utf8"));
  const trophies = JSON.parse(await readFile(join(DATA_DIR, "reddit_trophies.json"), "utf8"));

  // Some catalogue image_urls only ever serve Reddit's faint "ghost" placeholder
  // (real art exists solely on profiles that earned the badge). Substitute the
  // harvested real-art URLs where we have them; the rest stay unbundled and the
  // app falls back to the per-user art URL scraped from the achievements page.
  try {
    const overrides = JSON.parse(await readFile(join(DATA_DIR, "badgebook-image-overrides.json"), "utf8")).image_url_overrides || {};
    let applied = 0;
    for (const e of badges.badges) {
      if (overrides[e.id]) { e.image_url = overrides[e.id]; applied++; }
    }
    process.stderr.write(`Applied ${applied} image_url overrides (ghost-art replacements).\n`);
  } catch { /* no overrides file */ }

  process.stderr.write(`Achievements: ${badges.badges.length}  Trophies: ${trophies.trophies.length}\n`);
  process.stderr.write(`Downscaling to ${MAX_PX}px into ${OUT_DIR}\n`);

  process.stderr.write("Achievements:\n");
  const achFiles = await pool(badges.badges, CONCURRENCY, (e) => processOne(e, "a", haveOxipng));
  process.stderr.write("Trophies:\n");
  const troFiles = await pool(trophies.trophies, CONCURRENCY, (e) => processOne(e, "t", haveOxipng));

  const achievements = badges.badges.map((e, i) => ({
    id: e.id,
    title: e.title,
    bio: e.bio,
    category: e.category,
    image: achFiles[i],          // bundled filename, or null -> use image_url
    image_url: e.image_url,      // remote fallback
  }));

  const trophyEntries = trophies.trophies.map((e, i) => ({
    id: e.id,
    title: e.title,
    bio: e.bio,
    image: troFiles[i],
    image_url: e.image_url,
    destination_url: e.destination_url || null,
  }));

  const catalog = {
    schema_version: 1,
    achievement_count: achievements.length,
    trophy_count: trophyEntries.length,
    // Ordered list of achievement categories as they should render in the book.
    achievement_categories: [
      "Getting Started",
      "Building Community",
      "Community Moderation",
      "Exploration",
      "Reddit Streak",
    ],
    achievements,
    trophies: trophyEntries,
  };

  await writeFile(join(OUT_DIR, "badgebook-catalog.json"), JSON.stringify(catalog) + "\n");

  const achOk = achFiles.filter(Boolean).length;
  const troOk = troFiles.filter(Boolean).length;
  process.stderr.write(
    `\nDone. achievements ${achOk}/${achievements.length}, trophies ${troOk}/${trophyEntries.length} bundled.\n` +
    `Wrote ${join(OUT_DIR, "badgebook-catalog.json")}\n`);
}

main().catch((err) => { process.stderr.write(String(err?.stack || err) + "\n"); process.exit(1); });
