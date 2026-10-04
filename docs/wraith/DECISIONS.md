# WraithTerm — DECISIONS (ADR-lite)

Salinan §3 WRAITH_SPEC + keputusan mandiri (§2.7). Setiap keputusan non-trivial dicatat: konteks, pilihan, alasan.

## D1 — Image paste ke PTY: pendekatan (a), file sementara terkelola + paste path
- Saat paste gambar terdeteksi, simpan ke `$XDG_CACHE_HOME/wraith/paste/` (macOS: `~/Library/Caches/wraith/paste/`), nama `paste-<unix_ms>-<rand6>.png` (JPEG disimpan `.jpg`), file `0600`, direktori `0700`.
- Kirim ke PTY sebagai **bracketed paste** berisi path absolut (quote aman untuk shell: single-quote bila ada karakter spesial).
- Lifecycle: hapus file > 24 jam saat daemon/app start & tiap jam; batas total direktori 200 MiB (hapus tertua dulu); batas satu gambar 25 MiB (lebih besar: pesan gagal, jangan paste).
- Config: `wraith-image-paste = path | off` (default `off`).
- Mode (b) OSC/APC dan (c) preview **tidak** diimplementasikan di v1. Hook `deliverImage(mode, ...)` disisakan.
- Remote (SSP): klien simpan file lokal, paste path **remote** via payload chunked (P4.8); host remote menulis ke direktori paste miliknya dan mem-paste path remote.

## D2 — Bootstrap remote: via SSH (pola Mosh)
`wraith --remote user@host[:port]` menjalankan `ssh user@host wraith --remote-server`; server mencetak satu baris `WRAITH CONNECT <udp_port> <base64_session_key>` lalu menunggu paket UDP pertama. Klien memutus SSH setelah handshake UDP sukses. Kunci sesi 32 byte acak dari CSPRNG, hidup hanya selama session, tidak pernah ditulis ke disk, tidak muncul di log. Server menutup diri bila tidak ada klien terotentikasi dalam 60 detik pertama, dan bila tidak ada paket sama sekali dalam 7 hari (dapat dikonfigurasi).

## D3 — Kripto: ChaCha20-Poly1305 dengan kunci sesi dari bootstrap
- `std.crypto.aead.chacha_poly.ChaCha20Poly1305`.
- Nonce 12 byte = `[4 byte: 0x00000000 client→server, 0x00000001 server→client][8 byte: sequence counter LE]`. Counter hanya naik, tidak pernah dipakai ulang pada kunci sama.
- Replay protection: jendela geser 1024 paket per arah; tolak seq di luar/di dalam jendela yang sudah terlihat.
- Header paket (seq, flags) ikut sebagai AAD. Paket gagal otentikasi dibuang diam-diam (tanpa balasan).
- Tanpa key rotation di v1; session baru = kunci baru. Tanpa Noise di v1. Model ancaman di `PROTOCOL.md`.

## D4 — Scrollback
- Lokal (attach ke daemon): pulihkan hingga `wraith-scrollback-lines` (default **10000**) baris, dikirim chunked setelah snapshot layar aktif, dengan batas memori per session di daemon.
- SSP (remote): sinkronkan **hanya layar aktif** (seperti Mosh). Scrollback remote tidak disinkronkan di v1.

## D5 — HUD: native per platform
macOS = SwiftUI, Linux = GTK4 widget (ikuti pola `apprt`). Urutan: model data + CLI JSON (`--list-harnesses --json`) dulu, baru UI native (compile-verified, `[~]` bila tak bisa dijalankan).

## D6 — Kanal event bridge omp → daemon: Unix socket lokal
- Daemon membuat satu socket harness `wraith-harness-<daemon_id>.sock` (`0600`) di `$XDG_RUNTIME_DIR` (fallback `$TMPDIR`), inject env ke child: `WRAITH_HARNESS_SOCK=<path>`, `WRAITH_SESSION_ID=<id>`.
- Bridge `.ts` menulis **JSON lines** (satu objek per baris, maks 4 KiB), fire-and-forget:
  `{"v":1,"type":"state","state":"idle|thinking|executing_tool|awaiting_approval|error","tool":"<nama?>","ts":<ms>,"omp_version":"<x>","session_id":"<WRAITH_SESSION_ID>","tokens":{"in":<n>,"out":<n>}}` (`tool`, `tokens` opsional).
