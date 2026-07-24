#!/usr/bin/env python3
"""
Compiles src/targets/*.lua into the flat, single-file scripts CC:Tweaked
computers actually download (repo root: broker.lua, provider.lua, ...).

Each target may reference a shared module from src/lib/ with a directive on
its own line:

    --[[@include lib/updater.lua as updater]]

which is replaced with that module's full contents wrapped as an IIFE bound
to the given local name:

    local updater = (function()
    <contents of src/lib/updater.lua>
    end)()

This is a plain textual splice, not a real Lua module system - CC:Tweaked
computers download one flat file with wget and have no way to `require`
across multiple fetched files, so multi-file source has to be flattened at
build time. Each include's internals stay scoped inside its own IIFE, so
this is safe to do even though there's no real namespacing.

Every compiled file gets a banner stamped on top (release tag, commit, build
time) - the "what am I actually running" marker - and this script also
computes each file's checksum (the same 32-bit rolling hash the runtime
updater itself uses to verify a downloaded release asset), writing them to
dist/release_notes.md for the release step to publish alongside the assets.

Run with no arguments for a local dry run (tag "dev", commit from `git
rev-parse HEAD`). CI passes --tag and --sha explicitly.
"""
import argparse
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_TARGETS = os.path.join(ROOT, "src", "targets")
SRC_ROOT = os.path.join(ROOT, "src")  # include paths are relative to here

INCLUDE_RE = re.compile(r'^--\[\[@include\s+(\S+)\s+as\s+(\S+)\]\]\s*$')


def fallback_hash(data: bytes) -> str:
    # Must match the Lua implementation in src/lib/updater.lua exactly:
    #   local hash = 0
    #   for i = 1, #code do hash = (hash * 31 + code:byte(i)) % 4294967296 end
    #   return string.format("%08x", hash)
    # Lua's numbers are doubles, but every intermediate value here stays
    # within 32 bits (well under 2^53), so the arithmetic is exact and this
    # produces a bit-identical result to the Lua version.
    h = 0
    for b in data:
        h = (h * 31 + b) % 4294967296
    return format(h, "08x")


def resolve_includes(text: str, target_name: str) -> str:
    out_lines = []
    for line in text.split("\n"):
        m = INCLUDE_RE.match(line)
        if not m:
            out_lines.append(line)
            continue
        rel_path, local_name = m.group(1), m.group(2)
        lib_path = os.path.join(SRC_ROOT, rel_path)
        if not os.path.isfile(lib_path):
            raise SystemExit(f"{target_name}: @include references missing file {rel_path}")
        with open(lib_path, "r") as fh:
            lib_src = fh.read().rstrip("\n")
        out_lines.append(f"local {local_name} = (function()")
        out_lines.append(lib_src)
        out_lines.append("end)()")
    return "\n".join(out_lines)


def build_target(target_path: str, tag: str, sha: str, built_at: str) -> bytes:
    name = os.path.basename(target_path)
    with open(target_path, "r") as fh:
        src = fh.read()

    body = resolve_includes(src, name)

    banner = (
        f"-- cc-mqtt {name} | release {tag} | commit {sha[:7]} | built {built_at}\n"
        f"-- Generated from src/targets/{name} + src/lib/*.lua - do not edit directly.\n"
    )
    return (banner + body).encode("utf-8")


def commit_sha() -> str:
    sha = os.environ.get("GITHUB_SHA")
    if sha:
        return sha
    return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True, cwd=ROOT).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tag", default=os.environ.get("RELEASE_TAG", "dev"),
                     help="release tag / version string stamped into each file and compared by the runtime updater")
    ap.add_argument("--sha", default=None, help="commit sha stamped into each file's banner")
    ap.add_argument("--out-dir", default=ROOT, help="where compiled target files are written (default: repo root)")
    ap.add_argument("--notes-dir", default=os.path.join(ROOT, "dist"),
                     help="where release_notes.md (checksum table) is written")
    args = ap.parse_args()

    sha = args.sha or commit_sha()
    built_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if not os.path.isdir(SRC_TARGETS):
        raise SystemExit(f"missing {SRC_TARGETS}")

    target_files = sorted(f for f in os.listdir(SRC_TARGETS) if f.endswith(".lua"))
    if not target_files:
        raise SystemExit(f"no .lua files found in {SRC_TARGETS}")

    os.makedirs(args.out_dir, exist_ok=True)
    os.makedirs(args.notes_dir, exist_ok=True)

    checksums = {}
    for fname in target_files:
        compiled = build_target(os.path.join(SRC_TARGETS, fname), args.tag, sha, built_at)
        out_path = os.path.join(args.out_dir, fname)
        with open(out_path, "wb") as fh:
            fh.write(compiled)
        checksums[fname] = fallback_hash(compiled)
        print(f"built {fname} ({len(compiled)} bytes, checksum {checksums[fname]})")

    repo = os.environ.get("GITHUB_REPOSITORY", "PrimeAPI/cc-mqtt")
    commit_link = f"https://github.com/{repo}/commit/{sha}"
    lines = [
        f"# cc-mqtt {args.tag}",
        "",
        f"Commit: [`{sha[:7]}`]({commit_link})",
        f"Built: {built_at}",
        "",
        "## Checksums",
        "",
        "32-bit rolling hash (matches the in-game `Upd:` display and what",
        "`updater.lua` verifies a downloaded release asset against). Plain",
        "`file: hash` lines below on purpose - the runtime updater parses",
        "this exact release body to find each script's expected checksum.",
        "",
    ]
    for fname in target_files:
        lines.append(f"{fname}: {checksums[fname]}")
    lines.append("")

    notes_path = os.path.join(args.notes_dir, "release_notes.md")
    with open(notes_path, "w") as fh:
        fh.write("\n".join(lines))
    print(f"wrote {notes_path}")


if __name__ == "__main__":
    main()
