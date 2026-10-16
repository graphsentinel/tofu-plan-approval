# What does plan approval guarantee? OpenTofu, shared state and a second writer

A Kubernetes lab that asks what approving an OpenTofu plan actually binds when a second writer reaches the same
object, and what a check before the apply can do about it. One ConfigMap field goes through four boundary tests, a
sole-writer control and a pre-apply check ([gate/](gate)) on six paths, on pinned versions of
OpenTofu, its Kubernetes provider and Flux, on a local k3d cluster that anyone can rebuild from zero with a few
commands ([Quickstart](#quickstart)).

**Result, in this pinned setup: exactly one of the four is stopped, by the saved plan's stale-plan check
("Saved plan is stale"), not by the state lock. A pre-apply check that compares the live values with the values in
the approved plan, only at the paths the plan changes, blocked the plan after a conflicting edit (a field, a label)
and let it through otherwise (no edit, an unrelated annotation, a plan that also creates an object); the obvious
gates (the refresh-only exit code or its drift report) flagged every one of the six paths.**

Project page: https://graphsentinel.github.io/tofu-plan-approval/

- [The problem](#the-problem)
- [What is measured](#what-is-measured)
- [Results](#results)
- [The pre-apply check](#the-pre-apply-check)
- [Quickstart](#quickstart)
- [How-to](#how-to)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)

## The problem

Teams review an OpenTofu plan, approve it, and apply it to Kubernetes objects that other writers can also reach: a
person with `kubectl`, a script, or a GitOps controller that later reconciles the same object. Approving a plan feels
like approving an outcome. Several mechanisms sit between the approval and the outcome, each with its own scope:

| Mechanism | What it covers |
|---|---|
| Saved plan file (`tofu plan -out`) | executes the actions recorded in the saved plan without re-planning; it does not guarantee the live object's final value |
| Stale-plan check (`tofu apply <saved plan>`) | rejects a saved plan when the backend state's lineage or serial differs from the state the plan was made from |
| State lock (lease in the Kubernetes backend) | serializes OpenTofu operations that take the same state lock; it does not lock Kubernetes objects or reserve the state between plan and apply |
| Flux server-side apply (default `kustomize.toolkit.fluxcd.io/ssa: Override`) | applies the fields in its desired manifests on each successful reconciliation; another writer can change them again afterwards |

The lab asks, for one field: which second writer does each mechanism stop, which does it not, and what does the
approval end up bound to?

**Threat model.** The second writer is authorized: a separate service account editing the object (TC-01, TC-02), a
competing OpenTofu apply on the shared backend (TC-03), or Flux reconciling its own source (TC-04). No access control
is bypassed and the state backend is not attacked. Out of scope: compromised
credentials or backends, other state backends, OpenTofu controllers, and Kubernetes distributions other than k3s.

**What this is not.** Not a vulnerability report: no mechanism was bypassed; the stale-plan check, the state lock and
Flux each did what they are for. The question is what an approval is bound to, and how far that reaches.

## What is measured

One `ConfigMap` (`t27/t27`), one field (`data.value`). Start `A`; the approved change is `B` (in TC-01 the reviewed
plan keeps `A`, a no-op); the second writer writes `C`. OpenTofu keeps its state in the Kubernetes backend (secret
`t27-state/tfstate-default-t27`, lease-based lock). The runner is a person-triggered OpenTofu CLI, not a controller.
In TC-01 and TC-02 the second writer uses a separate service account and token, so the API server's audit log records
it as a different authenticated user; TC-03's competing apply uses the runner's credentials, and TC-04's writer is
Flux's service account.

| Test | Setup | What the approval is bound to |
|---|---|---|
| **TC-01** | Approve a plan, then the runner re-plans before applying | the configuration (git revision) |
| **TC-02** | Apply the exact saved plan after the object was edited out of band | the saved plan file (sha256) |
| **TC-03** | A competing apply advances the shared state, then the earlier saved plan is applied | the saved plan file |
| **TC-04** | Apply the approved plan cleanly, then let Flux reconcile a source that says `C` | the saved plan file |
| **TC-05** | The same four paths with no second writer | control |
| **TC-06** | TC-02 with the pre-apply check, on six paths: a conflicting edit of the field or of a planned label, no edit, an unrelated annotation, no edit with a label plan, a plan that also creates an object | the saved plan file, applied only if the check allows it |

Recorded per path: what the approval was bound to, planned actions, state serial and lineage, the API writes the
audit log captured (with request and response bodies for the target object), field managers, final field values,
and the exit code plus rejection class of each recorded command. Every scenario runs on a fresh k3d cluster.

## Results

### Sources

| Source | Stack | Runs | Where |
|---|---|---|---|
| Reference runs, 2026-09-29 | workstation, Docker; the pinned versions | 2 full runs (TC-01…TC-05 each; recorded before TC-06 existed) | [evidence/reference](evidence/reference) |
| Clean VM, 2026-10-16 | Ubuntu 26.04, docker.io, 4 CPU / 8 GB; this repository's quickstart from zero | 5 full runs (TC-01…TC-06, TC-06 on six paths), then 1 more after `reinstall` | [evidence/e2e-multipass/…-ubuntu26.04](evidence/e2e-multipass/20261016T043219Z-ubuntu26.04) |
| Clean VM, 2026-10-16 | Ubuntu 24.04, docker.io, 4 CPU / 8 GB; same | 1 full run, then 1 more after `reinstall` | [evidence/e2e-multipass/…-ubuntu24.04](evidence/e2e-multipass/20261016T043219Z-ubuntu24.04) |
| Clean VM, 2026-10-15 | Ubuntu 26.04 and 24.04, same; TC-06 on two paths, before the check moved to gate/ | 5 + 1 and 1 + 1 full runs | [26.04](evidence/e2e-multipass/20261015T183707Z-ubuntu26.04), [24.04](evidence/e2e-multipass/20261015T183710Z-ubuntu24.04) |
| Clean VM, 2026-10-13 | Ubuntu 26.04 and 24.04, same; before TC-06 existed | 5 + 1 and 1 + 1 full runs (TC-01…TC-05) | [26.04](evidence/e2e-multipass/20261013T044129Z-ubuntu26.04), [24.04](evidence/e2e-multipass/20261013T044132Z-ubuntu24.04) |

The two reference runs are identical row by row. The complete records of one clean-VM run, TC-01 to TC-06, written
by the current harness with English names throughout, are in
[evidence/e2e-multipass/…-ubuntu26.04/run](evidence/e2e-multipass/20261016T043219Z-ubuntu26.04/run). Every one of
the 8 clean-VM runs of 2026-10-16 matched [lab/expected.tsv](lab/expected.tsv) in all 21 check results and all 109
measurement rows; their TC-01 to TC-05 rows are the rows the reference runs give. The earlier clean-VM runs matched
what was expected then: 19 check results and 57 rows on 2026-10-15 (TC-06 on two paths), 17 and 39 on 2026-10-13
(before TC-06). Each VM also passed `install`, `reinstall`, `uninstall` and `cluster-down` with their residue checks. The
VM runs used the committed tree named in each `source.txt`. The reference runs were recorded by the first version of
this harness, before its file names were translated to English;
[evidence/reference/README.md](evidence/reference/README.md) lists the renames and what was masked.

### The four boundary tests

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

### One page: what each mechanism covered

In this pinned setup, for the four boundary tests and the pre-apply check (TC-06):

| Mechanism | TC-01 re-plan after approval | TC-02 saved plan after an out-of-band edit | TC-03 competing apply, then the earlier plan | TC-04 Flux after a clean apply |
|---|---|---|---|---|
| **Saved plan file** | not what was applied: the reviewed plan was a no-op, the runner applied a fresh plan (`update`, `C → A`) | applied unchanged (same sha256) over the edit: the field went `C → B`, not the reviewed `A → B` | the earlier saved plan was rejected; the field stayed `C` | applied as reviewed: `A → B` |
| **Stale-plan check** | did not engage: the runner applied a fresh plan made after the edit | did not engage: the edit changed neither the state's serial nor its lineage | **engaged**: plan saved at serial 4, state at 5, *"Saved plan is stale"*; the object kept `C` | did not reject the approved plan; Flux's write came after the apply |
| **State lock** | no contention: the second writer was not an OpenTofu run | no contention: the second writer was not an OpenTofu run | refused a concurrent runner in a separate step (*"Error acquiring the state lock"*); it is not what refused the earlier plan | no contention: the second writer was not an OpenTofu run |
| **Flux server-side apply** (`ssa: Override`) | — | — | — | after the apply: 5 successful calls, 4 of them dry runs; 1 persisted write `B → C` |
| **Pre-apply check** ([gate/](gate), TC-06) | — | blocked the saved plan when a path the plan changes had been edited (`C` kept), let it through otherwise (`A → B`) | — | not covered: Flux wrote after the apply |
| **Left open** | what is applied is whatever the re-plan produces | without the check: a change to the live object between plan and apply. With it: changes the plan does not make (reported, not blocked), and any change between the check and the apply | — | a later change by another authorized writer; here Flux, `B → C` |

Control (TC-05): with no second writer, the same paths give `A, B, B, B`, with no write by the second writer or Flux.

The stale-plan check compares the lineage and serial of the state a saved plan was made from with the current state
(OpenTofu v1.12.6, [`internal/backend/local/backend_local.go`, lines 347–375](https://github.com/opentofu/opentofu/blob/v1.12.6/internal/backend/local/backend_local.go#L347-L375)); it does not read the live object. That is why TC-03 was
refused and TC-02 was not.

Three checks this implies for a pipeline:

1. Does the approval bind a configuration revision or the exact saved plan that will be applied?
2. Does anything compare the live object with the reviewed plan before applying? ([gate/](gate) does, for the paths
   the plan changes: [The pre-apply check](#the-pre-apply-check).)
3. Which other writers can change the same fields during or after the apply?

### The pre-apply check on six paths (TC-06)

TC-06 repeats TC-02's setup and runs, between approval and apply, the check in [gate/](gate) as a pipeline would:
`gate/plan-drift-gate.sh reviewed.tfplan -var ...` (how it works: [The pre-apply check](#the-pre-apply-check)). Each
path starts at `A` on a fresh cluster; the plan is saved and approved; then the second writer acts, or not; then the
check decides whether the saved plan is applied.

| Path | Approved plan | Second writer, after approval | Check (gate 3) | Result |
|---|---|---|---|---|
| drift | `data.value` A → B | sets `data.value` to C | conflict at `data.value` → **blocked** | `C` kept; state serial unchanged |
| clean | `data.value` A → B | — | **applied** | `B` |
| unrelated | `data.value` A → B | adds an annotation | reported as drift outside the plan → **applied** | `B`; the annotation is still there after the apply |
| labels-drift | adds label `team=b` | sets label `team=c` | conflict at `metadata[0].labels.team` → **blocked** | `team=c` kept; state serial unchanged |
| labels-clean | adds label `team=b` | — | **applied** | `team=b` |
| create-clean | `data.value` A → B and creates `t27/t27-extra` | — | **applied** (a create is not drift) | `B`, `t27-extra` created |

Two obvious gates were recorded on the same paths for comparison: gate 1, the exit code of
`tofu plan -refresh-only -detailed-exitcode`, was 2 on all six paths, and gate 2, the `resource_drift` messages of
`tofu plan -refresh-only -json`, counted 1 on all six. Either would have blocked every plan, the clean ones included.
The reason is in the refresh-only plan: `binary_data`, `metadata.annotations` and `metadata.labels` go from `null` in
the state to `{}` as read from the cluster (the configuration sets none of them), and the plan reports that as a
change made outside OpenTofu. The check compares only the paths the plan changes and counts an empty map as null.

EV-019 checks the drift and clean paths, EV-021 the other four, EV-020 the obvious gates on the clean path, and
EV-022 runs the check's unit tests ([gate/test/run.sh](gate/test/run.sh)).

### Counting API calls and field changes separately (TC-04)

In the 120-second window Flux reconciled four times: once when the Kustomization was resumed, then three times on
request (the 3 recorded opportunities). Across them kustomize-controller made 5 successful API calls on the object:
4 were dry runs (`?dryRun=All`, the controller's drift detection; nothing is written) and 1 was a server-side apply
that persisted. That write happened right after the Kustomization was resumed, about two seconds before the first
requested reconciliation; the three requested reconciliations found nothing to change. It is Flux's only field
change: `B → C` (with OpenTofu's `A → B` before the window, the object changed twice in TC-04). Counting Flux's API
calls gives 5; counting Flux's field changes gives 1. The request body cannot tell them apart: the server-side apply
here sends the whole desired value, so request and response both say `C` even when the field changed. EV-012
therefore orders the persisted writes by `resourceVersion` and compares each with the one before it.

### What this does not say

| It does not say | Why |
|---|---|
| "An approval is always independent of the outcome" | one pinned setup; no generalisation |
| "Server-side apply ownership would have stopped TC-02" | SSA options were not compared; TC-02 saw no conflict, which depends on how the provider writes |
| "Flux misbehaved" | Flux applied its own desired state; the gap is in what the approval was bound to |
| "This holds on every Kubernetes distribution" | one distribution (k3s); not repeated on a second one (open limit below) |
| "This holds for other OpenTofu, provider or Flux versions" | measured on the pinned versions only |
| "The lock would have protected TC-02" | the second writer's edit did not change the state; there was no contention for a lock to resolve |
| "The pre-apply check closes the gap" | it covers the paths the plan changes, not the inputs the plan was computed from, not changes the plan does not make (reported only), and nothing between the check and the apply; measured on one provider and one resource type |

**Open limits.** (1) Independence from the distribution has not been established: everything ran on k3s. Repeating
TC-02 and TC-04 on another distribution would broaden the evidence; a different result there would need
investigation. (2) OpenTofu
CLI and Flux's kustomize-controller are what was measured; no OpenTofu controller (for example tofu-controller)
was run, and nothing here is claimed about one.

## The pre-apply check

[gate/plan-drift-gate.sh](gate/plan-drift-gate.sh) answers one question right before `tofu apply <plan>`: at every
path the approved plan changes, is the live value still the value recorded in the plan? It uses only OpenTofu and
`jq` (1.7 or later; it refuses a `jq` that compares large integers imprecisely); the comparison does not depend on the provider, for the plans it supports (below: what gives exit 2).

```bash
cd your-root-module
tofu plan -out reviewed.tfplan -var-file=prod.tfvars    # reviewed and approved
# ... later, in the apply job, with the same variables:
/path/to/gate/plan-drift-gate.sh reviewed.tfplan -var-file=prod.tfvars && tofu apply reviewed.tfplan
```

Exit status: 0 apply; 1 block (a path the plan changes no longer holds the recorded value: re-plan and re-approve);
2 could not decide, treat as block. The report on stdout lists addresses and paths, never values.

How it decides ([gate/planned-drift.jq](gate/planned-drift.jq)):

- It makes a refresh-only saved plan (`tofu plan -refresh-only -out`), which reads the live infrastructure without
  changing it or the state, and compares its values with the reviewed plan's recorded `before` values.
- Only the paths the plan changes count: for an update, the leaf paths whose value differs between `before` and
  `after` (a map key or list element present on one side only counts), plus those unknown until apply; for a create,
  delete or replace, the whole resource. A path through a list with more than one element stops at the list and
  compares all of it, so a reordering cannot move a change onto another element.
- An empty map or list counts as null on both sides; nothing else is normalised.
- Changes outside the planned paths are reported (`unplanned_drift`, `drift_outside_plan`); `--strict` blocks on them.
- It fails closed: unreadable, empty, errored or unsupported plans, a refresh made with different variables, options
  that would narrow or unlock the refresh (only `-var`, `-var-file`, `-lock`, `-lock-timeout`, `-parallelism`,
  `-no-color` and `-compact-warnings` pass), any `TF_CLI_ARGS*`, imports, moves and deposed objects all give exit 2.
- A container above a planned path that changed kind (a map that became null, a key that disappeared) is a conflict;
  so is a resource the plan updates, deletes or replaces that is no longer in the state.
- The refresh runs in the current workspace and data directory: run the check where the apply will run.

What it does not check: a write that lands between the check and the apply; the inputs the plan was computed from
(data sources, other resources); values the provider does not read back (write-only, ephemeral); objects outside the
state (a create does not prove the name is free); anything another writer does after the apply (TC-04). It was
measured on one provider (hashicorp/kubernetes 2.38.0) and one resource type; the unit tests cover the rest of its
logic on synthetic plans, 71 cases ([gate/test/run.sh](gate/test/run.sh), runs without tofu or a cluster).

## Quickstart

Requirements: Ubuntu 24.04 or 26.04 (amd64 or arm64), 4+ CPUs, 8 GB RAM, sudo for missing Ubuntu packages or
inotify-limit changes, and internet access during installation and the experiment.

```bash
sudo apt-get update && sudo apt-get install -y git   # if git is not there yet
git clone https://github.com/graphsentinel/tofu-plan-approval.git && cd tofu-plan-approval
scripts/platform.sh install       # missing Ubuntu packages (Docker, jq, curl, unzip, python3); pinned tofu, flux, k3d, kubectl into bin/
scripts/platform.sh cluster-up    # the lab's k3d cluster t27 and registry t27-reg
RUNS=2 scripts/lab.sh all         # build, install, then the full experiment twice (RUNS defaults to 5), checks, summary
```

If `install` added you to the `docker` group, the next commands pick the group up by themselves (they re-run under
`sg docker`). `scripts/lab.sh all` ends with the number of check results and measurement rows matching
[lab/expected.tsv](lab/expected.tsv) and either `ALL CHECKS PASSED` or the list of differences (exit status 1). The
table is also written to `lab/.runtime/summary.md`. On a 4-CPU, 8 GB Ubuntu 26.04 VM, `install` plus `cluster-up`
took about 2 minutes and one full run (TC-01 to TC-06, every scenario and TC-06 path on a fresh cluster, with its
checks) about 8 minutes (the step
times are in each VM's `host.log` under [evidence/e2e-multipass](evidence/e2e-multipass)). `all` finishes with an
empty platform cluster: run `scripts/lab.sh install` again before walking through a path by hand.

To remove the lab and keep the cluster: `scripts/lab.sh uninstall`. To remove the cluster too:
`scripts/platform.sh cluster-down`. The tools stay in `bin/`, and Ubuntu packages installed by `install` stay
installed.

Without a cluster, with only `bash`, `jq` and `python3`, every check that reads a recorded run can be re-run against
the published reference runs, and their measurement rows re-derived:

```bash
scripts/verify.sh --reference
scripts/collect.py --check evidence/reference evidence/reference/measurements.tsv
```

## How-to

### Two layers

| Layer | Script | What it owns |
|---|---|---|
| **platform** | `scripts/platform.sh` | host tools (Ubuntu packages; tofu, flux, k3d, kubectl in `bin/`) and the lab's k3d cluster and registry |
| **lab** | `scripts/lab.sh` | the OpenTofu configuration, Flux and its source, the experiment, its checks and the comparison |

The experiment needs a fresh cluster for every boundary test, so it deletes and recreates the cluster `t27` for each
scenario. The cluster carries the label `tofu-plan-approval/lab=true` on its server container. A k3d cluster named
`t27` without that label, or a container named `t27-reg` that is not k3d's registry for that cluster, belongs to
someone else: the scripts refuse to delete or reuse it. They create, change and delete no other cluster.

### Platform commands

| Command | What it does |
|---|---|
| `scripts/platform.sh install` | installs only what is missing: Ubuntu packages (`docker.io`, `jq`, `curl`, `ca-certificates`, `unzip`, `python3`, `git`) at Ubuntu's versions; `tofu`, `flux`, `k3d` and `kubectl` at the pinned versions into this repository's `bin/`, each checked against the publisher's sha256. An existing Docker or Podman engine and any tools elsewhere on the host are left unchanged. Writes `lab/.runtime/pins.env` |
| `scripts/platform.sh cluster-up` | k3d cluster `t27` (one k3s server) with the audit policy [k3d/audit-policy.yaml](k3d/audit-policy.yaml) and a local registry `t27-reg` on port 5111; kubeconfig in `lab/.runtime/kubeconfig` |
| `scripts/platform.sh cluster-down` | deletes that cluster and registry and checks neither is left |
| `scripts/platform.sh status` | tool versions against the pins, cluster nodes |

### Lab commands

| Command | What it does |
|---|---|
| `scripts/lab.sh build` | pulls the k3s and registry images; fetches the provider and checks it against [tofu/.terraform.lock.hcl](tofu/.terraform.lock.hcl) |
| `scripts/lab.sh install` | the starting point of every path: namespaces `t27`, `t27-state` and `flux-system`, the `second-writer` service account and its `edit` binding, `ConfigMap t27 = A` applied by OpenTofu, Flux installed with its source ([gitops/](gitops), value `C`) suspended. For walking through a path by hand; it prints how |
| `scripts/lab.sh uninstall` | `tofu destroy`, `flux uninstall`, the lab's labelled namespaces and binding; then checks nothing is left |
| `scripts/lab.sh reinstall` | `uninstall` + `install` |
| `scripts/lab.sh test` | the measured experiment `RUNS` times: [scripts/experiment.sh](scripts/experiment.sh) `all`, the checks ([scripts/verify.sh](scripts/verify.sh)) and the measurement rows ([scripts/collect.py](scripts/collect.py)) of each run, then `summary`. If the platform cluster was up before, it is recreated (empty) at the end |
| `scripts/lab.sh summary` | compares the last `test` with [lab/expected.tsv](lab/expected.tsv), cell by cell: every run's check results and measurement rows, the shell and Python counts of TC-04 against each other, no runner error, the test run to its end |
| `scripts/lab.sh status` | the lab's objects, the ConfigMap's value, Flux |
| `scripts/lab.sh all` | `build` + `install` + `test` |
| `scripts/check-versions.sh` | the pinned versions against the latest upstream releases |

Options: `RUNS` (default 5).

### Run one scenario

A single scenario is incomplete evidence for the full check suite: `scripts/verify.sh` then reports the other
scenarios as could-not-run (exit 2). Use `scripts/lab.sh test` for a complete checked run. Replace `<UTC>` with the
run id the experiment prints.

```bash
scripts/experiment.sh TC-02     # one scenario → runs/<UTC>/
scripts/experiment.sh clean     # remove the experiment cluster (the isolation check expects it gone)
scripts/verify.sh               # the checks against the latest run
scripts/collect.py "runs/<UTC>" # its measurement rows
```

### Look at a run

Each run is a directory `runs/<UTC>/` (ignored by git): `run.json` (pins, source commit, target), `events.jsonl`,
`MANIFEST.sha256`, and one directory per scenario with each recorded command's `.argv`, `.stdout`, `.stderr`, `.rc` and
`.ms`, the object (`object.<phase>.json`) and state (`state.<phase>.summary.json`, `backend.<phase>.json`) at each
phase, the reviewed and applied plans, `approval.json` and the audit snapshot `audit.jsonl`. `lab.sh test` writes
each run's check results and measurement rows to `results/<UTC>/`. The published runs in
[evidence/reference](evidence/reference) have the same layout.

### Check the claims rather than trust them

Each claim is a row in [checks/ledger.tsv](checks/ledger.tsv) with the script that tests it. The exit-code contract
is **0 = passed, 1 = the claim is false, 77 = could not run**. 77 never counts as passed: `scripts/verify.sh` exits
1 when a claim failed, otherwise 2 when a check that should run did not. The only checks allowed not to run are named
in the output: three human-judgement checks (`MANUAL`: EV-015/016/017), the publication gate (`GATE`: EV-018, run
with `scripts/verify.sh --publish`), host checks against recorded evidence and pair checks with a single run (`N/A`).

[scripts/collect.py](scripts/collect.py) derives the measurement rows from the raw records a second time, in
Python, without the shell checks; [scripts/summary.py](scripts/summary.py) compares both with the expected table.

**Limits.** This catches drift and mistakes; it does not stop a determined attacker. A run archive verifying its
own `MANIFEST.sha256` is not independent tamper evidence: keep the manifest digest that `experiment.sh` prints
somewhere else. Worth reading on every change: `checks/ledger.tsv` (a claim weakened or moved to manual),
`scripts/verify.sh` (a gate loosened), `lab/expected.tsv` (an expectation changed).

### Change a version

The result holds for the pinned versions; a newer version is a separate measurement. Change
[scripts/versions.env](scripts/versions.env) (the provider also in [tofu/versions.tf](tofu/versions.tf) and the lock
file), run `scripts/platform.sh install` and `scripts/lab.sh all`, and compare with [lab/expected.tsv](lab/expected.tsv).
`scripts/check-versions.sh` lists newer upstream releases.

### Test in a throwaway VM

`scripts/multipass-e2e.sh` runs the quickstart in a fresh multipass VM from the committed tree: install, cluster-up,
`lab.sh all`, then install + reinstall, one more test, install + uninstall and cluster-down.

```bash
scripts/multipass-e2e.sh                    # Ubuntu 26.04, RUNS=5
UBUNTU=24.04 RUNS=1 scripts/multipass-e2e.sh
```

The output goes to a directory outside the repository (`OUT`, default `../tofu-plan-approval-review/e2e-multipass/`).

### Versions

| Comes from | Components | Version |
|---|---|---|
| Ubuntu's packages | Docker (`docker.io`), jq, curl, unzip, python3, git | whatever the Ubuntu release ships; an existing Docker or Podman is kept. The clean-VM runs had Docker 29.1.3 on both releases (`environment.txt` of each run) |
| upstream, into `bin/` (sha256-checked) | OpenTofu | 1.12.6 |
| | Flux CLI | 2.9.5 |
| controller images, installed by `flux install` | source-controller, kustomize-controller | the versions of the Flux 2.9.5 release |
| | k3d | v5.8.3 |
| | kubectl | v1.35.0 |
| container image, pinned | Kubernetes (`rancher/k3s`) | v1.37.0-k3s1 |
| OpenTofu provider, pinned with its lock file | hashicorp/kubernetes | 2.38.0 |

`checks/01-pins.sh` (EV-001) compares the tofu, flux, k3d and kubectl CLI versions and the provider version declared
in `tofu/versions.tf` with `lab/.runtime/pins.env`. The k3s image is set by the same pins when the cluster is created.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `docker not usable` right after `install` | the new `docker` group is not active in your shell yet; the scripts re-run themselves under `sg docker`, otherwise log out and in |
| `a k3d cluster named t27 exists and was not created by this lab` | rename or delete your cluster, or change `CLUSTER`/`REGISTRY`/`REGISTRY_PORT` in `scripts/versions.env` and run `scripts/platform.sh install` again (it rewrites `lab/.runtime/pins.env`) |
| `EV-001 FAILED: pin drift` | a tool in `bin/` differs from `scripts/versions.env`: delete it and run `scripts/platform.sh install` |
| port 5111 in use | change `REGISTRY_PORT` in `scripts/versions.env`, then `scripts/platform.sh install` |
| `EV-002 COULD NOT RUN: audit` | the audit canary was not seen; check `docker exec k3d-t27-server-0 ls /var/log/k3s-audit` |
| `Permission denied` on `runs/*/…/audit/audit.log` | the k3s container writes the raw audit log as root; the checks read the `audit.jsonl` snapshots instead. The directory is yours, so `rm -rf runs/` still works |
| k3s fails with too many open files | `scripts/platform.sh install` raises the inotify limits; run it again |
| a result differs from `lab/expected.tsv` | the summary names the run and the row; its records are in `runs/<UTC>/` and `results/<UTC>/` |

## Repository layout

```
scripts/                  platform.sh (layer 1), lab.sh (layer 2), versions.env, experiment.sh, gitops-setup.sh,
                          lib.sh, verify.sh, collect.py, summary.py, check-versions.sh, multipass-e2e.sh
gate/                     the pre-apply check: plan-drift-gate.sh, planned-drift.jq, test/run.sh (unit tests)
checks/                   ledger.tsv, 01..19 automatic checks, 90..92 human judgement (always 77), target-writes.jq
lab/expected.tsv          the expected result of every check and measurement row
tofu/                     the OpenTofu configuration (kubernetes backend, one ConfigMap; TC-06 adds labels and a
                          second ConfigMap through variables) and its lock file
gitops/                   Flux's source: the same ConfigMap with value C
k3d/audit-policy.yaml     the API server's audit policy
evidence/reference/       the two reference runs and their measurement rows
evidence/e2e-multipass/   the clean-VM runs: summaries, per-run results, step logs
docs/                     the project page (GitHub Pages)
publish.env               the published address, read by checks/15-publish.sh
runs/, results/           written by your own runs (git-ignored)
```

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
