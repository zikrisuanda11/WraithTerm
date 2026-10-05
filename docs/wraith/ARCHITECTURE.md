# WraithTerm — ARCHITECTURE (final, P5.2)

Arsitektur implementasi akhir di branch `wraith/phase0-recon`
(P0–P5.1). Semua path file relatif ke repo root.

## 1. Prinsip arsitektur (dari §5, terbukti)

```
┌──────────────┐   Unix socket / UDP-SSP    ┌─────────────────────────┐
│ Wraith GUI   │ ◄────────────────────────► │ Wraith Daemon           │
│  renderer,   │   snapshots/diffs, input   │  ├─ Session manager     │
│  input,      │                            │  ├─ PTY + child procs   │
│  predictive  │                            │  ├─ Terminal state      │
│  echo, HUD   │                            │  ├─ Harness monitor     │
└──────────────┘                            │  └─ IPC / SSP server    │
   omp ──(WRAITH_HARNESS_SOCK, JSON lines)──► Harness monitor
                                            └─────────────────────────┘
```

- **Daemon = pemilik tunggal PTY master + state terminal.** GUI = view + input.
- IPC lokal dan SSP berbagi **model pesan** (`PROTOCOL.md`, D9); hanya transport berbeda.
- Semua pesan berversi + berbatas ukuran.

## 2. Kepemilikan PTY & state (P0.2–P1.4)

- PTY master dimiliki `termio.Exec.Subprocess.pty` (`src/termio/Exec.zig:592`). **SIGHUP ke
  process group dikirim di `Subprocess.stop()`** (`Exec.zig:1110-1210`), dipanggil saat
  `threadExit`. Untuk daemon, detach client **tidak boleh** memanggil `stop()` (AC1.1).
- Daemon memakai `src/daemon/pty.zig` (`DaemonPty`: PTY + child + `Headless` terminal),
  bukan `termio.Exec.Subprocess` (terlalu berat: butuh `renderer.GridSize`, `apprt.runtime`).
- State layar headless memakai engine yang sama dengan `libghostty-vt` (ADR-004), diakses
  via modul Zig (`Terminal`/`TerminalStream` re-export `src/lib_vt.zig`). `Terminal` wajib
  beralamat stabil (heap) selama `TerminalStream` hidup.

## 3. Daemon lokal (`src/daemon/`, P1.2–P1.8)

| Modul | Peran |
|---|---|
| `codec.zig` | Framing D9 `[u32 len][u8 ver][u8 type][payload]`, 14 tipe (Hello…HarnessList…Error); `decode` zero-copy + `decodeAlloc` untuk tabel variabel |
| `id.zig` | `SessionId` 8-hex dari CSPRNG (`terminal/sys.zig`) |
| `session.zig` | `Manager`: cap 64 session, 4 MiB scrollback/session, attach/takeover |
| `pty.zig` | Spawn PTY + child, `pump`/`resize`/`kill`; EIO Linux = EOF |
| `snapshot.zig` | Encode layar+scrollback via `terminal/snapshot`, chunked 64 KiB |
| `socket.zig` | Listener Unix socket (`0700` dir, `0600` socket; `chmod`, bukan `fchmod`) |
| `server.zig` + `client.zig` | Serving loop + headless client (attach/detach/takeover, `InMessage` pinjam-buf) |
| `server.zig` `run()` | Loop poll-1s + idle-10s D8 (`--exit-when-empty`) |
| CLI (`src/cli/`) | `+daemon`, `+attach`, `+list-sessions`, `+kill <id>` (positional ala ssh-cache), `+remote`, `+remote-server`, `+list-harnesses [--json]`, `+install/uninstall-omp-bridge`; auto-spawn bila `wraith-daemon=auto` |

## 4. Harness omp (`src/daemon/harness_*`, P2.1–P2.10)

Tiga tier (D6), semua terbukti terhadap omp 18.4.4 riil (`HARNESS_OMP.md`):

- **Tier 1 (event)**: `wraith-omp-bridge.ts` (11 hook → state, 1×50 ms fire-and-forget)
  menulis JSON-lines ke socket `0600` (`harness_sock.zig`); `harness_event.zig` mem-parse
  (cap 4 KiB/baris, malformed diabaikan); state per session di `LiveSession.harness`.
- **Tier 2 (process)**: `harness_detect.zig` — DFS murni atas snapshot `/proc`
  (argv[0]→basename, wrapper `bun`/`node`/`deno` dihitung).
- **Tier 3 (ANSI)**: `harness_tier3.zig` — klasifikasi best-effort (`confidence: low`,
  default `unknown`); tidak dibutuhkan untuk omp 18.4.4 (semua state ada event Tier 1).
- Konsumen: `harness_list.zig` (verdict Tier1→Tier2→none, text+JSON),
  `harness_notify.zig` (edge `awaiting_approval` → notify-send/osascript),
  HUD GTK `toggle_harness_hud`, installer idempoten `harness_install.zig` (AC4.3).

