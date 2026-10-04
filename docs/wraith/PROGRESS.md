# WraithTerm — PROGRESS

Satu-satunya sumber kebenaran "task apa berikutnya".

Status: `[ ]` belum · `[x]` selesai · `[~]` DONE-UNVERIFIED (lihat NEEDS_HUMAN_VERIFICATION.md) · `[!]` SKIPPED (lihat BLOCKERS.md)

Aturan iterasi: kerjakan SATU task `[ ]` pertama (dari atas) yang seluruh dependensinya sudah `[x]`/`[~]`/`[!]`. Implementasi → `zig build` → test → debug → commit (branch != main) → update berkas ini.

## Environment notes (dibaca tiap iterasi)
- **Onboarding agent baru:** baca `docs/wraith/NEXT_PROMPT.md`. **Pola loop tiap iterasi:** `docs/wraith/LOOP_PROMPT.md`.
- Zig TIDAK terpasang di system PATH. Toolchain user-local di `~/.local/opt/zig/zig` (0.16.0, sesuai `build.zig.zon` `minimum_zig_version`).
- **WAJIB: `source docs/wraith/build-env.sh` sebelum SETIAP `zig build`/`zig build test`.** Skrip men-set `PATH` (zig + `~/.local/bin`), `PKG_CONFIG_PATH`, `LIBRARY_PATH`. Setup lengkap: `docs/wraith/build-env.sh --setup` (idempoten). Latar: ADR-003 (blueprint-compiler via pip `--user`; header devel dari RPM diekstrak ke `~/.local/wraith-sysroot`; tanpa root).
- `bun` ada (`~/.bun/bin/bun`), `omp` ada (`~/.bun/bin/omp`, v18.4.0). `nix` tidak ada. Ada display X11 (`:0`) + Wayland. uid 1000 (bukan root) → `tc netem` tidak dipakai; pakai `LossyLink`.
- Remote `upstream` (ghostty) sudah ditambahkan (read-only ref, D7).
- **`zig build` sudah TERVERIFIKASI hijau** (2026-10-04) → `zig-out/bin/ghostty` = `Ghostty 1.3.2-wraith-phase0-recon`.

## Phase 0 — Recon & Fondasi
- [x] **P0.1** Buat branch `wraith/dev` dari `main`, lalu `wraith/phase0-recon`. Baca dokumen §0 poin 2. Buat `docs/wraith/PROGRESS.md` dan `DECISIONS.md` (salin §3). *Selesai bila:* kedua berkas ada dan ter-commit.
- [x] **P0.2** ← P0.1. Cek lingkungan (§2.5) dan petakan `src/` yang sebenarnya (termio, pty, Surface, App, apprt, renderer, input, config) di `RECON.md`, koreksi peta §5. *Selesai bila:* `RECON.md` memuat tabel modul nyata + hasil cek lingkungan.
- [x] **P0.3** ← P0.2. Evaluasi `libghostty-vt` untuk dipakai headless; putuskan sesuai §5 prinsip; buat prototipe kecil (test) yang memberi makan byte ke terminal headless dan membaca grid layar. *Selesai bila:* test prototipe lulus dan keputusan tercatat.
- [x] **P0.4** ← P0.2. Tulis `PROTOCOL.md` final berdasarkan D3, D9, D10 (layout byte tiap pesan, state machine handshake, model ancaman). *Selesai bila:* semua tipe pesan D9 terdefinisi lengkap.
- [~] **P0.5** ← P0.2. Jalankan `zig build` dan seluruh test suite baseline + benchmark yang ada; catat hasil di `BASELINE.md`; catat basis upstream di `UPSTREAM.md` (D7). *Selesai bila:* kedua berkas berisi angka/hash nyata. *(sebagian: `zig build` hijau + `UPSTREAM.md` selesai; `BASELINE.md` belum — run suite penuh belum tuntas)*
- [x] **P0.6** ← P0.1. Rancang test `LossyLink` secara tertulis di `ARCHITECTURE.md` (antarmuka transport yang bisa diganti, parameter loss/delay/dup/reorder, PRNG ber-seed). *Selesai bila:* antarmuka terdokumentasi.
- **Phase gate P0:** build hijau, berkas docs ada, tidak ada perubahan fungsional. Merge ke `wraith/dev`.

