# Reference runs (2026-09-29)

Two full runs of the experiment (TC-01 … TC-05 each), recorded on the author's workstation with the pinned versions
in [scripts/versions.env](../../scripts/versions.env). The results in the top-level README come from these runs.

| Run | Started (UTC) | Files |
|---|---|---|
| [20260929T163428Z](20260929T163428Z) | 2026-09-29 16:34:28 | 297 |
| [20260929T164313Z](20260929T164313Z) | 2026-09-29 16:43:13 | 297 |

[measurements.tsv](measurements.tsv) holds the rows `scripts/collect.py` derives from both runs; they are identical
row by row. Re-check everything without a cluster:

```bash
scripts/verify.sh --reference
scripts/collect.py --check evidence/reference evidence/reference/measurements.tsv
```

## What changed between the recording and this copy

The runs were recorded by the first version of the harness, whose file and variable names were in Turkish. This
copy was made from the closed archives (only the files each run's original `MANIFEST.sha256` listed) with these
changes, and nothing else:

- **File names translated** to the names the current harness writes, so the current checks read them. The full
  mapping is [RENAMES.tsv](RENAMES.tsv); path strings inside the files follow the new names.
- **Dropped:** `kubeconfig` and `kubeconfig.dis-yazar` of each run (an admin client key and a service account token
  of lab clusters that no longer exist). No check reads them.
- **Masked:** the author's home directory prefix in paths (inside `*.tfplan`, the plan files, it is replaced by a
  string of the same length so the files stay well-formed); `user@host` in the state-lock records (`Who:`) became
  `labuser@labhost`; the approver name in `approval.json` became `author`.
- **New `MANIFEST.sha256`** in each run, over this copy. The digest of each original manifest is kept by the author.
  Because the plan files were masked, `reviewed_plan_sha256` in `approval.json` is the digest of the original file,
  not of the masked copy; TC-02's two plan files are still byte-identical to each other.

Names that appear inside recorded command lines and plans are the original ones:

| Original | Meaning |
|---|---|
| `deger` (tofu variable) | `value` |
| `kilit_fifo` (tofu variable) | `lock_fifo` |
| `dis-yazar` (service account) | `second-writer` |
| `run.json` keys `basladi`, `pinler`, `kaynak_commit`, `hedef`; `runner.tip`, `runner.not` | `started`, `pins`, `source_commit`, `target`; `runner.kind`, `runner.note` |
| `events.jsonl` keys `sira`, `kaynak`, `mesaj` (messages in Turkish, e.g. `baslangic deger=A` = start value=A) | `seq`, `source`, `message` |
| `opportunities.jsonl` key `firsat` | `opportunity` |
| `approval.json` key `not` | `note` |

The raw audit logs the API server wrote (`audit/audit.log`) are not included: the harness reads its snapshots
(`audit.jsonl`), which are.
