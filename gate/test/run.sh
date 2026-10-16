#!/usr/bin/env bash
# ==================================================================
# Unit tests of the pre-apply check (gate/plan-drift-gate.sh --compare) on synthetic `tofu show -json` documents.
# No tofu, no cluster: only bash and jq. Each case builds a reviewed plan and a refresh-only plan and states the
# exit status the check must give (0 apply, 1 block, 2 could not decide).
#
#   gate/test/run.sh        exit 0 when every case gives its expected status, 1 otherwise
# ==================================================================
set -uo pipefail
GATE="$(cd "$(dirname "$0")/.." && pwd)/plan-drift-gate.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0

# reviewed <address> <actions> <before> <after> [after_unknown] [mode]: a plan with one resource change
reviewed(){ jq -n --arg a "$1" --argjson act "$2" --argjson b "$3" --argjson af "$4" \
              --argjson u "${5:-{\}}" --arg m "${6:-managed}" \
  '{format_version:"1.2",terraform_version:"1.12.6",configuration:{},planned_values:{},resource_changes:[{address:$a,mode:$m,change:{actions:$act,before:$b,after:$af,after_unknown:$u}}]}'; }
# refresh <address> <live values|null> [state-before]: a refresh-only plan whose prior_state holds the live values
refresh(){ jq -n --arg a "$1" --argjson v "$2" --argjson sb "${3:-null}" '
  {format_version:"1.2",terraform_version:"1.12.6",configuration:{},planned_values:{},
   prior_state:{values:{root_module:{resources:(if $v == null then [] else [{address:$a,mode:"managed",values:$v}] end)}}},
   resource_drift:(if $sb == null then [] else [{address:$a,mode:"managed",change:{actions:["update"],before:$sb,after:$v}}] end)}'; }
case_(){ # case_ <name> <expected exit> [--strict]   (reads $T/r.json and $T/f.json)
  local out rc
  out=$("$GATE" ${3:-} --compare "$T/r.json" "$T/f.json" 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then PASS=$((PASS+1)); printf '  ok    %-58s exit %s\n' "$1" "$rc"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-58s exit %s, expected %s\n%s\n' "$1" "$rc" "$2" "$out"; fi
}

A=kubernetes_config_map.t27
CM(){ # CM <value> [labels] [annotations]: a ConfigMap as the kubernetes provider stores it
  jq -n --arg v "$1" --argjson l "${2:-null}" --argjson an "${3:-null}" \
    '{data:{value:$v},binary_data:null,metadata:[{name:"t27",namespace:"t27",labels:$l,annotations:$an,resource_version:"1"}]}'; }

echo "update"
reviewed $A '["update"]' "$(CM A)" "$(CM B)" > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "planned value unchanged" 0
refresh  $A "$(CM C)" "$(CM A)" > $T/f.json;                        case_ "planned value changed by a second writer" 1
refresh  $A "$(CM A '{}' '{}' | jq '.binary_data={}')" "$(CM A)" > $T/f.json
                                                                     case_ "only null -> {} on unplanned maps (provider)" 0
refresh  $A "$(CM A null '{"note":"x"}')" "$(CM A)" > $T/f.json;     case_ "unplanned annotation added: reported, not blocked" 0
refresh  $A "$(CM A | jq '.metadata[0].resource_version="9"')" > $T/f.json
                                                                     case_ "unplanned computed attribute changed" 0
refresh  $A null > $T/f.json;                                       case_ "resource deleted out of band" 1

echo "nested paths (labels)"
reviewed $A '["update"]' "$(CM A)" "$(CM A '{"team":"b"}')" > $T/r.json
refresh  $A "$(CM A '{}' '{}')" > $T/f.json;                         case_ "label planned; annotations null -> {} only" 0
refresh  $A "$(CM A '{"team":"c"}')" > $T/f.json;                    case_ "label planned; second writer set the same label" 1
refresh  $A "$(CM A null '{"team":"c"}')" > $T/f.json;               case_ "label planned; annotation of the same key changed" 0
reviewed $A '["update"]' "$(CM A '{"team":"a","tier":"x"}')" "$(CM A '{"team":"b","tier":"x"}')" > $T/r.json
refresh  $A "$(CM A '{"team":"a","tier":"y"}')" > $T/f.json;         case_ "label team planned; label tier changed" 0
refresh  $A "$(CM A '{"team":"c","tier":"x"}')" > $T/f.json;         case_ "label team planned; label team changed" 1

echo "drift the reviewer already saw"
reviewed $A '["update"]' "$(CM C)" "$(CM B)" > $T/r.json
refresh  $A "$(CM C)" "$(CM A)" > $T/f.json;                         case_ "plan made over C (state A); live still C" 0
refresh  $A "$(CM D)" "$(CM A)" > $T/f.json;                         case_ "plan made over C; live now D" 1

echo "values unknown until apply"
reviewed $A '["update"]' "$(CM A)" "$(CM B | jq 'del(.metadata[0].resource_version)')" \
         '{"metadata":[{"resource_version":true}]}' > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "unknown planned path, live unchanged" 0
refresh  $A "$(CM A | jq '.metadata[0].resource_version="9"')" > $T/f.json
                                                                     case_ "unknown planned path, live changed there" 1
reviewed $A '["update"]' "$(CM A)" '{}' 'true' > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "whole resource unknown, live unchanged" 0

echo "create, delete, replace, data sources"
reviewed $A '["create"]' null "$(CM B)" > $T/r.json
refresh  $A null > $T/f.json;                                       case_ "create, nothing there" 0
reviewed $A '["delete"]' "$(CM A)" null > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "delete, unchanged" 0
refresh  $A "$(CM A null '{"note":"x"}')" > $T/f.json;              case_ "delete, changed anywhere" 1
reviewed $A '["delete","create"]' "$(CM A)" "$(CM B)" > $T/r.json
refresh  $A "$(CM C)" > $T/f.json;                                  case_ "replace, changed" 1
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "replace, unchanged" 0
reviewed data.x.y '["read"]' null '{"id":"1"}' '{}' data > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "data source read only" 0

echo "modules"
jq -n --argjson b "$(CM A)" --argjson af "$(CM B)" \
  '{format_version:"1.2",terraform_version:"1.12.6",configuration:{},planned_values:{},resource_changes:[{address:"module.m.kubernetes_config_map.t27",mode:"managed",
    change:{actions:["update"],before:$b,after:$af,after_unknown:{}}}]}' > $T/r.json
