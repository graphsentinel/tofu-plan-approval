# One full run from the clean Ubuntu 26.04 VM (2026-10-15)

The complete records of run [20261015T184044Z](run-20261015T184044Z), the first of the five runs in
[the Ubuntu 26.04 VM test](..), written by the harness from the committed tree named in [../source.txt](../source.txt).
It covers TC-01 to TC-06 and has the same layout as the [reference runs](../../../reference), with the current file
and variable names (`second-writer`, `value`); the reference runs predate TC-06.

Left out: `kubeconfig` and `kubeconfig.second-writer` (an admin client key and a service account token of a lab
cluster that no longer exists) and the API server's raw `audit.log` files (the checks read the `audit.jsonl`
snapshots, which are included). Only the files listed in the run's `MANIFEST.sha256` were copied, so files the checks
derive later (such as `audit/combined.jsonl`) are not here. `MANIFEST.sha256` was written again over this copy;
apart from the two kubeconfig files, every file matched the run's original manifest.

[measurements.tsv](measurements.tsv) holds the rows `scripts/collect.py` derives from this run; they are identical to
the rows the VM derived during the test.
