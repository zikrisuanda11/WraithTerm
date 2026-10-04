# WraithTerm — RECON

Hasil recon P0.2: cek lingkungan (§2.5) + peta modul `src/` yang sebenarnya + koreksi peta §5 WRAITH_SPEC.
Semua klaim di bawah memiliki bukti file:line. Yang belum terverifikasi ditandai `[UNVERIFIED]`.

## 1. Lingkungan (per 2026-10-04, host kerja)

| Properti | Nilai | Catatan |
|---|---|---|
| OS/Kernel | Linux 7.1.12-100.fc43.x86_64 (Fedora 43) | x86_64 |
| `uname -a` | `Linux fedora ... x86_64 GNU/Linux` | |
| **Zig** | **0.16.0** (user-local `~/.local/opt/zig/zig`) | BUKAN di PATH sistem. `build.zig.zon` `minimum_zig_version = "0.16.0"`. Wajib `PATH="$HOME/.local/opt/zig:$PATH"`. Lihat ADR-001. |
| uid | 1000 (bukan root) | `tc netem` **tidak boleh** dipakai → pakai `LossyLink` (P4.2). |
| Display | `DISPLAY=:0`, `WAYLAND_DISPLAY=wayland-0` | Ada X11 + Wayland. GUI/GTK mungkin bisa dibangun; verifikasi runtime tetap `[~]` bila tak bisa diverifikasi agent. |
| `tc` | `/usr/bin/tc` ada, tapi butuh root | Tidak dipakai (§2.5). |
| `bun` | 1.3.14 (`~/.bun/bin/bun`) | Untuk bridge `.ts` (P2.5) & recon omp. |
| `omp` | **omp/18.4.0** (`~/.bun/bin/omp`) | RIIL terpasang → P2.1 pakai recon nyata, bukan fixture sintetis. |
| GTK4 | 4.20.4 (`pkg-config --modversion gtk4`) | Backend Linux `apprt` = GTK4. |
| Wayland client | 1.25.0 | |
| X11 | ada | |
| CPU | 8 core | |
| `nix` | tidak ada | Jangan pakai jalur Nix. |
| `fd` | ada | Helper. |
| Remote git | `origin`=zikrisuanda11/WraithTerm, `upstream`=ghostty-org/ghostty (read-only ref, D7) | |
| Git HEAD basis | `f96c9711b` ("Update VOUCHED list (#14528)") | Detail di UPSTREAM.md (P0.5). |

**Verifikasi tidak mungkin di sini (→ `[~]` bila menyentuh):** kode macOS/Swift, render GUI nyata, notifikasi OS, clipboard image runtime (walau ada display, sesi interaktif tidak dapat diverifikasi agent). Logika murni tetap diuji unit test.

## 2. Peta modul `src/` yang sebenarnya

### 2.1 Termio / PTY (kepemilikan PTY — titik paling berisiko)

| Path | Peran | Simbol kunci (file:line) |
|---|---|---|
| `src/termio.zig` | Facade re-export `Backend/Mailbox/Message/Exec/Termio/Thread/Options/StreamHandler` | `src/termio.zig:21-33` |
| `src/termio/backend.zig` | **Interface pemisah backend↔state** | `Kind = enum { exec }`:14; `Backend = union(Kind)`:24; `Config = union`:; `ThreadData = union(Kind)`:116 |
| `src/termio/Termio.zig` | Pemilik terminal-state bersama | `Termio{backend, terminal:Terminal, renderer_state, mailbox, terminal_stream}`:43; `processOutput`:`:675`; `threadEnter`:~347; `init`:~326 |
| `src/termio/Thread.zig` | Thread IO writer (xev loop + drain mailbox) | `threadMain`:136; `drainMailbox`:290 |
| `src/termio/Exec.zig` (~2305 baris) | **Backend exec: pemilik Subprocess + PTY + pipeline baca** | `Exec{subprocess:Subprocess}`; `threadEnter`:86; `queueWrite`:403; `ThreadData`:493; `Subprocess`:583 (`pty:?Pty`:592); spawn via `Command.start()`:~1078; `Subprocess.stop()`:1110 → `killpg(SIGHUP)`:1171-1210; `ReadThread/Pipeline`:1264+ |
| `src/termio/mailbox.zig` | Transport pesan app→io thread | `Mailbox.spsc{queue:*BlockingQueue(Message,64), wakeup:xev.Async}`:18; `initSPSC`; `send`; `notify` |
| `src/termio/message.zig` | Varian `Message` (union ~40 byte) | write_small/stable/alloc, resize, focused, clear_screen, scroll_viewport, change_config, color_scheme_report, visibility_report, size_report, kitty_clipboard_grant_* |
| `src/termio/Options.zig` | Wiring init (size, config, backend, mailbox, renderer_state) | |
| `src/termio/stream_handler.zig` | VT stream callbacks → Terminal | ~77 KB |
| `src/pty.zig` | `Pty = PosixPty` (master/slave fd) | `open(size)!Pty`:131 (`c.openpty`:140-184); `childPreExec` (setsid+TIOCSCTTY):230-263 |
| `src/pty.c` | Shim C openpty/ioctl/termios | `<pty.h>` (Linux), `<util.h>` (macOS) |
| `src/Command.zig` | Spawner fork()+execve | `Command.start()`:163; `fork()`:296; sengaja bukan posix_spawn (:12-15) |