## 5. Image paste (P3.1–P3.4, D1)

`image_store.zig` (nama D1, `0600`, sniff PNG/JPEG, tolak >25 MiB; prune TTL-24h +
kuota-200MiB oldest-first) → `image_paste.zig` (`quoteShell` + `deliverImage(.path)`
via `input.paste.encode`, teks tak tersentuh/AC3.3) → deteksi clipboard Linux
(`apprt/gtk/class/surface.zig`: texture→PNG→store→path-sebagai-teks) dan macOS
(`apprt/embedded.zig`, macos-gated: minta image mime → store `~/Library/Caches` →
substitusi path). Config: `wraith-image-paste = off | <dir>`.

## 6. SSP remote (`src/daemon/ssp_*`, P4.1–P4.10)

| Modul | Peran |
|---|---|
| `ssp_crypto.zig` | D3: ChaCha20-Poly1305, nonce `[u32 dir][u64 seq]`, header=AAD, jendela replay 1024-bit |
| `ssp_link.zig` | `Transport` vtable (§3.1 di bawah) + `Loopback` + `LossyLink` (seed+jam-virtual+`pump`) |
| `ssp_frag.zig` | Fragmentasi 8B-header di plaintext-AEAD, reassembly timeout-5s + cap-4MiB + dedup |
| `ssp_bootstrap.zig` | D2: format/parse `WRAITH CONNECT`, `readConnectLine` poll-deadline |
| `ssp_sync.zig` | Snapshot penuh: take→frames→frag→seal; recv→open→reassemble→split→restore |
| `ssp_diff.zig` | Diff VT ber-alamat+SGR bernomor-state + ack-kumulatif + resend; `Cx.resync` snapshot saat resize |
| `ssp_roam.zig` | `PeerTracker` (adopt/refresh/roam/stale/suspect; pindah hanya via paket-terotentikasi-lebih-baru) |
| `ssp_predict.zig` | D10: mode adaptive/30ms-EWMA, predict-1-codepoint, hold, confirm/cancel (rendering `[~]`) |
| `ssp_ext.zig` | `ImageChunk` reassembly + `TelemetryLog` berurutan via `sendFrame` |
| `ssp_fuzz.zig` | 1M input seed + 250K reassembly + 250K AEAD tanpa crash/hang/OOM |

### 6.1 Antarmuka `Transport` (seperti dirancang P0.6)

```zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, datagram: []const u8) SendError!void,
        recv: *const fn (ptr: *anyopaque, buf: []u8, timeout_ns: u64) RecvError![]u8,
        maxDatagramSize: *const fn (ptr: *anyopaque) usize,
    };
    ...
};
```

**Invariant:** datagram (pesan utuh), bukan stream. Fragmentasi/reassembly milik
lapisan SSP (P4.2), bukan transport. `recv` tidak pernah menggemakan kiriman
sendiri (hanya forward inner); delay butuh `pump()` eksplisit setelah `advance()`.

### 6.2 `LossyLink` — simulator lossy deterministik (test-only, metode AC2.5)

Membungkus `Transport`, PRNG ber-seed per arah, jam virtual (`now_ns` manual —
tanpa `sleep` nyata). Config: `loss`, `duplicate`, `delay_ns` +
`delay_jitter_ns`, `reorder`, `max_queue`. Profil AC2.5: loss 10/20/30% +
delay 5 ms + jitter 20 ms + dup/reorder 5%, 20 seed.

**Deviasi dari rencana P0.6:** implementasi tinggal di `src/daemon/`
(`ssp_link.zig`), bukan `src/remote/` yang tak pernah dibuat — modul daemon
adalah konvensi yang mapan. Tidak ada `UdpTransport` produksi terpisah:
sisi-server memakai socket UDP mentah di aksi `+remote-server`; `localAddress`
tidak dibutuhkan (roaming via `PeerTracker`, bukan alamat transport).

## 7. Aturan kontribusi lintas-fase (pelajaran yang mengikat)

- Daemon libs tidak membaca global: `Environ`/`io` dioper masuk (pola `src/os/file.zig:85`).
- `decodeAlloc` zero-copy: buffer hidup bersama pesan (`InMessage`).
- Test PTY/socket yang menggantung via run-step: jalankan binary langsung + timeout.
- Enum publik yang sinkron ke C (`apprt Action.Key` ↔ `ghostty.h`): **append-only**,
  di ujung, di kedua sisi (test paritas `checkGhosttyHEnum`).
- `fchmod` pada socket = no-op diam-diam; selalu `chmod` by path.
- procfs lapor `st_size == 0`: baca dengan buffer-tetap, bukan alokasi-berdasar-ukuran.
- Versi binary = git-HEAD (kode uncommitted tak mengubah label).
