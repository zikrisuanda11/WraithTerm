# WraithTerm — Panduan Pengguna (P5.2)

Semua perilaku Ghostty asli dipertahankan secara default; setiap fitur
WraithTerm opt-in via config `wraith-*` atau aksi CLI `+`. Butuh build
dari branch ini (`zig build`).

## Daemon + attach/detach (Pilar 1)

```sh
# Jalankan daemon (foreground). Tanpa flag ia melayani sampai dibunuh.
ghostty +daemon
ghostty +daemon --exit-when-empty   # keluar setelah 10 dtk tanpa session (D8)

# Daftar / bunuh session.
ghostty +list-sessions
ghostty +kill <8-hex-id>

# Otomatis: mulai daemon saat dibutuhkan (default off).
# config: wraith-daemon = auto
```

Satu client interaktif per session; attach baru mengambil alih (client
lama menerima `Detached(taken_over)`). Detach tidak membunuh child (AC1.1).

## Monitoring harness omp (Pilar 4)

```sh
# Pasang bridge event ke omp (idempoten; backup file asing).
ghostty +install-omp-bridge
ghostty +uninstall-omp-bridge

# Daftar harness: Tier 1 (event bridge) + Tier 2 (process tree).
ghostty +list-harnesses
ghostty +list-harnesses --json      # untuk HUD / tooling
```

Bridge menulis JSON-lines ke socket `0600` milik daemon; env
`WRAITH_HARNESS_SOCK`/`WRAITH_SESSION_ID` diinjeksikan ke setiap child.
State `awaiting_approval` memicu notifikasi OS (best-effort).
Aksi keybind: `toggle_harness_hud` (dialog GTK).

## Image paste (Pilar 3)

```sh
# config: wraith-image-paste = /path/ke/dir   # default: off
# config: wraith-image-paste = off
```

Gambar di clipboard ditempel sebagai **path absolut ter-quote**
(bracketed paste); teks biasa tidak berubah (AC3.3). File dikelola di
direktori tersebut: nama `paste-<ms>-<rand6>.png/.jpg`, `0600`,
prune TTL-24h + kuota-200MiB, tolak >25 MiB.

## Remote SSP (Pilar 2)

```sh
# Di server (via SSH atau langsung):
ghostty +remote-server              # cetak WRAITH CONNECT <port> <key>, tunggu UDP 60 dtk

# Di klien:
ghostty +remote user@host[:port]    # bootstrap SSH, lapor endpoint UDP
```

Keamanan (D3): ChaCha20-Poly1305, kunci 32 B per session dari
bootstrap, tanpa rotasi di v1. Roaming otomatis (pindah alamat ikut
paket terotentikasi terbaru). Predictive echo: lihat di bawah.

## Config keys (ringkas)

| Key | Nilai | Default |
|---|---|---|
| `wraith-daemon` | `off` \| `auto` | `off` |
| `wraith-image-paste` | `off` \| `<dir>` | `off` |
| `wraith-predictive-echo` | `adaptive` \| `always` \| `never` | `adaptive` |

`adaptive` memprediksi ketikan hanya bila smoothed RTT > 30 ms;
prediksi batal saat Enter/kontrol, alt-screen, atau echo-off.
