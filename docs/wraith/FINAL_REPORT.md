# WraithTerm — FINAL REPORT (P5.4)

Semua fase P0–P5 selesai di branch `wraith/phase0-recon`
(2026-10-05). Ringkasan bukti, bukan klaim ulang: angka di bawah
berasal dari run yang dicatat di `BASELINE.md`/`PROGRESS.md`.

## Status akhir

| Gerbang | Hasil |
|---|---|
| `zig build` | EXIT=0 |
| Suite penuh (binary langsung) | 3976 lulus / 40 skip / 0 gagal |
| Benchmark vs baseline | nihil regresi >5% beban kerja (analisis `format−noop` di `BASELINE.md` §P5.1) |
| Fuzz 1M + 250K + 250K | tanpa crash/hang/OOM |
| e2e lossy | P4.5 60 skenario + P4.10 20 seed + P4.8 e2e, layar/hash identik |
| `[~]` terbuka | 6 item di `NEEDS_HUMAN_VERIFICATION.md` (butuh display/macOS) |
| `[!]` / blocker | nihil |

## Per pilar

- **Pilar 1 — Daemon + attach/detach (P1.1–P1.9):** codec D9 14 tipe,
  session manager, PTY headless, snapshot chunked, socket `0600`,
  headless client, `+daemon/+list-sessions/+kill/+remote/+remote-server/+list-harnesses`,
  auto-spawn `wraith-daemon=auto`. GUI `--attach` belum ada (jalur
  input termio di luar skop; dicatat `[~]`).
- **Pilar 4 — Harness omp (P2.1–P2.10):** recon omp 18.4.4 riil;
  Tier 1 (bridge 11 hook + socket + parser), Tier 2 (`/proc` detector),
  Tier 3 (klasifier ANSI, tak dibutuhkan omp kini); installer AC4.3;
  HUD GTK + aksi; notifikasi edge-triggered.
- **Pilar 3 — Image paste (P3.1–P3.4):** store terkelola D1, quoting +
  bracketed delivery (AC3.3), deteksi Linux GTK + macOS embedded
  (compile-guarded).
- **Pilar 2 — Remote SSP (P4.1–P4.10):** AEAD D3 + replay window,
  Transport/LossyLink/fragmentasi, bootstrap D2, snapshot sync, diff
  bernomor-state + ack/retransmit, roaming anti-bajak, predictive echo
  D10 (aturan; rendering `[~]`), payload ImageChunk/Telemetry, fuzz,
  endurance 20 seed.

## Config keys baru (default = perilaku stock)

`wraith-daemon = off|auto`, `wraith-image-paste = off|<dir>`,
`wraith-predictive-echo = adaptive|always|never`. Panduan:
`USER_GUIDE.md`.

## Deviasi terdokumentasi

- Implementasi di `src/daemon/`, bukan `src/remote/` + `src/harness/`
  (direktori tak pernah dibuat; lihat `ARCHITECTURE.md` §6.2).
- Enum publik sinkron-C: aturan append-only (pelajaran P5.1).
- Aturan lintas-fase di `ARCHITECTURE.md` §7.

## Merge

Branch ini di-merge ke `wraith/dev` (fast-forward) dan di-push.
Marker penyelesaian: `docs/wraith/WRAITH_DONE`.