## Phase 1 — Daemon + Attach/Detach (Pilar 1)
- [~] **P1.1** ← P0.* CLI skeleton semua aksi baru (D8) sebagai stub yang mencetak "not implemented" dan exit code non-zero. *Selesai bila:* `--help`/parsing aksi berfungsi, test parsing lulus. *(sebagian: `SessionId` selesai + teruji; skeleton aksi CLI belum)*
- [ ] **P1.2** ← P0.4 Codec pesan (encode/decode semua tipe D9) dengan unit test termasuk kasus malformed/oversize/versi salah. *Selesai bila:* round-trip test + negative test lulus.
- [ ] **P1.3** ← P1.2 Session manager (create/list/kill, ID D8, batas memori scrollback). *Selesai bila:* unit test lulus.
- [ ] **P1.4** ← P0.3, P1.3 Daemon memiliki PTY + child (spawn, resize, baca output ke state headless; tidak ada SIGHUP saat client lepas). *Selesai bila:* test integrasi: spawn `sh -c 'sleep 30'`, putus client, proses tetap hidup.
- [ ] **P1.5** ← P1.4 Snapshot + serialisasi layar & scrollback chunked (D4). *Selesai bila:* test: isi layar dengan output deterministik → snapshot → rekonstruksi → grid identik.
- [ ] **P1.6** ← P1.2 Unix socket server kontrol dengan permission `0600`/`0700` (D8). *Selesai bila:* test memverifikasi mode file.
- [ ] **P1.7** ← P1.5, P1.6 Client **headless** (test client) untuk attach/detach/input; lalu `--attach <id>` di GUI (`[~]` bila GUI tak bisa dijalankan). *Selesai bila:* test integrasi: spawn → detach → attach ulang → layar identik; attach kedua mengambil alih yang pertama.
- [ ] **P1.8** ← P1.7 `--list-sessions`, `--kill <id>`, `--exit-when-empty`, `wraith-daemon = auto`. *Selesai bila:* test integrasi tiap perintah.
- [ ] **P1.9** ← P1.8 Regression: seluruh test Ghostty lama lulus; benchmark vs `BASELINE.md` tidak turun signifikan (>5% = perbaiki). *Selesai bila:* hasil dicatat di `BASELINE.md`.
- **Phase gate P1:** build + semua test hijau, fitur opt-in. Merge ke `wraith/dev`.

## Phase 2 — Harness Monitoring omp (Pilar 4)
- [ ] **P2.1** ← P1.9 Recon omp: bila `omp` terpasang, baca versi + dokumentasi hook/extension API; bila tidak ada, coba `bun add -g @oh-my-pi/pi-coding-agent` atau clone `can1357/oh-my-pi` (jika jaringan diizinkan) dan baca source. Daftar event lifecycle **nyata**, format `settings.json`, lokasi extension. Rekam fixture event; bila omp tidak dapat diperoleh sama sekali, buat fixture **sintetis** berlabel `synthetic` di nama berkas dan catat batasnya. Tulis `HARNESS_OMP.md`. *Selesai bila:* dokumen memuat daftar event, versi omp, dan keputusan Tier 1 vs Tier 3 per state (D6).
- [ ] **P2.2** ← P1.4 Process detector Tier 2 (pure function atas snapshot process tree; Linux `/proc`, macOS `libproc`). *Selesai bila:* unit test dengan fixture process tree (termasuk `bun`/wrapper) lulus.
- [ ] **P2.3** ← P2.1 Skema event D6 + parser JSON-lines di Zig (batas 4 KiB/baris, malformed diabaikan). *Selesai bila:* unit test dengan fixture + kasus malformed lulus.
- [ ] **P2.4** ← P1.4, P2.3 Socket harness di daemon + injeksi env `WRAITH_HARNESS_SOCK`/`WRAITH_SESSION_ID`; state machine per session. *Selesai bila:* test integrasi: client palsu menulis event → state session berubah; socket mode `0600`.
- [ ] **P2.5** ← P2.1 `wraith-omp-bridge.ts` (fire-and-forget, timeout ≤ 50 ms, diam bila socket tak ada), di-embed dengan `@embedFile`. *Selesai bila:* test (menjalankan dengan `bun` bila ada; jika tidak, test statis atas isi berkas + `[~]`) membuktikan tidak melempar saat socket tidak ada.
- [ ] **P2.6** ← P2.5 Installer/uninstaller idempoten (AC4.3) dengan `HOME` sementara. *Selesai bila:* test: install 2× = hasil sama; extension pengguna lain tidak tersentuh; backup dibuat; uninstall hanya menghapus file ber-marker; uninstall saat tidak terpasang tidak error.
- [ ] **P2.7** ← P2.4, P2.2 `--list-harnesses [--json]` menggabungkan Tier 1 + Tier 2. *Selesai bila:* test snapshot output JSON.
- [ ] **P2.8** ← P2.7 Notifikasi OS saat `awaiting_approval` (shim per platform; gagal anggun). *Selesai bila:* logika pemicu teruji unit; pemanggilan OS `[~]` bila tak bisa dijalankan.
- [ ] **P2.9** ← P2.7 HUD native minimal (daftar + state) sesuai D5. *Selesai bila:* build lulus di platform host; `[~]` bila tak dapat dijalankan.
- [ ] **P2.10** ← P2.4 Fallback ANSI parser Tier 3 (best-effort, `confidence: low`). *Selesai bila:* unit test dengan fixture; hasil `unknown` diperbolehkan.
- **Phase gate P2:** build + test hijau; installer tidak merusak `~/.omp` asli (dibuktikan test dengan HOME sementara). Merge ke `wraith/dev`.

