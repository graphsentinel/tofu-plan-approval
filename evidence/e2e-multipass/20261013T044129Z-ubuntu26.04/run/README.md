# One full run from the clean Ubuntu 26.04 VM (2026-10-13)

The complete records of run [20261013T044514Z](run-20261013T044514Z), the first of the five runs in
[the Ubuntu 26.04 VM test](..), written by the current harness from the committed tree named in
[../source.txt](../source.txt). It has the same layout and the same measurement rows as the
[reference runs](../../../reference), with the current file and variable names (`second-writer`, `value`).

Left out: `kubeconfig` and `kubeconfig.second-writer` (an admin client key and a service account token of a lab
cluster that no longer exists) and the API server's raw `audit.log` files (the checks read the `audit.jsonl`
snapshots, which are included). `MANIFEST.sha256` was written again over this copy; apart from the two kubeconfig
files, every file matched the run's original manifest.

[measurements.tsv](measurements.tsv) holds the rows `scripts/collect.py` derives from this run; they are identical to
the rows the VM derived during the test and to the rows of the reference runs.