- Remote: daemon remote meneruskan event lewat payload telemetri SSP (P4.8).
- Bila omp tidak mengekspos event cukup (`awaiting_approval`, token usage): jangan menebak. Bridge hanya kirim event yang benar-benar tersedia dari API omp hasil recon P2.1; state tak tersedia diturunkan dari Tier 3 (parsing ANSI, best-effort) dengan `"confidence":"low"`, atau `unknown`. Batas ini didokumentasikan di `HARNESS_OMP.md`.
- Komunikasi **satu arah** (omp → daemon). Daemon tidak mengirim apa pun ke omp.

## D7 — Sinkronisasi upstream: manual, di luar cakupan agent
Agent **tidak** merge/rebase dari `upstream`. Cukup catat commit upstream yang menjadi basis di `UPSTREAM.md` (hash, tanggal, versi Zig). Pemilik proyek menangani merge upstream sendiri setelah selesai.

## D8 — Model session & kontrol
- ID session: 8 karakter hex acak.
- Daemon default: satu daemon per user, socket kontrol `$XDG_RUNTIME_DIR/wraith/<user>.sock` (macOS: `$TMPDIR/wraith-<uid>/control.sock`), direktori `0700`, socket `0600`.
- Satu client interaktif per session; attach baru mengambil alih (client lama terima `Detached(reason=taken_over)`).
- Daemon dimulai otomatis bila `wraith-daemon = auto` (default `off`); `wraith --daemon` memulai manual. Daemon keluar sendiri bila tidak ada session selama 10 detik **dan** dijalankan dengan `--exit-when-empty`.
- Config keys WraithTerm berprefix `wraith-`; default semuanya menjaga perilaku Ghostty asli.

## D9 — Format protokol
- Biner, little-endian, tanpa library serialisasi eksternal. Frame: `[u32 length][u8 protocol_version][u8 msg_type][payload]`. `protocol_version = 1`.
- Batas: pesan lokal ≤ 1 MiB; datagram SSP ≤ 1200 byte (fragmentasi untuk lebih besar, reassembly timeout 5 dtk, batas total 4 MiB).
- Tipe pesan minimum: `Hello`, `Snapshot`, `Diff`, `Input`, `Resize`, `Control`, `Detached`, `Telemetry`, `ImageChunk`, `Ack`, `Error`.
- Parser **wajib** menolak (bukan crash) input salah bentuk, melebihi batas, atau versi tak dikenal.

## D10 — Predictive echo (Phase 4)
Mode `wraith-predictive-echo = adaptive | always | never` (default `adaptive`: aktif bila smoothed RTT > 30 ms). Prediksi hanya untuk karakter cetak di layar normal (bukan alt screen), ditampilkan underline/dim; dikonfirmasi saat state server mencapai epoch prediksi; dibatalkan & dihapus bila tidak cocok; dimatikan sementara setelah Enter/kontrol, saat alt-screen aktif, dan saat echo-off (password).

---

# Keputusan mandiri tambahan (ADR §2.7)

## ADR-001 — Toolchain Zig user-local (2026-10-04)
- **Konteks:** `zig` tidak terpasang di system PATH; `build.zig.zon` butuh `minimum_zig_version = "0.16.0"`. Tanpa Zig, semua task build/test mustahil.
- **Pilihan:** unduh tarball resmi Zig 0.16.0 ke `~/.local/opt/zig-0.16.0/` + symlink `~/.local/opt/zig`; pakai `PATH="$HOME/.local/opt/zig:$PATH"`. Tidak menyentuh konfigurasi sistem, tidak `sudo`.
- **Alasan:** repo §0.6 melarang aksi di luar repo kecuali tmp/XDG; memasang toolchain di `$HOME` adalah jalur minimal & revertable untuk bisa build. Pinned 0.16.0 persis sesuai minimum repo (bukan master) demi reproduksibilitas.
- **Catatan:** dicatat di RECON.md & BASELINE.md; commit tidak menyertakan toolchain.

## ADR-002 — Environment: display tersedia, root tidak
- **Konteks:** `DISPLAY=:0` + `WAYLAND_DISPLAY=wayland-0` ada; uid 1000 (bukan root); `tc` ada tapi butuh root.
- **Pilihan:** GUI mungkin bisa dibangun (`zig build`), tapi verifikasi runtime GUI/Linux clipboard tetap `[~]` bila tidak ada sesi interaktif yang bisa diverifikasi agent. Transport loss memakai `LossyLink` (P4.2), bukan `tc netem`.
- **Alasan:** §2.5 menetapkan `LossyLink` sebagai metode uji resmi AC2.5.

