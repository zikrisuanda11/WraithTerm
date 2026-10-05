# WraithTerm — NEEDS_HUMAN_VERIFICATION (P5.3)

Setiap item `[~]` dari PROGRESS.md dengan langkah manual yang dapat
diulang di mesin dengan display / hardware yang tepat. Semua sudah
lolos verifikasi otomatis yang tersedia (test/build hijau); yang
tercantum di sini murni keterbatasan lingkungan agent (tanpa sesi
desktop, bukan macOS).

## 1. GUI `--attach` (P1.7)

**Klaim:** `ghostty --attach <id>` membuka window GUI ke session daemon.
**Status otomatis:** headless attach/detach/takeover terbukti via test;
jalur input GUI→termio belum ada (butuh termio-backend/input-path surgery).
**Verifikasi manual:**

1. `zig build` lalu jalankan `zig-out/bin/ghostty +daemon &`.
2. Dari terminal lain: tulis marker via headless client atau TUI.
3. Implementasikan `--attach` (belum ada), buka window, cocokkan layar
   dengan `+list-sessions` + snapshot headless.
4. Attach kedua dari window lain: window pertama harus menerima
   `Detached(taken_over)`.

## 2. Notifikasi OS `awaiting_approval` (P2.8)

**Klaim:** daemon memunculkan notifikasi desktop saat harness masuk
`awaiting_approval`.
**Status otomatis:** trigger edge-only + format pesan teruji unit;
`send()` fire-and-forget terbukti tak pernah gagal/crash tanpa display.
**Verifikasi manual** (sesi desktop Linux dengan notification daemon):

1. `notify-send -a WraithTerm "test" "test"` → notifikasi muncul
   (prasyarat lingkungan).
2. Jalankan daemon + session dengan bridge aktif
   (`+install-omp-bridge`, jalankan omp di PTY session).
3. Picu approval (tool call tanpa `--auto-approve`) → notifikasi
   "Session \<id\> awaits approval" muncul tepat sekali (bukan
   berulang per event).
4. Resolve approval → tidak ada notifikasi baru; minta lagi →
   notifikasi lagi (re-arm).

Ulangi di macOS (osascript path) bila tersedia.

## 3. HUD native `toggle_harness_hud` (P2.9)

**Klaim:** aksi menampilkan dialog GTK berisi daftar session + state.
**Status otomatis:** `zig build` hijau (compile-verified di host);
`rowLabel` murni teruji; data via `queryHarnesses` yang teruji.
**Verifikasi manual** (sesi desktop Linux):

1. Jalankan daemon + 1–2 session (satu dengan bridge aktif).
2. Buka command palette → jalankan `toggle_harness_hud`
   (atau bind key ke aksi tersebut).
3. Dialog muncul transient di window: baris `id — verdict[(tool)]`
   cocok dengan output `+list-harnesses`.
4. Daemon mati → dialog tetap terbuka kosong ("No harness sessions").

## 4. Paste gambar Linux GTK (P3.3)

**Klaim:** paste clipboard bergambar mengetik path ter-quote
(bracketed) ke PTY; teks biasa tak berubah.
**Status otomatis:** quoting/delivery/store teruji unit; gate
clipboard ter-compile; teks tak tersentuh (AC3.3 terbukti).
**Verifikasi manual** (X11 dan Wayland, masing-masing):

1. Config `wraith-image-paste = /tmp/wraith-test-pics`.
2. Salin gambar (screenshot / file manager) → paste di Ghostty →
   path `'.../paste-<ms>-<rand>.png'` terketik terbracket.
3. Salin teks → paste → teks verbatim (tanpa quote tambahan).
4. Cek file `0600`, dir `0700`; file >24 jam terprune saat start.

## 5. Paste gambar macOS (P3.4)

**Klaim:** sama seperti P3.3 di AppKit (`~/Library/Caches/...`).
**Status otomatis:** cabang macOS type-checked di Linux; logika
murni (`findImageData`, quote, store) teruji.
**Verifikasi manual** (butuh Mac): ulangi langkah P3.3 di aplikasi
macOS; pastikan request mime image hanya bila config set (default
off = perilaku stock).

## 6. Predictive echo rendering (P4.7)

**Klaim:** ketikan spekulatif tampil underline/dim di latency tinggi.
**Status otomatis:** seluruh aturan D10 teruji (gate/mode/hold/
confirm/cancel); rendering belum diimplementasikan di layer GUI.
**Verifikasi manual:** butuh implementasi renderer (di luar skop
v1) + link ≥30 ms (atau paksa `wraith-predictive-echo = always`):
ketik → echo ber-style → konfirmasi (style hilang) / mismatch
(echo terhapus).

## Audit `[!]`: nihil

Tidak ada task berstatus `[!]` (SKIPPED) di PROGRESS.md — tidak ada
`BLOCKERS.md` yang perlu diaudit. Tidak ada blocker hardware yang
ditemui selama pengerjaan (semua hambatan: toolchain/CRT/pip —
diselesaikan user-local, ADR-001/003/005).