## Phase 3 — Image Paste (Pilar 3)
- [ ] **P3.1** ← P1.9 Store gambar terkelola (D1: nama, permission, quota, TTL, pembersihan). *Selesai bila:* unit test lifecycle (TTL, quota, ukuran maks) lulus.
- [ ] **P3.2** ← P3.1 Pengiriman bracketed paste path ter-quote + config `wraith-image-paste`. *Selesai bila:* test quoting (spasi, kutip, karakter spesial) + test paste teks tidak berubah (AC3.3).
- [ ] **P3.3** ← P3.2 Deteksi clipboard Linux GTK (X11 + Wayland). *Selesai bila:* build lulus; `[~]` bila tak ada display.
- [ ] **P3.4** ← P3.2 Deteksi clipboard macOS AppKit. *Selesai bila:* kode compile-guarded; `[~]` bila host bukan macOS.
- **Phase gate P3:** build + test hijau. Merge ke `wraith/dev`.

## Phase 4 — Remote SSP (Pilar 2)
- [ ] **P4.1** ← P0.4 Modul kripto (D3): AEAD, nonce, jendela replay. *Selesai bila:* test: round-trip, tamper ditolak, replay ditolak, nonce tidak berulang, arah berbeda tak saling dekripsi.
- [ ] **P4.2** ← P0.6, P4.1 Transport datagram (fragmentasi/reassembly, timeout) di balik antarmuka + `LossyLink` (loss/delay/dup/reorder, seed tetap). *Selesai bila:* test fragmentasi di bawah loss/reorder lulus deterministik.
- [ ] **P4.3** ← P4.1, P1.8 Bootstrap SSH + handshake (D2), mode `--remote-server`, timeout 60 dtk. *Selesai bila:* test bootstrap dengan "SSH palsu" (skrip lokal) + test timeout.
- [ ] **P4.4** ← P4.2, P4.3 Sinkronisasi snapshot penuh (tanpa diff) end-to-end. *Selesai bila:* e2e loopback: layar klien == layar server.
- [ ] **P4.5** ← P4.4 Diff state + ack/retransmit berbasis nomor state (bukan byte). *Selesai bila:* e2e dengan `LossyLink` loss 10%, 20%, 30% + jitter + dup: layar akhir identik di 20 seed berbeda.
- [ ] **P4.6** ← P4.5 Roaming + reconnect (AC2.4). *Selesai bila:* test: ganti alamat peer di tengah session → sinkron berlanjut; paket lama/replay dari alamat lain tidak membajak.
- [ ] **P4.7** ← P4.5 Predictive echo (D10). *Selesai bila:* unit test aturan prediksi/konfirmasi/pembatalan; rendering indikator `[~]` bila tak bisa dijalankan.
- [ ] **P4.8** ← P4.5, P3.2, P2.4 Payload ekstensi: `ImageChunk` (host remote menulis file & paste path remote) dan `Telemetry` (event harness). *Selesai bila:* e2e dengan `LossyLink`: gambar utuh (hash sama), event harness tiba berurutan.
- [ ] **P4.9** ← P4.1, P1.2 Fuzz parser pesan (lokal & SSP) dan reassembly: minimal 1 juta input acak ber-seed tanpa crash/hang/OOM. *Selesai bila:* test fuzz lulus; temuan diperbaiki.
- [ ] **P4.10** ← P4.8 Uji ketahanan akhir: e2e panjang (output besar, resize, sleep simulasi/gap 30 dtk, loss 30%). *Selesai bila:* lulus di 20 seed.
- **Phase gate P4:** build + semua test hijau. Merge ke `wraith/dev`.