jq -n --argjson v "$(CM C)" '{format_version:"1.2",terraform_version:"1.12.6",configuration:{},planned_values:{},prior_state:{values:{root_module:{child_modules:[{address:"module.m",
    resources:[{address:"module.m.kubernetes_config_map.t27",mode:"managed",values:$v}]}]}}}}' > $T/f.json
                                                                     case_ "resource in a child module changed" 1

echo "fails closed"
reviewed $A '["update"]' "$(CM A)" "$(CM B)" > $T/r.json
: > $T/f.json;                                                       case_ "empty refresh JSON" 2
echo '{"format_version":"1.2","terraform_version":"1.12.6","configuration":{},"planned_values":{},"errored":true}' > $T/f.json;          case_ "errored refresh-only plan" 2
refresh  $A "$(CM A)" > $T/f.json; : > $T/r.json;                    case_ "empty reviewed JSON" 2
echo 'not json' > $T/r.json;                                         case_ "unreadable reviewed JSON" 2
reviewed $A '["forget"]' "$(CM A)" null > $T/r.json;                 case_ "action the check does not know" 2
rm -f $T/f.json; reviewed $A '["update"]' "$(CM A)" "$(CM B)" > $T/r.json
                                                                     case_ "missing refresh JSON" 2

echo "found in review: no false apply"
reviewed $A '["update"]' '{"id":"A","x":null}' '{"id":"A","x":"B"}' > $T/r.json
refresh  $A null > $T/f.json;                                       case_ "resource gone; the planned field was null" 1
reviewed $A '["update"]' '{"l":[{"id":"a","v":1},{"id":"b","v":1}]}' '{"l":[{"id":"a","v":2},{"id":"b","v":1}]}' > $T/r.json
refresh  $A '{"l":[{"id":"b","v":1},{"id":"a","v":1}]}' > $T/f.json; case_ "list reordered under a planned element" 1
refresh  $A '{"l":[{"id":"a","v":1},{"id":"b","v":1}]}' > $T/f.json; case_ "list unchanged" 0
reviewed $A '["update"]' '{"x":null}' '{"x":[]}' > $T/r.json
refresh  $A '{"x":["C"]}' > $T/f.json;                              case_ "plan empties a list (null -> []); live gained an element" 1
reviewed $A '["update"]' '{"x":null}' '{"x":{"k":"B"}}' > $T/r.json
refresh  $A '{"x":{}}' > $T/f.json;                                 case_ "planned map: null recorded, {} live (empty = null)" 0
reviewed $A '["update"]' '{"x":"1"}' '{"x":"1"}' > $T/r.json
refresh  $A '{"x":"2"}' > $T/f.json;                                case_ "update with no changed path: whole resource checked" 1
reviewed $A '["update"]' '{"o":{"k":"1"}}' '{"o":{"k":"2"}}' > $T/r.json
refresh  $A '{"o":"scalar"}' > $T/f.json;                           case_ "live has a scalar where the plan has an object" 1
reviewed $A '["create"]' null "$(CM B)" > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "create, but the state already holds the address" 1

