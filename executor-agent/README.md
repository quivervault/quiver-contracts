# Quiver Executor Agent

Agent onchain untuk Quiver (Robinhood Chain 4663): memantau semua vault dan
strategi, menyusun aksi executor yang jatuh tempo, mensimulasikan semuanya,
dan mengeksekusi **satu transaksi per konfirmasi eksplisit febri ("gas")**.
Agent ini tidak pernah broadcast sendiri dan tidak pernah memegang dana user —
withdraw dan claim yield tetap owner-only di kontrak.

Dibangun 2026-11-27 atas pilihan febri ("Gas Quiver Executor Agent").

## Cara pakai

```bash
cd ~/workspace/quiver-executor-agent
npm install          # sekali saja (ethers)
node agent.js status # laporan live read-only (v1 + v6), tanpa kunci
node agent.js plan   # proposal + simulasi, tersimpan ke runs/latest-plan.json
node agent.js execute P1 --confirm GAS   # SATU proposal, hanya setelah febri bilang gas
node agent.js recall-preview <vault> <strategy> <ETH|USDG> <amount>
```

Alur normal dengan cil di chat: cil menjalankan `plan`, menunjukkan preview
(ID, target, jumlah, gas, hasil simulasi) ke febri, febri menjawab "gas"
untuk ID tertentu, cil menjalankan `execute <id> --confirm GAS`, lalu
melaporkan hash + gas + saldo. Plan berlaku 30 menit; lewat dari itu
`execute` menolak dan minta plan ulang.

## Yang direncanakan agent

- **Aktivasi v6 (admin):** `executeStrategyApproval` untuk Morpho + LP begitu
  timelock lewat (Minggu 29 Nov 2026 ~02:34 WIB).
- **Deploy (executor):** kapital idle vault sampai batas profilnya
  (USDG → Morpho, ETH → LP), hanya ke strategi yang sudah approved.
- **Supply (executor):** sweep USDG idle di MorphoStrategy ke Steakhouse.
- **Mint LP (executor):** satu posisi full-range dari unminted principal,
  minimum 99,6% (kontrak memaksa lantai 99,5%).
- **Collect (executor):** fees LP dan yield Morpho/LP ke executor wallet.
  Settlement ke reserve tiap vault (fundYield + creditYield) **tidak**
  diotomatiskan — strategi bersifat pooled dan atribusi per-vault adalah
  keputusan febri.
- **Recall:** tidak pernah diusulkan otomatis; hanya preview atas instruksi
  eksplisit dengan vault + strategi + token + jumlah.

## Rel keamanan (ditegakkan di kode)

- `status`/`plan` tidak memuat private key sama sekali; simulasi memakai
  `eth_call` dari alamat admin/executor yang dikenal.
- `execute` memuat tepat satu file kunci yang sudah ada
  (`quiver-admin/deployer.key` untuk admin, `quiver-admin/executor.key`
  untuk executor, keduanya mode 600), memverifikasi alamat signer,
  mensimulasi ulang, mengecek chain id 4663 + kode kontrak + saldo gas,
  lalu mengirim satu tx dengan fee terpaku (maxFee 0,025 gwei, gasLimit
  estimasi ×1,3 — pola yang sama dengan skrip quiver-admin).
- Semua write LPStrategy **v1** diblokir keras (instruksi tetap febri).
- Fungsi owner-only tidak pernah dipanggil; agent hanya melaporkan status
  claim-due.
- Kunci tidak pernah dicetak, dicatat, atau disalin ke folder agent.

## State live saat dibangun (2026-11-27 11:12 WIB, block 123.979.707)

- v6 factory `0xee7f6607…72369`: 0 vault, Morpho `0x8070A912…51A5` dan LP
  `0x265F9cfF…c8Cd` belum approved, ETA Minggu 29 Nov 2026 02:34 WIB.
- v1 factory `0x681eE15f…15A2E9`: 3 vault semua deposits-paused, principal 0
  kecuali debu bookkeeping di vault tes. Vault febri `0x460D11bA…F486` sudah
  0 (0,01 ETH-nya sudah ditarik sendiri oleh febri).
- Executor `0x28D227Eb…6221`: 0,0001 ETH. Admin/control
  `0x0d6fa82F…fE8`: 0,000498 ETH.

## Runbook aktivasi Minggu 29 Nov

1. Setelah 02:34 WIB: `node agent.js plan` → harus muncul 2 proposal
   ACTIVATE_STRATEGY (admin) dengan simulasi OK.
2. Febri "gas" satu per satu → `execute P1`, lalu plan ulang, `execute P2`.
3. Site switch ke v6 hanya atas perintah febri (di luar agent ini).
4. Setelah site pindah dan ada deposit: `plan` akan mengusulkan deploy →
   supply/mint; eksekusi satu per satu dengan "gas" seperti biasa.
5. Revoke approval v1 + pause v1 menyusul sesuai rencana HeyResearch —
   langkah admin terpisah, bukan bagian plan otomatis agent.

## File

- `agent.js` — CLI agent (status/plan/execute/recall-preview)
- `config.json` — alamat, ambang kebijakan, path kunci (tanpa nilai kunci)
- `status.html` — dashboard read-only satu file (baca RPC langsung dari
  browser; deploy hanya atas perintah febri)
- `runs/` — plan terakhir + log eksekusi per tx

## HEY Research Lab integration

`status` also reads Quiver's public record on HEY Research Lab
(heyresearch.xyz) so the on-chain view can be compared with what HEY has
recorded. Every HEY call sends the integration header:

```
x-hey-integration: quiver-executor/1.0.0
```

Endpoints read (public, no key, read-only):

- `GET /api/token/4663/<QUIV contract>` — token to project record
- `GET /api/projects/quiver-aca79a/snapshot` — one-read project state

The read fails soft: if HEY is unreachable, the on-chain status still prints.
