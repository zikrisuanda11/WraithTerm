# WraithTerm — BASELINE (P0.5)

Angka acuan sebelum perubahan fungsional. Dipakai P1.9/P5.1 untuk deteksi
regresi (>5% = perbaiki).

## Lingkungan pengukuran

| Properti | Nilai |
|---|---|
| Mesin | CachyOS (Arch rolling), kernel 7.2.8-1-cachyos, x86_64, 8 core |
| Toolchain | Zig 0.16.0 user-local (`~/.local/opt/zig`), `ZIG_LIBC` → sanitized CRT (ADR-005) |
| GTK / libadwaita | 4.22.5 / 1.9.4 (build = runtime) |
| Commit | `5b1bf33e0` (branch `wraith/phase0-recon`) |
| Basis upstream | `f96c9711b` (lihat UPSTREAM.md) |
| Biner | `zig-out/bin/ghostty` = `Ghostty 1.3.2-wraith-phase0-recon+dd0532be0` |

## Full test suite (`zig build test`)

Status: **hijau via test binary langsung (2026-10-05)**.

Catatan pelaksana: `zig build test` (tanpa filter) pada Zig 0.16.0 menandai
run-step `ghostty-test` sebagai "failed command" bila test binary menulis
apa pun ke stderr — walau semua test lolos. Sumber noise yang diketahui:
`src/benchmark/TerminalFormatter.zig:405` (`std.debug.print` di test
`TerminalFormatter roundtrip`, output `... equal=true`) yang ikut
ter-compile ke test binary via `src/main_ghostty.zig:247`
(`benchmark/main.zig` refAllDecls). Kode upstream, bukan regresi Wraith.
Karena itu baseline dicatat dari **exit code test binary langsung**
(`zig build test -Demit-test-exe=true` + jalankan), bukan dari status
run-step build.

| Metrik | Nilai |
|---|---|
| Test binary exit code | 0 |
| Test lulus / total | 3881 / 3921 |
| Skip (platform, mis. windows-only) | 40 |
| Test gagal | 0 |
| Durasi wall (binary langsung) | ±398 dtk |

## Benchmark (`-Demit-bench=true -Doptimize=ReleaseFast`)

Status: **ter-build + jalan (2026-10-05)**. Biner: `ghostty-bench`,
`ghostty-gen` (versi `1.3.2-wraith-phase0-recon+5b1bf33e0`).

Metodologi (kasar, cukup untuk deteksi regresi >5% di P1.9/P5.1 bila
diulang dengan cara sama): korpus `ghostty-gen +styled` 640000 byte
(sha256 `103a926e…cc27e69b1`; seed acak per-generate — ulangi generate
untuk perbandingan apel-ke-apel bila perlu deterministik, pakai korpus
tersimpan), `bash time` single-run per bench, mode default/`format`.
Tanpa `hyperfine` di mesin ini.

| Bench | Argumen | Wall (single-run) |
|---|---|---|
| terminal-formatter noop | `--mode=noop` | 0.015 s |
| terminal-formatter format | `--mode=format` (default) | 0.069 s |
| terminal-formatter report | `--mode=report` | out 640000 B / 10350 baris / 828000 sel, `out_hash=ea331b0675534fc8` |
| terminal-parser | (default) | 0.028 s |
| terminal-snapshot encode | `--mode=encode` | 0.017 s |
| terminal-snapshot report | `--mode=report` | page payload 650784 B (18 page) |
| terminal-resize | (default) | 0.244 s |
| terminal-stream | (default) | 0.013 s |

## Catatan

- Suite penuh pertama (2026-10-05) berhenti di run-step `ghostty-test`
  setelah ±603 dtk dengan satu-satunya output stderr berupa baris
  `terminal-formatter roundtrip ... equal=true` → test roundtrip-nya
  sendiri LOLOS; yang gagal hanya run-step build karena kebijakan
  stderr-ketat Zig 0.16.
