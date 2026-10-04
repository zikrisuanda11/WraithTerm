# WraithTerm — PROTOCOL

Spesifikasi protokol pesan WraithTerm. Dua transport memakai **model pesan yang sama**
(§5 prinsip): IPC lokal (Unix socket, saat client attach ke daemon) dan SSP (Shm-less
State Protocol, UDP untuk remote). Hanya pembungkus transport yang berbeda.

Dasar: D3 (kripto), D9 (format), D10 (predictive echo). Versi dokumen: 1.

## 1. Prinsip

- Biner, **little-endian**, tanpa library serialisasi eksternal.
- Semua pesan berversi dan berbatas ukuran. **Parser wajib menolak, bukan crash.**
- Semuaisasi integer unsigned kecuali disebut lain. String = UTF-8 tanpa NUL, panjang eksplisit.
- Tidak ada eksekusi dari data jaringan (NFR §7). Tidak ada `exec`, `system`, atau pemuatan library dari isi pesan.

## 2. Framing (IPC lokal)

Setiap pesan pada Unix socket:

```
+0  u32  length            // jumlah byte setelah field ini (protocol_version..payload)
+4  u8   protocol_version  // = 1
+5  u8   msg_type          // lihat §3
+6  ...  payload           // msg_type-specific
```

- `length` = `1 + 1 + len(payload)` (tidak termasuk dirinya sendiri; minimum 2).
- Batas: `length` ≤ 1 MiB (D9). Lebih besar → `Error{code=TooLarge}`, tutup koneksi.
- `protocol_version` ≠ 1 → `Error{code=BadVersion}`, tutup koneksi.
- `msg_type` tak dikenal → `Error{code=UnknownMessage}`, tutup koneksi.
- Pembacaan: baca 4 byte header, validasi `length`, baca `length` byte, dispatch. `length` di bawah minimum atau di atas maksimum ditolak sebelum alokasi penuh.

## 3. Tipe pesan (`msg_type`)

| Nilai | Nama | Arah | Ringkas |
|---|---|---|---|
| 0x01 | `Hello` | C→S, S→C | Pembuka + negosiasi versi/kapabilitas |
| 0x02 | `Snapshot` | S→C | Layar penuh + metadata + scrollback chunked |
| 0x03 | `Diff` | S→C | Perubahan layar sejak state terakhir |
| 0x04 | `Input` | C→S | Byte input / event |
| 0x05 | `Resize` | C→S, S→C | Dimensi grid + piksel sel |
| 0x06 | `Control` | dua arah | Perintah kontrol (attach/detach/ambil-alih/kill) |
| 0x07 | `Detached` | S→C | Client dilepas (mis. diambil alih) |
| 0x08 | `Telemetry` | S→C (remote) | Event harness omp |
| 0x09 | `ImageChunk` | C→S (remote) | Gambar chunked untuk paste remote |
| 0x0A | `Ack` | dua arah | Konfirmasi state/seq |
| 0x7F | `Error` | dua arah | Kesalahan; lihat §4.12 |

## 4. Layout payload

### 4.1 `Hello` (0x01)
```
u16  protocol_version_min
u16  protocol_version_max
u16  capabilities        // bitmask, §5
u8   role                // 0=client, 1=daemon/server
u16  id_len
u8   id[id_len]          // session ID (8 hex) atau kosong untuk daemon
```
Server membalas `Hello` dengan versi terpilih (`protocol_version_max` = 1) + kapabilitas final. Inkonsistensi kapabilitas → `Error`.

### 4.2 `Snapshot` (0x02)
Mengirim **satu state layar konsisten**. Bila scrollback melebihi payload, dikirim sebagai beberapa `Snapshot` ber-`chunk_index` (D4).
```
u32  state_id            // monotonik; dipakai untuk Ack/Diff (§6)
u16  cols
u16  rows
u16  cursor_x
u16  cursor_y
u8   flags               // bit0=alternate_screen, bit1=has_scrollback, bit2=more_chunks
u8   cursor_style
u16  chunk_index
u16  chunk_count
u32  payload_len         // baris/glyph terenkode (termios serialisasi internal, §7)
u8   payload[payload_len]
```
Serialisasi grid memakai format snapshot internal Ghostty (`src/terminal/snapshot/`) bila self-describing; bila tidak, encoder/decoder kustom didokumentasikan di `ARCHITECTURE.md` saat P1.5. Yang penting: round-trip **identik** (AC1.2), dan state_id naik monotonik.

