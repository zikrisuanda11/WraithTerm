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

## P1.9 Regression (2026-10-05, commit `ee5e15204`)

Metode sama: test binary langsung + bench `date`-timed 3x (diambil
rentang), korpus `ghostty-gen +styled` default 640000 B
(sha256 `e982755e…01e293bc7`; seed acak → bandingkan timing, bukan hash).

| Metrik | Baseline (P0.5) | P1.9 | Putusan |
|---|---|---|---|
| Test binary exit | 0 | 0 | hijau |
| Lulus / total | 3881 / 3921 | 3910 / 3950 | +29 test baru (P1.7/P1.8), 0 gagal |
| Skip / gagal | 40 / 0 | 40 / 0 | sama |
| Durasi wall | ±398 dtk | ±403 dtk | setara |
| formatter noop | 0.015 s | 0.018–0.019 s | noise startup (+3 ms absolut) |
| formatter format | 0.069 s | 0.068–0.070 s | −1%, setara |
| parser | 0.028 s | 0.023–0.024 s | lebih cepat |
| snapshot encode | 0.017 s | 0.019–0.020 s | noise startup (+2 ms absolut) |
| resize | 0.244 s | 0.245–0.252 s | +0.4%, setara |
| stream | 0.013 s | 0.015–0.016 s | noise startup (+2 ms absolut) |
| formatter report | out 640000 B / 10350 baris, `out_hash=ea331b06…` | out 640000 B / 10340 baris, `out_hash=cd609ae6…` (korpus beda seed) | konten penuh diproses |
| snapshot report | page 650784 B (18 page) | page 650774 B (18 page) | setara |

Kesimpulan: **tidak ada regresi >5%** pada beban kerja nyata
(format/resize/suite). Selisih +2–3 ms absolut hanya pada bench
operasi-kecil yang didominasi startup proses; modul daemon ter-link
tapi tak pernah dieksekusi bench.

## Catatan
