# WraithTerm — UPSTREAM

Basis upstream Ghostty untuk fork WraithTerm (D7). Agent **tidak** fetch-merge dari
upstream; pemilik proyek menangani sinkronisasi sendiri setelah pekerjaan selesai.

## Basis fork

| Properti | Nilai |
|---|---|
| Remote | `upstream` = `https://github.com/ghostty-org/ghostty.git` (read-only, tidak di-fetch-merge; D7) |
| Commit basis (`main` fork) | `f96c9711b9f72ecf75e0fd50f3434529b4dea5b6` |
| Tanggal commit | 2026-10-04 01:09:40 +0000 |
| Subjek | `Update VOUCHED list (#14528)` |
| Versi (build.zig.zon) | `1.3.2-dev` |
| `minimum_zig_version` | `0.16.0` |
| Toolchain dipakai | Zig 0.16.0 (user-local; ADR-001) |
| Jumlah commit di `main` | 18053 |

## Catatan

- `origin` = fork `zikrisuanda11/WraithTerm` (tempat branch fase & `wraith/dev` di-push bila kredensial tersedia).
- Semua branch WraithTerm bercabang dari `main` fork di commit basis di atas.
- Identitas versi runtime terverifikasi: `zig-out/bin/ghostty --version` → `Ghostty 1.3.2-wraith-phase0-recon+<hash>`.
- Sinkronisasi upstream di luar cakupan agent (D7). Saat pemilik proyek melakukan merge, commit basis ini adalah titik divergensi.