## ADR-003 — Build user-local tanpa root (blueprint-compiler + sysroot header devel) (2026-10-04)
- **Konteks:** `zig build` gagal: `blueprint-compiler` tidak terpasang, dan header devel `adwaita.h` (libadwaita-devel), `gtk4-layer-shell.h`, serta `appstream.pc` (appstream-devel) tidak ada. §0.7 melarang `sudo`/ubah konfigurasi sistem.
- **Pilihan:** (1) `pip3 install --user blueprint-compiler` (0.22.2, wheel murni Python) → `~/.local/bin`. (2) `dnf download --setopt=repo_gpgcheck=False --setopt=gpgcheck=False` RPM devel (x86_64) lalu ekstrak ke sysroot privat `~/.local/wraith-sysroot` via `rpm2cpio | cpio -idm` (tanpa instalasi). (3) `.pc` di sysroot ditulis ulang ke path sysroot; symlink `.so` dev diarahkan ke `lib*.so.0` sistem. (4) env `PKG_CONFIG_PATH` + `LIBRARY_PATH` di-set saat build. Semua dibungkus `docs/wraith/build-env.sh` (idempoten, `--setup`).
- **Alasan:** satu-satunya jalur memenuhi §0.7 (tanpa root) sambil membuat build hijau; reversible (hapus `~/.local/wraith-sysroot` + `pip3 uninstall`). Downside: environment build tidak standar — dicatat di PROGRESS.md & BASELINE.md, dan tidak ada artefak sysroot yang di-commit (hanya skrip setup).
- **Hasil:** `zig build` **hijau** → `zig-out/bin/ghostty` (`Ghostty 1.3.2-wraith-phase0-recon`).

## ADR-004 — State terminal headless: engine yang sama dengan `libghostty-vt`, dipakai lewat modul Zig (2026-10-04)
- **Konteks:** §5 meminta daemon memakai `libghostty-vt` untuk state layar headless, dengan fallback ke modul `src/terminal/` internal bila tidak layak. P0.3 harus memverifikasi.
- **Temuan (lihat RECON.md §2.2):** `src/lib_vt.zig` (modul yang membangun `libghostty-vt`) **mengekspor ulang tipe internal**: `Terminal` (`lib_vt.zig:94`), `TerminalStream`:95, `Stream`:96, `TinyIo`:51. ABI C (`include/ghostty/vt/terminal.h`) membungkus engine yang sama. Prototipe `src/terminal/headless_proto.zig` membuktikan headless tanpa PTY/GUI/renderer: `Terminal.init(TinyIo.io(), ...)` + `TerminalStream.init` + `nextSlice` → baca grid via `screens.active.pages.getCell(.{.active=.{...}})` (`.cell.content.codepoint.data`, `style_id`), alt-screen (`?1049h/l`), `resize`, dan split-escape lintas-feed. Semua lulus.
- **Pilihan:** daemon memakai **engine terminal yang sama yang dipublikasikan `libghostty-vt`**, diakses lewat permukaan modul Zig (`Terminal`/`TerminalStream`/`Stream` hasil re-export `src/lib_vt.zig`), **bukan** memanggil ABI C di dalam proses yang sama.
- **Alasan:** (1) memenuhi maksud §5 (memakai engine libghostty-vt, dan tetap kompatibel bila nanti dipakai ABI C untuk embedder eksternal); (2) menghindari batas FFI intra-proses yang menambah marshalling, callback non-reentrant, dan grid_ref pinjam-pakai yang harus segera disalin; (3) tipe internal = tipe yang di-re-export, jadi tidak ada duplikasi konvensi; (4) risiko "API belum stabil" dikurung di balik adapter tipis milik daemon.
- **Catatan desain penting (untuk P1.4):** `TerminalStream.Handler` menyimpan `*Terminal`, jadi `Terminal` **harus** beralamat stabil (di-heap) selama stream hidup — memindahkan `Terminal` by-value pasca-`Stream.init` akan menggantung pointer. Adapter `Headless` mengalokasikan `Terminal` di heap dan hanya memberikan pointer. ABI C tetap dibangun (`-Demit-lib-vt`) untuk embedder eksternal.