**Temuan kritis:**
- PTY master fd dimiliki `termio.Exec.Subprocess.pty` (`Exec.zig:592`); dibuat `Subprocess.start()`→`Pty.open` (`Exec.zig:905`). Slave ditutup di parent pasca-spawn (`Exec.zig:928`); master di-alias ke `read_thread_fd` (`Exec.zig:154`) + `xev.Stream` writer (`Exec.zig:130`). **Lifetime sepenuhnya in-process, CLOEXEC.**
- 3 thread per surface: 1 io-loop (xev, `Thread.zig:136`) + 2 thread pipeline baca (`Exec.zig:141-144`, gather+parse). Tidak ada global thread pool.
- **SIGHUP dikirim ke process group saat `threadExit`→`Subprocess.stop()`** (`Exec.zig:1110,1171-1210`). Ini yang harus dicegah saat client lepas (AC1.1): daemon tidak boleh memanggil `stop()` pada detach.
- **Tidak ada** dukungan daemon/socket/reconnect/multiprocess di `src/termio/*` (grep bersih). Ini greenfield.
- Hook untuk daemon: ganti `Backend`/`ThreadData` (slot varian baru) + `Mailbox` SPSC (transport bisa diganti) + serialisasi `Message` & byte `processOutput`.

### 2.2 Terminal state headless (`src/terminal/`)

| Path | Peran | Simbol kunci |
|---|---|---|
| `src/terminal/Terminal.zig` | State emulator utama | `Terminal`:2; `Options{cols,rows,max_scrollback_bytes=10_000,max_scrollback_lines,colors,...}`:273; `init(io_impl, alloc, opts)!Terminal`:318; `deinit`:363; `plainString`:4917 |
| `src/terminal/Screen.zig` | Screen aktif (cursor, selection, dump) | `Cursor`:132; `Dirty`:90; `dumpString*`:3666+ |
| `src/terminal/ScreenSet.zig` | Primary/alternate | `active_key`/`active`:14-110; `switchTo` |
| `src/terminal/PageList.zig` | Deque page scrollback + pin/dirty | `getCell(pt)?Cell`:5867; `pin`; `getTopLeft/BottomRight`:6752/6787; `isDirty`:6990 |
| `src/terminal/page.zig` | Grid kontigu | `Page.dirty`:184; `Row`:2008 (dirty bit:2072); `Cell` packed u64:2137 |
| `src/terminal/stream.zig` | Parser VT generik (SIMD) | `Stream.nextSlice/next`:1-123 |
| `src/terminal/stream_terminal.zig` | Stream terikat Terminal | `Handler.init(&term)`:445 |
| `src/terminal/snapshot/snapshot.zig` | Serialisasi/restore layar | `encode`:44; `decodeExact`:619/645; `Decoded.toOwned()`:179 |
| `src/terminal/c/terminal.zig` | Wrapper ABI C | `TerminalWrapper{terminal,stream,io}`:72-78; `new_`:893; `vt_write`:928 |

**Cara pakai headless (jalur Zig internal):**
```zig
var term = try terminal.Terminal.init(io, alloc, .{ .cols=80, .rows=24 });
var stream = terminal.TerminalStream.init(.{ .allocator=alloc, .handler=.init(&term) });
stream.nextSlice(bytes);          // umpan byte PTY
_ = term.screens.active;          // baca grid (PageList.getCell / Screen.dumpString)
```

**Cara pakai ABI C `libghostty-vt`** (`src/lib_vt.zig` re-export: `Terminal`:94, `TerminalStream`:95, `Stream`:96, `TinyIo`:51):
- `ghostty_terminal_new(alloc,&term,cols,rows)` `include/ghostty/vt/terminal.h:2596`
- `ghostty_terminal_vt_write(term,ptr,len)` `:2707` (partial-sequence-safe)
- `ghostty_terminal_get/_multi` `:2924/2955`; `ghostty_terminal_grid_ref` `:2987`
- `ghostty_terminal_resize` `:2654`; `ghostty_terminal_free` `:2611`
- Snapshot: `ghostty_snapshot_encode* / ghostty_decoder_*` (`c/snapshot.zig`).