## Phase 5 — Finalisasi
- [ ] **P5.1** ← semua fase Regression penuh: seluruh test Ghostty lama + baru; benchmark vs baseline. *Selesai bila:* hasil dicatat.
- [ ] **P5.2** ← P5.1 Selesaikan `ARCHITECTURE.md`, perbarui `PROTOCOL.md` sesuai implementasi akhir, tambah bagian "WraithTerm" singkat di dokumentasi (cara aktifkan tiap fitur, config keys). *Selesai bila:* dokumen konsisten dengan kode.
- [ ] **P5.3** ← P5.1 Kompilasi `NEEDS_HUMAN_VERIFICATION.md` dari semua task `[~]` (langkah verifikasi manual yang dapat diulang) dan audit `BLOCKERS.md` dari semua `[!]`. *Selesai bila:* tiap `[~]`/`[!]` punya entri.
- [ ] **P5.4** ← P5.2, P5.3 Tulis `FINAL_REPORT.md`; merge final ke `wraith/dev`; tulis `WRAITH_DONE` (§2.6).

## Catatan iterasi
- **P0.5 (in-progress):** `zig build` **hijau** (terverifikasi) → `zig-out/bin/ghostty`. `UPSTREAM.md` selesai (basis `f96c9711b`, 2026-10-04, versi 1.3.2-dev). **BELUM selesai:** jalankan seluruh test suite baseline + benchmark dan catat angkanya di `BASELINE.md` (run pertama terjegal test `apprt.gtk.adw_version` karena header/runtime libadwaita beda versi — sudah diperbaiki: header 1.8.7 dipin di sysroot; run ulang belum tuntas). Lanjutkan di pc-zikri: `source docs/wraith/build-env.sh --setup` lalu `zig build test -Dtest-filter=` dan `-Demit-bench=true`.
- **P1.1 (partial):** `src/daemon/id.zig` (`SessionId` 8-hex, CSPRNG via `sys.randomSecure`, 4 unit test lulus; ter-wire di `src/main.zig` test root). **BELUM:** skeleton aksi CLI (`+daemon`,`+attach`,`+list-sessions`,`+kill`,`+remote`,`+remote-server`,`+list-harnesses`,`+install-omp-bridge`,`+uninstall-omp-bridge`) sebagai stub "not implemented" + test parsing. Catatan: shell completions (bash/fish/zsh) auto-generate dari enum `Action` (`src/extra/*.zig`), jadi aksi baru propagasi otomatis.
- **P0.6 (done):** `docs/wraith/ARCHITECTURE.md` — antarmuka `Transport` yang dapat diganti + `LossyLink` (loss/delay/dup/reorder, PRNG ber-seed, jam virtual) + skenario uji AC2.5 (20 seed, loss 10/20/30%).
- **P0.4 (done):** `PROTOCOL.md` — framing `[u32 len][u8 ver][u8 type][payload]`; 11 tipe D9 lengkap (`Hello` 0x01 … `Error` 0x7F) dengan layout byte per pesan; kapabilitas bitmask; state machine handshake IPC lokal + bootstrap SSP; kripto D3 (nonce 4+8, replay window 1024, AAD header); roaming AC2.4; predictive echo D10; model ancaman (dilindungi vs di luar cakupan).
- **P0.3 (done):** prototipe headless `src/terminal/headless_proto.zig` (6 test: teks→grid, SGR style, cursor addressing, split escape lintas-feed, alt-screen, resize) — lulus via `zig build test-lib-vt -Dtest-filter=headless` (83/83 test, EXIT=0). Keputusan ADR-004: pakai engine libghostty-vt lewat re-export modul Zig `src/lib_vt.zig`. Temuan penting: `TerminalStream.Handler` menyimpan `*Terminal` → Terminal wajib hidup di heap/alamat stabil.
- **P0.1 (done):** branch `wraith/dev` + `wraith/phase0-recon` dibuat; `upstream` remote ditambahkan; PROGRESS.md + DECISIONS.md dibuat. Baca AGENTS.md, HACKING.md, CONTRIBUTING.md, AI_POLICY.md. Verifikasi: `git branch --show-current` = `wraith/phase0-recon`; berkas ada.
- **P0.2 (done):** `RECON.md` dibuat — cek lingkungan lengkap (Zig user-local 0.16.0, omp 18.4.0 riil, GTK4 4.20.4, uid 1000, display ada) + peta modul nyata dengan bukti file:line untuk termio/pty (`backend.zig` Backend/ThreadData union; PTY di `Exec.Subprocess.pty`; SIGHUP di `Subprocess.stop()`), terminal headless (`Terminal`/`TerminalStream`/ABI C `libghostty-vt`), CLI (`Action` enum prefix `+`), apprt/input/config (funnel `terminal/paste.zig`, HUD `renderer/Overlay.zig`). Verifikasi: 4 scout read-only + spot-check `grep`; peta §5 dikoreksi. Build baseline ditunda ke P0.5 (deps diunduh di sana).