### 4.3 `Diff` (0x03)
Perubahan terhadap `state_id` referensi (SSP; di lokal opsional).
```
u32  base_state_id       // state yang diasumsikan dimiliki client
u32  state_id            // state setelah diff diterapkan
repeat span_count:
  u16 start_x
  u16 start_y
  u16 cell_count
  u32 glyphs_len
  u8  glyphs[glyphs_len]  // UTF-8, cell_count unit
  u32 style_data_len
  u8  style_data[style_data_len]
(Koreksi P1.2: `glyphs_len u32` ditambahkan — tanpa panjang eksplisit,
batas antara `glyphs` dan `style_data` tak dapat ditentukan saat decode.)
Ack berbasis **nomor state**, bukan byte (D9, AC2.4). Client yang tak memiliki `base_state_id` mengabaikan diff dan meminta `Snapshot` baru.

### 4.4 `Input` (0x04)
```
u8   kind                // 0=key, 1=text, 2=mouse, 3=paste, 4=focus
u32  len
u8   data[len]           // byte yang sudah ditranskode oleh client (PTY-ready)
```
`data` = byte yang sudah melalui encoder Ghostty (mis. `input.encodeKey`) sehingga daemon tinggal menulis ke PTY master. Ini menjaga logika keybinding di lapisan client, konsisten dengan arsitektur §5 (daemon = pemilik PTY, GUI = input).

### 4.5 `Resize` (0x05)
```
u16  cols
u16  rows
u16  cell_width_px
u16  cell_height_px
u8   flags               // bit0=cell_size_valid
```

### 4.6 `Control` (0x06)
```
u8   command
```
| Nilai | Perintah | Payload tambahan |
|---|---|---|
| 0x01 | RequestSnapshot | — |
| 0x02 | TakeOver | — (attach baru mengambil alih; D8) |
| 0x03 | Detach | — |
| 0x04 | KillSession | — |
| 0x05 | ListSessions | — |
| 0x06 | ExitWhenEmpty | `u8 on` |

### 4.7 `Detached` (0x07)
```
u8   reason              // 0=taken_over, 1=server_shutdown, 2=idle_timeout
```
Dikirim ke client yang kalah saat `TakeOver` (D8/AC1.4).

### 4.8 `Telemetry` (0x08) — remote (D6/P4.8)
```
u16  event_len
u8   event[event_len]    // JSON lines objek event harness (skema D6), ≤ 4 KiB
u32  origin_session_id   // ID session asal di host remote
```

### 4.9 `ImageChunk` (0x09) — remote (D1/P4.8)
```
u16  image_id
u16  chunk_index
u16  chunk_count
u8   mime_tag            // 0=png, 1=jpeg
u32  data_len
u8   data[data_len]
```
Host remote merakit, menulis ke direktori paste miliknya, mem-paste **path remote** ke PTY (bracketed paste). Klien memverifikasi hash akhir via `Control`/`Ack` ekstensi.

### 4.10 `Ack` (0x0A)
```
u32  state_id            // state yang dikonfirmasi diterima
u16  seq_lo              // opsional: ack paket SSP
u16  flags
```

### 4.11 `Error` (0x7F)
```
u8   code                // §4.12
u16  message_len
u8   message[message_len] // UTF-8, untuk log/manusia; JANGAN memuat data layar/input/kunci
```

### 4.12 Kode error
| Kode | Nama |
|---|---|
| 0x01 | BadVersion |
| 0x02 | UnknownMessage |
| 0x03 | Malformed |
| 0x04 | TooLarge |
| 0x05 | Unauthorized |
| 0x06 | NoSuchSession |
| 0x07 | Busy |
| 0x08 | Replay |
| 0x09 | Timeout |

## 5. Kapabilitas (bitmask `Hello.capabilities`)
| Bit | Kapabilitas |
|---|---|
| 0x0001 | image_paste |
| 0x0002 | telemetry |
| 0x0004 | predictive_echo |
| 0x0008 | scrollback_restore |
| 0x0010 | roaming |
| 0x0020 | clipboard_kitty |

Tidak ada fitur wajib yang bergantung pada bit opsional; client dan server bernegosiasi irisan.

## 6. Handshake & state machine

### 6.1 IPC lokal (Unix socket)
```
client                         daemon
  |-- Hello(role=client) ------->|
  |<------------- Hello(role=daemon)
  |-- Control(ListSessions) ---->|   (opsional, untuk CLI)
  |-- Control(Attach?) --------->|
  |<------------- Snapshot ------|   state awal (state_id=S0)
  |<------------- Diff* ---------|   bila ada perubahan
  |-- Input -------------------->|
  |<------------- Diff ----------|
  |-- Ack(state_id) ------------>|
  ...
  |<------------- Detached ------|   bila client lain TakeOver