**Penilaian headless:** ABI C 9/10 (self-contained: ctor hanya butuh allocator+cols/rows, tanpa PTY/GUI/render; efek callbacks untuk writeback judul/bell/clipboard; grid_ref + render_state dirty-aware; snapshot untuk restore). Modul Zig internal 8/10 (lebih kuat: akses pin/page/search, tapi API tak stabil & butuh wiring `std.Io` + build option sendiri). **Keputusan P0.3** (dicatat di DECISIONS.md saat dikerjakan): daemon Zig → pakai modul `src/terminal/` internal langsung bila butuh pin-level, atau ABI C bila ingin batas ABI stabil. Prototipe headless wajib di P0.3.

### 2.3 CLI / App / Surface (titik injeksi aksi baru)

| Path | Peran | Simbol kunci |
|---|---|---|
| `src/cli/ghostty.zig` | **Registry `Action` enum + dispatch** | `Action = enum {version,help,@"list-fonts",...}`:31-60; `detectSpecialCase`:~62; `runMain` arm; `options()` arm |
| `src/cli/action.zig` | Detektor `+action` generik | `detectIter/detectArgs`:1-78 |
| `src/cli/args.zig` | Parser flag berbasis field struct | `parse(T,...)`:52-200; `argsIterator`:1361 |
| `src/global.zig` | Argv global + state action | panggil deteksi ~150-170 |
| `src/main_ghostty.zig` | Dispatch exe + **fast-path action headless** | init → action?run+exit → `App.create` → `apprt.run()`:18-90 |
| `src/App.zig` | Wrapper core atas runtime apprt | `surfaces: ArrayListUnmanaged(*apprt.Surface)`:1-20 |
| `src/Surface.zig` | Pemilik per-tab: Termio (terminal+pty) + Renderer | `Surface.init(alloc,config,app,rt_app,rt_surface)`:475; `io:Termio`:134; `io_thread`:135; `startClipboardRequest`:6174; `completeClipboardRequest`:5973; `performBindingAction`:4898 |
| `src/apprt.zig` | Alias `App`/`Surface` per runtime (comptime) | `runtime.App`/`runtime.Surface`:43-53 |
| `src/apprt/runtime.zig` | Enum runtime | `Runtime{none,gtk}`:4-22, `default()`=gtk di Linux |
| `src/apprt/none.zig` | Runtime headless stub | IPC return false:1-15 |

**Cara menambah aksi CLI baru** (mis. `+daemon`): buat `src/cli/daemon.zig` (`pub const Options` + `pub fn run(alloc)!u8`), lalu edit `src/cli/ghostty.zig`: import + varian enum + arm `runMain` + arm `options()`. `helpgen` (`build.zig:211`) + `src/helpgen.zig:73-118` auto-generate help. **Catatan:** `--daemon` double-dash adalah **config key**, bukan Action; aksi pakai prefix `+` (`+daemon`). Peta §5 menyebut `--daemon`/`--attach` — koreksi: implementasi sebagai `+daemon`, `+attach`, dst. (atau flag config bila sesuai), ikuti pola aksi `+`.

**Mode headless sudah ada:** `main_ghostty.zig:~45-55` menjalankan `global.action()` sebelum `App.create`; `+show-config` dll tak butuh display. Jalur ini yang dipakai CLI WraithTerm (daemon/attach/list) — tidak memicu GUI.

### 2.4 apprt (GTK), input, renderer, config

| Path | Peran | Simbol kunci |
|---|---|---|
| `src/apprt/gtk/class/application.zig` | Lifecycle GTK app, action window/tab | `newWindow`:2596; `newTab`:2566; `newSplit`:2544 |
| `src/apprt/gtk/class/window.zig` | Tab + paste action | `newTabPage`:438; `actionPaste`:2180; `addToast` |
| `src/apprt/gtk/class/surface.zig` | Widget `GhosttySurface:adw.Bin` (key/IME/clipboard/render) | `Clipboard.request`:4091 (gate teks:4112 `containGtype(string)==0 → .unavailable`); `keyEvent`:1257 |
| `src/apprt/gtk/class/*_overlay.zig` | **Preseden widget HUD** | `search_overlay`/`resize_overlay`/`key_state_overlay` |
| `src/apprt/gtk/class/render_surface.zig` | `GdkTexture` untuk tampilan | `rebuildTexture`:304 |
| `macos/Sources/Ghostty/*.swift` | UI macOS (Swift, **bukan** di `src/`) | `Ghostty.App.swift` `readClipboard`:298, `completeClipboardRequest`:427; `Surface View/SurfaceView*.swift`; `NSPasteboard+Extension.swift` |
| `src/input/paste.zig` | Framing bracketed paste | prefix `200~`:5; suffix `201~`:6; `Options.fromTerminal`:17; `encode`:42; `isSafe` |
| `src/terminal/paste.zig` | **Funnel tunggal clipboard→pty** | `Request{source, contents:Contents{memory,reader}}`:1-23; mode 5522 vs 2004 |
| `src/config/Config.zig` | **Deklarasi semua config key** (~11k baris) | klaster clipboard: `clipboard-paste-bracketed-safe`=2502; `image-storage-limit`=2522 |
| `src/renderer.zig` | Pilih `GenericRenderer(GraphicsAPI)` | Metal (macOS) / OpenGL (lain) |
| `src/renderer/Overlay.zig` | **HUD CPU (z2d) backend-agnostik** | `pendingImage` komposit di atas output terminal |

