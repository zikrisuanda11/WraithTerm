# WraithTerm — ARCHITECTURE

Dokumen ini tumbuh bertahap. Saat ini memuat desain antarmuka transport yang dapat
diganti + simulator `LossyLink` (P0.6). Bagian lain (session manager, IPC, SSP)
ditambahkan sesuai task.

## 1. Prinsip arsitektur (ringkas, dari §5)

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

## 2. Kepemilikan PTY & state (temuan P0.2)

- PTY master dimiliki `termio.Exec.Subprocess.pty` (`src/termio/Exec.zig:592`). **SIGHUP ke
  process group dikirim di `Subprocess.stop()`** (`Exec.zig:1110-1210`), dipanggil saat
  `threadExit`. Untuk daemon, detach client **tidak boleh** memanggil `stop()` (AC1.1).
- State layar headless memakai engine yang sama dengan `libghostty-vt` (ADR-004), diakses
  via modul Zig (`Terminal`/`TerminalStream` re-export `src/lib_vt.zig`). `Terminal` wajib
  beralamat stabil (heap) selama `TerminalStream` hidup.

## 3. Transport yang dapat diganti (P0.6)

Semua konsumen pesan (daemon, client, SSP) bekerja di atas satu antarmuka transport.
Tujuannya: unit test boleh menukar transport nyata dengan simulator lossy **tanpa
mengubah kode pemanggil**, dan `LossyLink` menjadi metode uji resmi AC2.5 (§2.5).

### 3.1 Antarmuka `Transport` (desain; Zig)

```zig
/// A datagram-oriented, unreliable transport. Delivery is not guaranteed;
/// ordering is not guaranteed. Implementations are NOT thread-safe: the
/// owner serializes calls.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Send one datagram. Returns an error only for local failures
        /// (buffer full, peer gone); it never indicates remote receipt.
        send: *const fn (ptr: *anyopaque, datagram: []const u8) SendError!void,

        /// Receive into `buf` (>= max_datagram_size). Returns the datagram
        /// slice or error.Timeout. The returned slice aliases `buf` and is
        /// valid until the next recv.
        recv: *const fn (ptr: *anyopaque, buf: []u8, timeout_ns: u64) RecvError![]const u8,

        /// Largest datagram the link accepts, in bytes. The SSP layer sizes
        /// its fragmentation to this (<= 1200 per D9; LossyLink may shrink it).
        maxDatagramSize: *const fn (ptr: *anyopaque) usize,

        /// Local address of the endpoint, if meaningful (roaming AC2.4).
        localAddress: *const fn (ptr: *anyopaque, buf: []u8) ![]const u8,
    };

    pub fn send(self: Transport, datagram: []const u8) SendError!void { ... }
    pub fn recv(self: Transport, buf: []u8, timeout_ns: u64) RecvError![]const u8 { ... }
    pub fn maxDatagramSize(self: Transport) usize { ... }
};
```

**Invariant:** `Transport` adalah **datagram** (pesan utuh), bukan stream. Fragmentasi/
reassembly adalah tanggung jawab lapisan SSP di atasnya (P4.2), bukan transport.

### 3.2 Implementasi yang direncanakan

| Implementasi | Kapan | Catatan |
|---|---|---|
| `UdpTransport` | produksi SSP | `sendto`/`recvfrom`; mendukung roaming (baca alamat source) |
| `UnixSocketTransport` | IPC lokal | sebenarnya stream; dibungkus framing `PROTOCOL.md` §2 |
| `LossyLink` | **test** (AC2.5) | membungkus transport lain, menyuntik loss/delay/dup/reorder |
| `LoopbackTransport` | test | in-memory, tanpa syscall |

### 3.3 `LossyLink` — simulator lossy deterministik (test-only)

`LossyLink` membungkus `Transport` lain dan memakai **PRNG ber-seed** (deterministik):
hasil uji identik di setiap mesin. Parameter dari AC2.5.

