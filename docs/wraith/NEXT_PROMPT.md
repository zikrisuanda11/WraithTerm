# WraithTerm — PROMPT AGENT SELANJUTNYA

Salin-tempel blok di bawah ini sebagai pesan pertama ke agent baru (mis. di pc-zikri).
Prompt ini menggantikan ringkasan percakapan; semua detail kanonik ada di `docs/wraith/`.

---

## PROMPT (salin mulai dari baris ini)

Kamu melanjutkan proyek **WraithTerm**: fork Ghostty (`/home/<user>/tools/WraithTerm`)
yang menambahkan daemon detach/attach, remote lossy (SSP), copy-paste gambar lintas
platform, HUD, dan monitor harness `omp`. Spesifikasi lengkap & keputusan ada di
`WRAITH_SPEC` (dokumen yang dipegang pemilik proyek); ringkasan kanonik ada di repo.

### 0. Baca dulu (WAJIB, sebelum ngoding)
Baca berurutan dari repo:
1. `docs/wraith/PROGRESS.md` — status tiap task + **environment notes** + catatan iterasi terbaru.
2. `docs/wraith/DECISIONS.md` — ADR Wajib (D1–D11 dari spec) + ADR mandiri (ADR-001..004).
3. `docs/wraith/RECON.md` — peta modul nyata + cara hook.
4. `docs/wraith/ARCHITECTURE.md` — antarmuka Transport + LossyLink (P0.6).
5. `docs/wraith/PROTOCOL.md` — protokol pesan D3/D9/D10.
6. `docs/wraith/UPSTREAM.md` — basis upstream (D7, jangan fetch-merge).
7. `AGENTS.md`, `HACKING.md`, `CONTRIBUTING.md`, `AI_POLICY.md` di root repo.
8. `docs/wraith/LOOP_PROMPT.md` — pola loop kerja per iterasi.

### 1. Setup environment (SEKALI per mesin)
```bash
cd /path/ke/WraithTerm
source docs/wraith/build-env.sh --setup     # idempoten
```
`build-env.sh --setup` akan: (a) pakai Zig 0.16.0 di `~/.local/opt/zig` bila ada, jika tidak instruksikan unduh; (b) `pip3 install --user blueprint-compiler`; (c) ekstrak RPM `-devel` (libadwaita/gtk4-layer-shell/appstream) ke `~/.local/wraith-sysroot`, **dipin ke versi runtime** mesin; (d) set `PATH`/`PKG_CONFIG_PATH`/`LIBRARY_PATH`.

**Aturan mutlak:** `source docs/wraith/build-env.sh` sebelum SETIAP `zig build`/`zig build test`. Tanpa ini build gagal (lihat ADR-003). Jangan `sudo`, jangan ubah konfigurasi sistem (§0.7). Zig tidak ada di PATH sistem.

### 2. Verifikasi kondisi awal
```bash
source docs/wraith/build-env.sh
zig build                      # harus hijau -> zig-out/bin/ghostty
zig build test-lib-vt -Dtest-filter=headless   # prototipe P0.3 harus lulus
```

### 3. Kerjakan sesuai urutan PROGRESS
Ambil task **paling awal yang belum selesai** (`[ ]`/`[~]`) mengikuti urutan fase
(P0 → P1 → ... → P5). Jangan lompat fase. Task `[~]` = sebagian; **selesaikan dulu**.

**Prioritas saat ini (per commit `dd0532be0`):**
1. **P0.5** `[~]` — selesaikan baseline: jalankan **seluruh** suite + benchmark, isi
   `docs/wraith/BASELINE.md` dengan angka nyata.
   ```bash
   zig build test -Dtest-filter=            # suite penuh (lama; sabar)
   zig build -Demit-bench=true              # build bench
   # jalankan bench, catat hasil
   ```
   Bila test `apprt.gtk.adw_version` masih gagal → header/runtime libadwaita beda versi;
   pastikan `build-env.sh --setup` memakai versi yang dipin (ADR-003).
2. **P1.1** `[~]` — buat skeleton 9 aksi CLI baru D8 sebagai stub "not implemented"
   (exit non-zero): `+daemon`, `+attach`, `+list-sessions`, `+kill`, `+remote`,
   `+remote-server`, `+list-harnesses`, `+install-omp-bridge`, `+uninstall-omp-bridge`.
   - Pola: tambah varian di `enum Action` (`src/cli/ghostty.zig:31`), buat
     `src/cli/<nama>.zig` (`pub const Options` + `pub fn run`), daftarkan di arm
     `runMain` + `options()` (`ghostty.zig:~195`).
   - Prefix **`+`**, bukan `--` (`--daemon` double-dash adalah config key).
   - Completions (bash/fish/zsh) **auto-generate** dari enum `Action`
     (`src/extra/*.zig`) — tidak perlu edit manual.
   - `SessionId` sudah ada & teruji di `src/daemon/id.zig` (8-hex, CSPRNG).
   - Selesai bila: `+list-sessions --help` dsb berfungsi + test parsing lulus.

### 4. Aturan kerja (dari spec, tidak bisa dinegosiasi)
- **Doker**: branch per fase dari `wraith/dev`. Commit kecil & sering, conventional commits. **JANGAN hapus/force-push.**
- **Build hijau dulu** sebelum lanjut tiap sub-task. Jangan commit yang tidak compile.
- **Offline**: jangan fetch ini itu dari internet. Dokumentasi yang kau butuh sudah di sini.
- **D7**: JANGAN fetch-merge dari `upstream` ghostty. Pemilik proyek yang sinkron.
- **§0.7**: JANGAN `sudo`, jangan ubah konfigurasi sistem, jangan auto-install paket sistem. Semua user-local.
- **Selalu `source docs/wraith/build-env.sh`** sebelum build/test.
- Setiap iterasi: update `docs/wraith/PROGRESS.md` (checkbox + catatan singkat dengan bukti verifikasi). Blocker hardware → `docs/wraith/BLOCKERS.md` (`[BLOCKED]`).
- **Bukti, bukan klaim.** Jalankan test; tempel hasil. `[UNVERIFIED]` bila tidak bisa diverifikasi.
- Verifikasi GUI di mesin tanpa sesi interaktif → tandai `[~]` per ADR-002.

### 5. Titik kritis yang sudah ditemukan (jangan temukan ulang)
- PTY dimiliki `termio.Exec.Subprocess.pty`; **`Subprocess.stop()` mengirim SIGHUP**
  (`src/termio/Exec.zig:1110-1210`). Saat client detach, daemon **tidak boleh** panggil
  `stop()` (AC1.1).
- State headless = engine yang sama dengan `libghostty-vt`, diakses via modul Zig
  (`Terminal`/`TerminalStream` re-export `src/lib_vt.zig`) — ADR-004.
- `TerminalStream.Handler` menyimpan `*Terminal` → `Terminal` **wajib** di heap/alamat
  stabil selama stream hidup.
- `tc netem` dilarang (uid bukan root) → pakai `LossyLink` untuk uji transport (AC2.5).

### 6. Serahkan kembali
Saat diminta berhenti / pindah mesin: commit semua, push ke `origin`
(`zikrisuanda11/WraithTerm`), lalu update `PROGRESS.md` (status jujur, termasuk yang
belum tuntas). Branch saat ini: `wraith/phase0-recon`.

## AKHIR PROMPT