reviewed $A '["update"]' '{"m":{"a":null},"x":1}' '{"m":{},"x":2}' > $T/r.json
refresh  $A '{"m":{"a":"C"},"x":1}' > $T/f.json;                     case_ "plan removes a key holding null; live set it" 1
reviewed $A '["update"]' '{"l":["a","b"],"x":1}' '{"l":["a"],"x":2}' > $T/r.json
refresh  $A '{"l":["a","c"],"x":1}' > $T/f.json;                     case_ "plan drops a list element; live changed it" 1

reviewed $A '["update"]' '{"m":{"a":null,"keep":1}}' '{"m":{"a":"B","keep":1}}' > $T/r.json
refresh  $A '{"m":{"keep":1}}' > $T/f.json;                          case_ "planned key held null; live has no such key" 1

reviewed $A '["update"]' '{"m":{"keep":1}}' '{"m":{"keep":1,"a":"B"}}' > $T/r.json
refresh  $A '{"m":null}' > $T/f.json;                                case_ "plan adds a key; live map around it removed" 1
refresh  $A '{"m":{"keep":1}}' > $T/f.json;                          case_ "plan adds a key; live map unchanged" 0
reviewed $A '["delete","create"]' '{}' "$(CM B)" > $T/r.json
refresh  $A null > $T/f.json;                                       case_ "replace of an empty resource now missing" 1

reviewed $A '["update"]' '{"x":9007199254740992}' '{"x":0}' > $T/r.json
refresh  $A '{"x":9007199254740993}' > $T/f.json;                    case_ "integers beyond 2^53 compared exactly" 1

echo "strict"
reviewed $A '["update"]' "$(CM A)" "$(CM B)" > $T/r.json
refresh  $A "$(CM A null '{"note":"x"}')" "$(CM A)" > $T/f.json;     case_ "strict: unplanned annotation blocks" 1 --strict
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "strict: nothing changed" 0 --strict

echo "fails closed (found in review)"
reviewed $A '["update"]' "$(CM A)" "$(CM B)" | jq '.resource_changes[0].change.importing={"id":"x"}' > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "import" 2
reviewed $A '["no-op"]' "$(CM A)" "$(CM A)" | jq '.resource_changes[0].previous_address="kubernetes_config_map.old"' > $T/r.json
                                                                     case_ "move" 2
reviewed $A '["delete"]' "$(CM A)" null | jq '.resource_changes[0].deposed="00000001"' > $T/r.json
                                                                     case_ "deposed object" 2
reviewed $A '["update"]' "$(CM A)" "$(CM B)" | jq '.format_version="99"' > $T/r.json
refresh  $A "$(CM A)" | jq '.format_version="99"' > $T/f.json;      case_ "unsupported format version" 2
reviewed $A '["update"]' "$(CM A)" "$(CM B)" | jq '.variables={"value":{"value":"B"}}' > $T/r.json
refresh  $A "$(CM A)" | jq '.variables={"value":{"value":"A"}}' > $T/f.json
                                                                     case_ "different variables in the two plans" 2
reviewed $A '["create"]' null "$(CM B)" | jq '.prior_state={"values":{"root_module":{}}}' > $T/r.json
echo '{"format_version":"1.2","terraform_version":"1.12.6","configuration":{},"planned_values":{}}' > $T/f.json
                                                                     case_ "refresh document without state" 2
reviewed $A '["update"]' "$(CM A)" "$(CM B)" | jq '.resource_changes[0].change.actions="update"' > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "malformed actions" 2

echo '{"format_version":"1.2"}' > $T/r.json; echo '{"format_version":"1.2"}' > $T/f.json
                                                                     case_ "stub documents (no configuration)" 2
echo '{"format_version":"1.2","configuration":null}' > $T/r.json; cp $T/r.json $T/f.json
                                                                     case_ "stub documents (configuration null)" 2
reviewed data.x.y '["frobnicate"]' null '{"id":"1"}' '{}' data > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "unknown action on a data source" 2
reviewed $A '["update"]' "$(CM A)" "$(CM B)" '{}' weird > $T/r.json
refresh  $A "$(CM A)" > $T/f.json;                                  case_ "unknown resource mode" 2

echo "wrapper options"
: > $T/plan.tfplan
for opt in -target=x -exclude=x -refresh=false -out=x -state=x -detailed-exitcode -destroy -lock=false -lock=0 -lock=f -lock=FALSE; do
  "$GATE" "$T/plan.tfplan" "$opt" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ]; then PASS=$((PASS+1)); printf '  ok    %-58s exit %s\n' "option $opt refused" "$rc"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-58s exit %s, expected 2\n' "option $opt refused" "$rc"; fi
done
for v in TF_CLI_ARGS TF_CLI_ARGS_plan TF_CLI_ARGS_apply; do
  env "$v=-target=x" "$GATE" "$T/plan.tfplan" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ]; then PASS=$((PASS+1)); printf '  ok    %-58s exit %s\n' "$v refused" "$rc"
  else FAIL=$((FAIL+1)); printf '  FAIL  %-58s exit %s, expected 2\n' "$v refused" "$rc"; fi
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