**Cara menambah config key `wraith-image-paste`:** tambah field `pub` berdoc-comment di klaster `src/config/Config.zig` (~2502). Parsing/`+show-config`/`+explain-config`/reload bekerja generik via refleksi comptime. Tipe enum/limit perlu `pub const` + `parseCLI`/`formatEntry` (salin tetangga). **Belum ada key `wraith*` di repo** (`grep -c wraith src/config/Config.zig` = 0).

**Hook clipboard gambar:** hari ini **tak ada** jalur gambar — GTK `Clipboard.request` hanya `readTextAsync` dan early-out non-teks (`surface.zig:4112-4120`); `src/terminal/clipboard.zig:254` eksplisit `!isTextMime("image/png")`. Namun funnel `src/terminal/paste.zig` **sudah** membawa `Contents` multi-mime, jadi bagian yang hilang hanya **supplier** apprt (baca image async) + **cabang konsumen** untuk data gambar. Titik hook HUD: `renderer/Overlay.zig` (portabel, backend-agnostik) atau overlay widget GTK/SwiftUI.

## 3. Koreksi peta §5 (PERKIRAAN → REALITA)

| Area di §5 | Realita |
|---|---|
| `src/main*.zig`, `src/cli/` aksi `--daemon`,`--attach`,... | Aksi CLI = varian di `src/cli/ghostty.zig` enum `Action` + `src/cli/<name>.zig`; prefix **`+`**, bukan `--`. `--daemon` adalah config key. |
| `src/termio/`, `src/pty*` | Benar. PTY dimiliki `termio/Exec.Subprocess.pty`; SIGHUP di `stop()`; ada pemisahan `backend.zig` (`Backend`/`ThreadData` union) yang bisa ditambah varian backend daemon. |
| `src/terminal/` | Benar; state headless murni (`Terminal`+`Stream`+`PageList`), snapshot encode/decode sudah ada. ABI C `libghostty-vt` tersedia & embeddable. |
| `src/daemon/` (baru) | Belum ada. Perlu: session manager, IPC server, pemilik PTY+Terminal (pindahan dari `Exec`/`Termio`). |
| `src/remote/` (baru) | Belum ada. |
| `src/harness/` (baru) | Belum ada. |
| `src/input/`, `src/apprt/*` clipboard/HUD | Benar; jalur paste = `src/terminal/paste.zig` funnel + `src/apprt/gtk/.../surface.zig` supplier (teks saja saat ini); HUD preseden di `renderer/Overlay.zig` & `apprt/gtk/class/*_overlay.zig`. |
| `docs/wraith/` (baru) | Sudah dibuat (PROGRESS, DECISIONS, RECON ini). |
| Runtime backends | Linux = **GTK saja** (+ none/embedded/browser per artifact). macOS UI di `macos/Sources/Ghostty/*.swift`, di luar `src/`. |

## 4. Dampak ke task berikutnya

- **P0.3** (evaluasi libghostty-vt headless): jalur C `ghostty_terminal_new`/`vt_write`/`get`/`grid_ref` sudah jelas; prototipe bisa berupa test Zig yang memakai `terminal.Terminal` + `TerminalStream` internal **atau** ABI C. `TinyIo` (`lib_vt.zig:51`) menyediakan `std.Io` headless.
- **P0.4** (PROTOCOL.md): model pesan D9 dipetakan ke `termio.Message` yang ada (write/resize/focused/... di `message.zig`) untuk area tumpang tindih.
- **P0.5** (baseline): jalankan `zig build` (butuh deps dari `deps.files.ghostty.org`) + `zig build test`; catat hash upstream `f96c9711b`.
- **P1.4** (daemon memiliki PTY): titik kritis = memindahkan `termio.Exec.Subprocess`+`Pty`+pipeline baca ke daemon, dan **memastikan detach client tidak memanggil `Subprocess.stop()`** (yang mengirim SIGHUP).
