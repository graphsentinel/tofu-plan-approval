# What Does Plan Approval Guarantee?

Four boundary tests that ask what approving an OpenTofu plan actually binds, when a second writer reaches the
same Kubernetes object.

**Result, in this pinned setup: exactly one of the four is stopped, by the saved plan's stale-plan check
("Saved plan is stale"), not by the state lock.**

This is not a vulnerability report. No mechanism was bypassed: the stale-plan check, the state lock and Flux each
did what they are for. The question is what an approval is bound to, and how far that reaches. See [What this does not say](#what-this-does-not-say).

- [What is measured](#what-is-measured) · [Results](#results) · [Where each result comes from](#where-each-result-comes-from)
- [Quickstart](#quickstart) · [How to](#how-to) · [Check the claims](#check-the-claims-rather-than-trust-them)
- [Versions](#versions) · [Troubleshooting](#troubleshooting) · [Layout](#layout)

---

## What is measured

One `ConfigMap` (`t27/t27`), one field (`data.value`). Start `A`; the approved change is `B` (in TC-01 the reviewed
plan keeps `A`, a no-op); the second writer writes `C`.
OpenTofu keeps its state in the Kubernetes backend (secret `t27-state/tfstate-default-t27`, lease-based lock).
The runner is a person-triggered OpenTofu CLI, not a controller. The second writer is a separate service account
with its own token, so the API server's audit log records it as a different authenticated user.

| Test | Setup | What the approval is bound to |
|---|---|---|
| **TC-01** | Approve a plan, then the runner re-plans before applying | the configuration (git revision) |
| **TC-02** | Apply the exact saved plan after the object was edited out of band | the saved plan file (sha256) |
| **TC-03** | A competing apply advances the shared state, then the earlier saved plan is applied | the saved plan file |
| **TC-04** | Apply the approved plan cleanly, then let Flux reconcile a source that says `C` | the saved plan file |
| **TC-05** | The same four paths with no second writer | control |

Recorded per path: what the approval was bound to, planned actions, state serial and lineage, the API writes the
audit log captured (with request and response bodies for the target object), field managers, final field values,
and the exit code plus rejection class of every command. Every scenario runs on a fresh k3d cluster.

## Results

From the two reference runs of 2026-09-29 (identical row by row; [evidence/reference](evidence/reference)):

| Test | Result | Protection engaged |
|---|---|---|
| **TC-01** | reviewed plan `no-op`, applied plan `update`; the API went `C → A` | no |
| **TC-02** | plan file identical (sha256); the out-of-band edit left the state's lineage and serial unchanged; the apply **succeeded**: `C → B` | no |
| **TC-03** | lock precondition shown first (a second runner is refused with *"Error acquiring the state lock"* while an apply holds it); the plan is saved from state serial 4 (`TC-03/state.05-after-lock.summary.json`); a competing apply moves it to 5 on the same lineage and the earlier plan is rejected with *"Saved plan is stale"*; the target stays `C` | **yes**, by the stale-plan check |
| **TC-04** | the approved plan applies `A → B`; Flux's service account then writes `B → C` on the same object (same UID) | no |
| **TC-05** | `A, B, B, B`; no write by the second writer or Flux | control |

**The lock did not stop TC-03.** The competing apply ran after the earlier plan was saved and finished before it
was applied, so there was no lock contention at that moment. The saved plan carries the state serial it was made
from, and `tofu apply` refuses it when the state has moved on. In TC-02 the edit went straight to the API and did
not touch the state, so neither mechanism had anything to detect.

**Counting API calls and field changes separately (TC-04).** In the 120-second window there were 3 completed
reconciliation opportunities. Flux's kustomize-controller made 5 successful API calls on the object: 4 were dry
runs (`?dryRun=All`, the controller's drift detection; nothing is written) and 1 was a server-side apply that
persisted. That one write is Flux's only field change: `B → C` (with OpenTofu's `A → B` before the window, the
object changed twice in TC-04). Counting Flux's API calls gives 5; counting Flux's field changes gives 1. The request
body cannot tell them apart: the server-side apply here sends the whole desired value, so request and response both
say `C` even when the field changed. EV-012 therefore orders the persisted writes by `resourceVersion` and compares
each with the one before it.

### What this does not say

| It does not say | Why |
|---|---|
| "An approval is always independent of the outcome" | one pinned setup; no generalisation |
| "Server-side apply ownership would have stopped TC-02" | SSA options were not compared; TC-02 saw no conflict, which depends on how the provider writes |
| "Flux misbehaved" | Flux applied its own desired state; the gap is in what the approval was bound to |
| "This holds on every Kubernetes distribution" | one distribution (k3s); not repeated on a second one (open limit below) |
| "This holds for other OpenTofu, provider or Flux versions" | measured on the pins below only |
| "The lock would have protected TC-02" | the second writer's edit did not change the state; there was no contention for a lock to resolve |

**Open limits.** (1) Not every observed behaviour is shown to be independent of k3s; a repeat of TC-02 and TC-04 on
a second distribution would settle it, and a different result would make the finding k3s-specific. (2) OpenTofu
CLI and Flux's kustomize-controller are what was measured; no OpenTofu controller (for example tofu-controller)
was run, and nothing here is claimed about one.

## Where each result comes from

| Source | Stack | Runs | Where |
|---|---|---|---|
| Reference runs, 2026-09-29 | workstation, Docker; versions below | 2 full runs (TC-01…TC-05 each) | [evidence/reference](evidence/reference) |

The reference runs were recorded by the first version of this harness, before its file names were translated to
English; [evidence/reference/README.md](evidence/reference/README.md) lists the renames and what was masked.

---

## Quickstart

Ubuntu 24.04 or 26.04 with network access for the first install. The scripts support amd64 and arm64; the clean-VM
runs used amd64 with 4 CPUs and 8 GB of memory.

```bash
git clone https://github.com/graphsentinel/tofu-plan-approval.git
cd tofu-plan-approval
scripts/platform.sh install       # what is missing: Docker, jq, curl, unzip, python3, git; tofu, flux, k3d, kubectl into bin/
scripts/platform.sh cluster-up    # the lab's k3d cluster t27 and registry t27-reg
RUNS=2 scripts/lab.sh all         # build, install, then the full experiment twice, checks, summary
```

`lab.sh test` prints `ALL CHECKS PASSED` when every run matches [lab/expected.tsv](lab/expected.tsv). On a 4-CPU,
8 GB Ubuntu 26.04 VM, `platform.sh install` plus `cluster-up` took 98 s and one full run (five scenarios, each on a
fresh cluster, with its checks) about 5 minutes. Remove the lab and its cluster
with `scripts/lab.sh uninstall && scripts/platform.sh cluster-down`; the tools stay in `bin/` and Ubuntu packages
installed by `install` stay installed.

No cluster, only `bash`, `jq` and `python3`: re-run every check that reads a recorded run against the published
reference runs, and re-derive the measurement rows.

```bash
scripts/verify.sh --reference
scripts/collect.py --check evidence/reference evidence/reference/measurements.tsv
```

## How to

The lab has two layers. Each command is safe to run again.

**Layer 1, `scripts/platform.sh`: tools and cluster**

| Command | What it does |
|---|---|
| `install` | installs only what is missing: Ubuntu packages (`docker.io`, `jq`, `curl`, `ca-certificates`, `unzip`, `python3`, `git`) at Ubuntu's versions; `tofu`, `flux`, `k3d` and `kubectl` at the pinned versions into this repository's `bin/`, each checked against the publisher's sha256. An existing Docker or Podman engine and any tools elsewhere on the host are left unchanged. Writes `lab/.runtime/pins.env`. |
| `cluster-up` | k3d cluster `t27` (one k3s server) with the audit policy [k3d/audit-policy.yaml](k3d/audit-policy.yaml) and a local registry `t27-reg` on port 5111; kubeconfig in `lab/.runtime/kubeconfig` |
| `cluster-down` | deletes that cluster and registry and checks neither is left |
| `status` | tool versions against the pins, cluster nodes |

The cluster carries the label `tofu-plan-approval/lab=true` on its server container. A k3d cluster named `t27`
without that label, or a container named `t27-reg` that is not k3d's registry for that cluster, belongs to someone
else: the scripts refuse to delete or reuse it. They create, change and delete no other cluster.

**Layer 2, `scripts/lab.sh`: the lab on that cluster**

| Command | What it does |
|---|---|
| `build` | pulls the k3s and registry images; fetches the provider and checks it against [tofu/.terraform.lock.hcl](tofu/.terraform.lock.hcl) |
| `install` | the starting point of every path: namespaces `t27` and `t27-state`, the `second-writer` service account, `ConfigMap t27 = A` applied by OpenTofu, Flux installed with its source ([gitops/](gitops), value `C`) suspended. For walking through a path by hand; it prints how. |
| `uninstall` | `tofu destroy`, `flux uninstall`, the lab's labelled namespaces and binding; then checks nothing is left |
| `reinstall` | `uninstall` + `install` |
| `test` | the measured experiment `RUNS` times (default 5): [scripts/experiment.sh](scripts/experiment.sh) `all`, the checks ([scripts/verify.sh](scripts/verify.sh)) and the measurement rows ([scripts/collect.py](scripts/collect.py)) of each run, then `summary`. Each scenario deletes and recreates cluster `t27`; if the platform cluster was up before, it is recreated (empty) at the end. |
| `summary` | compares the last `test` with [lab/expected.tsv](lab/expected.tsv), cell by cell; exit 1 on any difference |
| `status` | the lab's objects, the ConfigMap's value, Flux |
| `all` | `build` + `install` + `test` |

Single scenarios: `scripts/experiment.sh TC-01` … `TC-05`, then `scripts/experiment.sh clean` and
`scripts/verify.sh`. Run archives go to `runs/<UTC>/`, results to `results/<UTC>/`.

## Check the claims rather than trust them

Each claim is a row in [checks/ledger.tsv](checks/ledger.tsv) with the script that tests it. The exit-code contract
is **0 = passed, 1 = the claim is false, 77 = could not run**. 77 never counts as passed: `scripts/verify.sh` exits
1 when a claim failed, otherwise 2 when a check that should run did not. The only checks allowed not to run are named in the output: three
human-judgement checks (`MANUAL`: EV-015/016/017), the publication gate (`GATE`: EV-018, run with
`scripts/verify.sh --publish`), host checks against recorded evidence and pair checks with a single run (`N/A`).

[scripts/collect.py](scripts/collect.py) derives the measurement rows from the raw records a second time, in
Python, without the shell checks; [scripts/summary.py](scripts/summary.py) compares both with the expected table.
`scripts/collect.py --check evidence/reference evidence/reference/measurements.tsv` re-derives the published rows.

**Limits.** This catches drift and mistakes; it does not stop a determined attacker. A run archive verifying its
own `MANIFEST.sha256` is not independent tamper evidence: keep the manifest digest that `experiment.sh` prints
somewhere else. Worth reading on every change: `checks/ledger.tsv` (a claim weakened or moved to manual),
`scripts/verify.sh` (a gate loosened), `lab/expected.tsv` (an expectation changed).

## Versions

The result holds for these pins ([scripts/versions.env](scripts/versions.env)); checks/01-pins.sh enforces them.

| Component | Version |
|---|---|
| OpenTofu | 1.12.6 |
| hashicorp/kubernetes provider | 2.38.0 |
| Flux | 2.9.5 (source-controller, kustomize-controller) |
| k3s | `rancher/k3s:v1.37.0-k3s1` |
| k3d | v5.8.3 |
| kubectl | v1.35.0 |

`scripts/check-versions.sh` lists newer upstream releases. A newer version is a separate measurement: change
`versions.env`, run `scripts/platform.sh install` and `scripts/lab.sh all`, and compare; it does not replace the
pinned result.

## Troubleshooting

| Symptom | Cause, fix |
|---|---|
| `docker not usable` right after `install` | the new `docker` group is not active in your shell yet; the scripts re-run themselves under `sg docker`, otherwise log out and in |
| `a k3d cluster named t27 exists and was not created by this lab` | rename or delete your cluster, or change `CLUSTER`/`REGISTRY`/`REGISTRY_PORT` in `scripts/versions.env` and run `scripts/platform.sh install` again (it rewrites `lab/.runtime/pins.env`) |
| `EV-001 FAILED: pin drift` | a tool in `bin/` differs from `scripts/versions.env`: delete it and run `scripts/platform.sh install` |
| port 5111 in use | change `REGISTRY_PORT` in `scripts/versions.env`, then `scripts/platform.sh install` |
| `EV-002 COULD NOT RUN: audit` | the audit canary was not seen; check `docker exec k3d-t27-server-0 ls /var/log/k3s-audit` |
| `Permission denied` on `runs/*/…/audit/audit.log` | the k3s container writes the raw audit log as root; the checks read the `audit.jsonl` snapshots instead. The directory is yours, so `rm -rf runs/` still works |
| k3s fails with too many open files | `scripts/platform.sh install` raises the inotify limits; run it again |

## Layout

```
scripts/      platform.sh · lab.sh · experiment.sh · gitops-setup.sh · lib.sh · verify.sh · collect.py · summary.py
              versions.env · check-versions.sh · multipass-e2e.sh (the quickstart in a fresh VM)
checks/       ledger.tsv · 01..15 automatic checks · 90..92 human judgement (always 77)
lab/          expected.tsv
tofu/ gitops/ k3d/   the experiment's OpenTofu configuration, Flux source and audit policy
evidence/     reference/ the two reference runs, measurements.tsv
publish.env   the published address, read by checks/15-publish.sh
```

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