```zig
pub const LossyLink = struct {
    inner: Transport,
    rng: std.Random.DefaultPrng,       // seed eksplisit, wajib
    cfg: Config,
    // Antrean paket tertunda (delay/reorder), diurutkan berdasarkan waktu kirim.
    queue: std.PriorityQueue(Delayed),

    pub const Config = struct {
        /// Probabilitas paket dijatuhkan, 0..1 (AC2.5: 0.10–0.30).
        loss: f32 = 0.0,
        /// Probabilitas paket digandakan, 0..1.
        duplicate: f32 = 0.0,
        /// Jitter/delay dasar per paket, ns. Delay = base + uniform(0, jitter).
        delay_ns: u64 = 0,
        delay_jitter_ns: u64 = 0,
        /// Probabilitas dua paket berurutan ditukar (reorder).
        reorder: f32 = 0.0,
        /// Batas antrean tertunda; melebihi = drop tertua (cegah OOM).
        max_queue: usize = 4096,
    };

    /// Kirim: terapkan loss -> duplicate -> delay/jitter -> reorder, lalu
    /// teruskan ke inner.send (bila tidak dijatuhkan). Deterministik via rng.
    pub fn send(self: *LossyLink, datagram: []const u8) SendError!void { ... }

    /// Terima: keluarkan paket tertunda yang jatuh tempo, dengan urutan yang
    /// sudah diacak, dari antrean; bila kosong, teruskan inner.recv.
    pub fn recv(self: *LossyLink, buf: []u8, timeout_ns: u64) RecvError![]const u8 { ... }

    pub const Config = struct { ... };
};
```

Aturan determinisme:
- Satu `rng` per arah (kirim/terima) supaya keputusan loss tidak bergantung urutan tak relevan.
- Waktu disuntik lewat **jam virtual** (`now_ns` monotonik) yang bisa dimajukan manual di test, sehingga `sleep` nyata tidak dibutuhkan → test cepat & stabil.
- `maxDatagramSize()` mengembalikan `inner.maxDatagramSize()` (tidak mengecilkan) kecuali test meminta sebaliknya.

### 3.4 Skenario uji resmi AC2.5

Test P4.5/P4.10 menjalankan loopback dua endpoint yang dihubungkan dua `LossyLink`
(satu per arah), lalu memverifikasi **layar akhir klien == layar akhir server** untuk:

| Parameter | Nilai |
|---|---|
| loss | 10%, 20%, 30% (tiga run terpisah) |
| delay_ns | 5 ms |
| delay_jitter_ns | 20 ms |
| duplicate | 5% |
| reorder | 5% |
| seed | tetap, mis. `0xWRAITH`… (20 seed berbeda di P4.5/P4.10) |

Karena AC2.5 meminta **hasil identik di 20 seed berbeda**, test mengiterasi seed dan
gagal bila ada satu seed menghasilkan layar berbeda. Seed dicatat di output agar bisa
direproduksi.

### 3.5 Di mana `LossyLink` tinggal

`src/remote/lossy.zig` (test-only; tidak di-embed ke build produksi). Antarmuka
`Transport` di `src/remote/transport.zig`. Build test menambahkannya sebagai
`test`-dependency sehingga tidak menambah ukuran binary rilis.

## 4. Peta modul target (dikoreksi P0.2)

| Area | Perubahan |
|---|---|
| `src/cli/` | Aksi `+daemon`, `+attach`, `+list-sessions`, `+kill`, `+remote`, `+remote-server`, `+list-harnesses`, `+install-omp-bridge`, `+uninstall-omp-bridge` (varian enum `Action` + file per aksi; prefix `+`) |
| `src/termio/`, `src/pty.zig` | Kepemilikan PTY dipindah ke daemon (jaga jalur non-daemon) |
| `src/terminal/` | Sudah headless (prototipe P0.3); tambah serialisasi snapshot/diff |
| `src/daemon/` (baru) | Session manager + IPC server |
| `src/remote/` (baru) | `transport.zig`, `lossy.zig` (test), SSP: kripto, diff, predictive echo |
| `src/harness/` (baru) | Detector, penerima event, parser; `omp/` = bridge `.ts` + installer |
| `src/input/`, `src/apprt/*` | Deteksi gambar clipboard; HUD native |
| `docs/wraith/` | Dokumentasi & state agent |
