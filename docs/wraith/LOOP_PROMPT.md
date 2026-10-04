# WraithTerm — LOOP PROMPT (pola kerja berulang)

Prompt ini dipakai **setiap iterasi** oleh agent yang mengerjakan WraithTerm. Ringkas,
berulang, dan mengikat ke aturan spec. Untuk onboarding ke mesin baru, lihat
`NEXT_PROMPT.md` dulu.

---

## POLA LOOP (ulangi sampai semua task selesai)

```
SETUP (sekali per shell):
  cd /path/ke/WraithTerm
  source docs/wraith/build-env.sh

TIAP ITERASI:
  1. ORIENTASI
     - Baca docs/wraith/PROGRESS.md (task belum selesai paling awal + catatan).
     - Baca docs/wraith/DECISIONS.md (ADR relevan).
  2. PILIH
     - Ambil task `[ ]` atau `[~]` paling awal menurut urutan fase.
     - Nyatakan tujuannya 1 baris; jangan lompat fase, jangan kerjakan 2 fase sekaligus.
  3. KERJAKAN
     - Baca kode terkait dulu (RECON.md punya peta + file:line).
     - Tulis kode sesuai pola repo; jangan bikin konvensi kedua.
     - Build/test lokal sambil iterasi:
         zig build                          # cepat, cek compile
         zig build test -Dtest-filter=<x>   # test terarah (WAJIB pilih yang sempit)
  4. VERIFIKASI (bukti, bukan klaim)
     - Jalankan test yang menyentuh perubahan; tempel hasil nyata (exit code, jumlah lulus).
     - Fitur/API: buktikan lewat skrip/smoke, bukan hanya "compile sukses".
     - GUI tak bisa diverifikasi → tandai [~] (ADR-002).
  5. CATAT + COMMIT
     - Update docs/wraith/PROGRESS.md: checklist + 1-2 baris catatan berisi bukti.
     - Blockers hardware → docs/wraith/BLOCKERS.md dengan tanda [BLOCKED].
     - git add <file spesifik> && git commit  (conventional commits; JANGAN force-push).
  6. LANJUT
     - Langsung ke iterasi berikutnya bila ada task berikutnya yang belum selesai.
     - Berhenti HANYA bila: semua task fase selesai (lanjut fase), atau diminta berhenti.

SAAT BERHENTI / PINDAH MESIN:
  - Commit semua perubahan (working tree bersih).
  - git push origin <branch>   (branch: wraith/phase0-recon saat ini)
  - Pastikan PROGRESS.md jujur soal [~]/[ ] yang belum tuntas.
```

---

## Checklist mutlak tiap iterasi

- [ ] `source docs/wraith/build-env.sh` sudah dijalankan di shell ini.
- [ ] Tidak pakai `sudo`, tidak ubah konfigurasi sistem, tidak auto-install paket sistem.
- [ ] Tidak fetch-merge dari `upstream` (D7).
- [ ] Test yang sempit dipilih via `-Dtest-filter` (suite penuh itu lama).
- [ ] Perubahan compile (build hijau) sebelum commit.
- [ ] `zig fmt .` pada file yang disentuh.
- [ ] PROGRESS.md diperbarui dengan bukti verifikasi.
- [ ] Commit kecil, pesan jelas, tanpa force-push.
- [ ] Perubahan fungsional = di branch fase, bukan langsung ke `main`/`wraith/dev` sembarangan.

## Larangan (dari spec)

| Larangan | Alasan |
|---|---|
| `sudo` / ubah sistem | §0.7 |
| Fetch-merge `upstream` | D7 |
| Force-push / hapus branch orang lain | §0 kerja |
| Commit yang tidak compile | disiplin build hijau |
| Klaim "selesai" tanpa test dijalankan | bukti, bukan klaim |
| Bikin konvensi/modul kedua untuk hal yang sudah ada | §4 reuse pola repo |
| `tc netem` | uid bukan root → pakai `LossyLink` |

## Kalimat pemulihan (bila ragu/kehilangan arah)

> "Baca `docs/wraith/PROGRESS.md`, ambil task belum selesai paling awal, kerjakan,
> verifikasi dengan test, catat, commit."

## AKHIR LOOP PROMPT
