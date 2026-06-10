#!/usr/bin/env bash
#
# mp4san/mayhem/build.sh — build signalapp/mp4san's cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (projects/mp4san/build.sh which runs
# `cargo fuzz build` per crate).
#
# mp4san is a pure-Rust media (MP4 / WebP) sanitizer workspace. The fuzzed library crates
# (mp4san, webpsan) have NO ffmpeg / system-library dependency — ffmpeg is only an OPTIONAL,
# non-default dev-dependency used by the differential test suite — so `cargo fuzz build` needs
# nothing beyond the Rust toolchain.
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Each fuzz crate (mp4san/fuzz, webpsan/fuzz) is its own nested cargo workspace exposing a single
# target `sanitize`. We build per-crate and copy the produced binary to /mayhem/<crate>-sanitize
# (matching OSS-Fuzz's <crate>-<target> output naming).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# RUST_DEBUG_FLAGS threads DWARF < 4 symbols (item 10): debuginfo=2 for compact line tables,
# -Z dwarf-version=3 for the Rust user CUs, and the -Clinker cc-wrapper that prepends a DWARF3
# anchor object as the FIRST link input so the -m1 readelf check in verify-repo sees DWARF v3
# even though the precompiled ASan runtime CUs (librustc-nightly_rt.asan.a) remain DWARF v5
# deeper in the binary. See the DWARF<4 block in the Dockerfile for the full rationale.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# crate-dir -> output binary name. The single fuzz target in each crate is `sanitize`.
CRATES=(mp4san webpsan)

for crate in "${CRATES[@]}"; do
  fuzz_dir="$SRC/$crate/fuzz"
  out="/mayhem/${crate}-sanitize"
  echo "--- building fuzz target: $crate/fuzz:sanitize ---"
  # cargo-fuzz must run from inside the fuzz crate dir (it's a nested workspace). Use the image's
  # DEFAULT toolchain (Dockerfile pins it to the required nightly); a `+toolchain` override would
  # make rustup try to install a different channel into the read-only shared /opt/rust.
  # `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh (catches
  # overflow/debug asserts during fuzzing). cargo-fuzz 0.12 doesn't accept --jobs; parallelism is
  # controlled via CARGO_BUILD_JOBS in the environment (above).
  ( cd "$fuzz_dir" && cargo fuzz build -O --debug-assertions sanitize )
  bin="$fuzz_dir/target/$TRIPLE/release/sanitize"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "$out"
  echo "built $out"
done

echo "build.sh complete:"
ls -la /mayhem/mp4san-sanitize /mayhem/webpsan-sanitize 2>&1 || true