```
- Attach baru → daemon mengirim `Detached(taken_over)` ke client lama lalu `Snapshot` ke yang baru (AC1.4).
- Tidak ada `SIGHUP` ke child saat client lepas (AC1.1) — daemon mempertahankan PTY.

### 6.2 SSP remote (bootstrap D2)
```
klien                              server (wraith --remote-server)
  |-- ssh user@host --------------->|  (jalankan server)
  |<-- "WRAITH CONNECT <port> <key>|  satu baris di stdout
  |-- UDP: paket#0 (AEAD) -------->|  handshake UDP pertama (kunci dari key)
  |<-- UDP: paket#0 (AEAD) --------|
  |   ... SSH diputus setelah UDP sukses ...
```
- Server menutup diri bila tak ada klien terotentikasi dalam **60 detik** pertama, atau tak ada paket sama sekali dalam **7 hari** (dapat dikonfigurasi; D2).
- `key` = 32 byte CSPRNG. Hidup hanya selama session; tidak pernah ditulis ke disk/log (D2/NFR).

## 7. Kripto & anti-replay (SSP, D3)

- AEAD: `ChaCha20-Poly1305`. Kunci = 32 byte dari bootstrap.
- **Nonce 12 byte** = `[4 byte: 0x00000000 (C→S) atau 0x00000001 (S→C)][8 byte: counter seq little-endian]`. Counter naik monotonik per arah; tidak pernah dipakai ulang pada kunci yang sama.
- **AAD** = header paket (seq, flags) — mencegah pergeseran header tanpa deteksi.
- **Replay window**: jendela geser 1024 paket per arah; tolak seq di luar jendela atau yang sudah terlihat.
- Paket gagal otentikasi **dibuang diam-diam** (tanpa balasan), mencegah oracle.
- Paket SSP ≤ 1200 byte. Payload lebih besar → fragmentasi (`chunk_index`/`chunk_count` di dalam AEAD), reassembly timeout 5 detik, batas total 4 MiB (D9). Melebihi batas → buang fragmen (bukan crash).
- Tanpa key rotation di v1; session baru = kunci baru. Tidak memakai Noise di v1.

## 8. Roaming (AC2.4)
- Alamat peer diperbarui **hanya** dari paket terotentikasi AEAD dengan seq lebih tinggi. Paket lama/replay dari alamat lain tidak boleh membajak.
- Reconnect pasca-sleep: client mengirim paket terotentikasi seq tertinggi yang ia miliki; server melanjutkan diff dari state terkonfirmasi.

## 9. Predictive echo (D10)
- Mode `wraith-predictive-echo = adaptive | always | never` (default adaptive: aktif bila smoothed RTT > 30 ms).
- Karakter cetak, layar normal saja (bukan alt screen). Ditampilkan underline/dim. Dikonfirmasi saat state server mencapai epoch prediksi; dibatalkan & dihapus bila tidak cocok.
- Dimatikan sementara setelah Enter/kontrol, saat alt-screen, dan saat echo-off (password).

## 10. Model ancaman

**Dilindungi:** eavesdropping pasif pada jalur UDP (AEAD), tamper/replay paket, injeksi pengirim palsu (kunci hanya dari bootstrap SSH), pembajakan roaming oleh alamat lain (harus paket terotentikasi seq lebih tinggi).

**Tidak dilindungi / di luar cakupan v1:** kompromi host endpoint (client atau server) — kunci ada di memori proses; MITM pada sesi SSH bootstrap (dipercaya); serangan DoS volume pada port UDP (tidak ada rate-limit anti-DDoS di v1); kebocoran lewat side-channel timing (tidak dimodelkan); autentikasi pengguna saat attach ke daemon lokal (diproteksi hanya oleh permission socket `0600`/direktori `0700`, D8).

**Data sensitif yang TIDAK boleh di-log:** isi layar, byte input, kunci sesi (NFR §7).

## 11. Catatan pemetaan ke `termio.Message`
Pesan lokal untuk kebutuhan internal (write/resize/focused/clear_screen/…) sudah ada di
`src/termio/message.zig`. Yang tumpang tindih dipetakan: `Resize`↔`Message.resize`,
`Input`↔`Message.write_*`, `Diff`/`Snapshot` = pembungkus state_id untuk serialisasi
`Terminal`. PROTOCOL ini menambah bingkai + state_id + negosiasi yang tidak ada di
`Message` internal.
