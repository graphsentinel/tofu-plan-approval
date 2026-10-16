# Pre-apply check for an approved OpenTofu saved plan (the comparison; gate/plan-drift-gate.sh runs it).
#
#   jq -n --slurpfile r reviewed.json --slurpfile f refresh.json [--argjson strict true] -f gate/planned-drift.jq
#
#   reviewed.json  `tofu show -json` of the saved plan that was reviewed and approved
#   refresh.json   `tofu show -json` of a refresh-only saved plan made right before the apply, with the same
#                  variables (its prior_state holds the values read from the live infrastructure)
#
# Question: at every path the reviewed plan changes, is the live value still the value recorded in the approved
# plan (change.before)? Only those paths count; differences elsewhere are reported (strict: they block too).
#   update          the leaf paths whose value differs between before and after (compared exactly), plus every path
#                   unknown until apply; an update with no such path checks the whole resource. A path through a
#                   list with more than one element stops at the list: the whole list is compared, so a reordering
#                   cannot move the change onto another element unnoticed.
#   create          the whole resource: there was nothing there, and the refreshed state must still have nothing
#   delete, replace the whole resource, which must still be in the refreshed state
#   no-op, data sources (read): not checked
# The comparison treats an empty map or list as equal to null (providers store some empty attributes as null and
# read them back as {} or []); nothing else is normalised. An updated, deleted or replaced resource missing from the
# refreshed state is a conflict, and so is a container above a planned path that changed kind (a map that became
# null, a key that disappeared). Reported, never blocking unless --strict: drift that is not at or below a planned
# path (unplanned_drift for the plan's resources, drift_outside_plan for other resources); drift above a planned path,
# such as a whole map replaced around a planned key, is in unplanned_drift too.
#
# Not checked: the inputs the plan was computed from (data sources, other resources, variables beyond equality of
# the two documents' variables), objects outside the state (a create does not prove the name is free remotely),
# values a provider does not read back (write-only, ephemeral), and anything between this check and the apply.
#
# Fails closed (jq error -> gate/plan-drift-gate.sh exit 2): unreadable, empty, errored or unsupported documents;
# different variables in the two plans; imports, moves, deposed objects and actions this check does not know.
# The report holds addresses and paths, never values (values may be sensitive).

def norm: walk(if . == {} or . == [] then null else . end);

# leaf paths where a and b differ; a path ends early where the two sides have different types, and at a map key or
# list element present on one side only (a key holding null is not the same as no key)
def diffpaths(a; b):
  if a == b then empty
  elif (a | type) == "object" and (b | type) == "object" then
    ((a | keys) + (b | keys) | unique[]) as $k
    | if (a | has($k)) and (b | has($k)) then [$k] + diffpaths(a[$k]; b[$k]) else [$k] end
  elif (a | type) == "array" and (b | type) == "array" then
    range(0; [(a | length), (b | length)] | max) as $i
    | if $i < (a | length) and $i < (b | length) then [$i] + diffpaths(a[$i]; b[$i]) else [$i] end
  else [] end;

# the value at a path, wrapped: {v: value}, or {missing: true} when a map key or list element on the way does not
# exist (so a key holding null is distinct from no key, and neither can equal a real value)
def at($p): . as $x
  | reduce $p[] as $s ({v: $x};
      if has("missing") then .
      elif (.v | type) == "object" and ($s | type) == "string" and (.v | has($s)) then {v: .v[$s]}
      elif (.v | type) == "array" and ($s | type) == "number" and $s >= 0 and $s < (.v | length) then {v: .v[$s]}
      else {missing: true} end);
# the kind of value at a path, for comparing the containers above a planned path: "missing", or the type after
# normalisation (an empty map or list is "null")
def shape($q): at($q) | if has("missing") then "missing" else (.v | norm | type) end;
def under($p; $d): ($d | length) >= ($p | length) and $d[0:($p | length)] == $p;
def overlaps($p; $q): ([($p | length), ($q | length)] | min) as $n | $p[0:$n] == $q[0:$n];
# a path stops at the first list that has more than one element (or differs in type) on either side
def guard($p; $b; $n):
  first( (range(0; $p | length) as $k
          | select(($p[$k] | type) == "number")
          | ($b | at($p[0:$k]).v) as $x | ($n | at($p[0:$k]).v) as $y
          | select((($x | type) == "array" and ($x | length) > 1) or (($y | type) == "array" and ($y | length) > 1)
                   or (($x | type) != ($y | type)))
          | $p[0:$k]), $p );
def pstr: if length == 0 then "(whole resource)"
          else map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") | ltrimstr(".") end;
def need(cond; msg): if cond then . else error(msg) end;
def major: tostring | split(".")[0];

def managed_values:
  [ (.prior_state.values.root_module // {}) | recurse(.child_modules[]?) | .resources[]?
    | select(.mode == "managed" and (has("deposed_key") | not)) | {key: .address, value: .values} ] | from_entries;

def planned_paths($c):
  ($c.change.actions) as $a
  | if $a == ["update"] then
      ( [ diffpaths($c.change.before; $c.change.after) ]
        + (if $c.change.after_unknown == true then [[]]
           else [ $c.change.after_unknown // {} | paths(. == true) ] end)
        | unique ) as $p
      | if $p == [] then [[]] else $p end
    elif $a == ["create"] or $a == ["delete"] or $a == ["delete", "create"] or $a == ["create", "delete"] then [[]]
    else error("unsupported action \($a) at \($c.address)") end;

need(($r | length) == 1 and ($f | length) == 1; "plan JSON missing or unreadable")
| $r[0] as $R | $f[0] as $F
| need(($R | type) == "object" and ($F | type) == "object"
       and ($R.format_version | type) == "string" and ($F.format_version | type) == "string"
       and ($R.format_version | major) == "1" and ($F.format_version | major) == "1"
       and ($R.configuration | type) == "object" and ($F.configuration | type) == "object"
       and ($R.terraform_version | type) == "string" and ($F.terraform_version | type) == "string"
       and ($R.planned_values | type) == "object" and ($F.planned_values | type) == "object"
       and (($R.resource_changes // []) | type) == "array"; "plan JSON missing, unreadable or of an unsupported format")
| need(($R.errored // false) == false and ($F.errored // false) == false; "errored plan")
| need(($F | has("prior_state")) or (($R | has("prior_state")) | not);
       "the refresh-only plan has no state although the reviewed plan had one")
| need(($R.variables // null) == ($F.variables // null);
       "the refresh-only plan was made with different variables than the reviewed plan")
| need(all($R.resource_changes // [] | .[];
           (.address | type) == "string" and (.mode == "managed" or .mode == "data")
           and (.change.actions | type) == "array");
       "malformed resource change")
| need(all($R.resource_changes // [] | .[]; .change.actions as $a
           | [["no-op"], ["read"], ["create"], ["update"], ["delete"], ["delete", "create"], ["create", "delete"]]
           | any(. == $a)); "an action this check does not know")
| need(all($R.resource_changes // [] | .[];
           (has("deposed") | not) and (has("previous_address") | not) and (.change.importing == null));
       "the plan imports, moves or replaces a deposed object: not supported, review and apply it separately")
| ($F | managed_values) as $live
| [ $R.resource_changes // [] | .[]
    | select(.mode == "managed" and .change.actions != ["no-op"])
    | . as $c
    | $c.change.before as $before
    | ($live | has($c.address)) as $present
    | $live[$c.address] as $now
    | [ planned_paths($c)[] | guard(.; $before; $now) ] | unique as $planned
    | { address: $c.address, actions: $c.change.actions, planned: $planned,
        conflicts: (
          if $c.change.actions == ["create"] then (if $present then [[]] else [] end)
          elif ($present | not) then [[]]
          else [ $planned[] as $p
                 | select((($before | at($p) | .v |= norm) != ($now | at($p) | .v |= norm))
                          or any(range(0; $p | length) as $k | $p[0:$k];
                                 . as $q | ($before | shape($q)) != ($now | shape($q))))
                 | $p ] end ),
        unplanned: [ diffpaths($before | norm; $now | norm) as $d
                     | select(any($planned[]; under(.; $d)) | not) | $d ] } ] as $checked
| ($checked | map(.address)) as $mine
| [ $checked[] | .address as $a | .conflicts[] | {address: $a, path: pstr, path_array: .} ] as $conflicts
| [ $checked[] | .address as $a | .unplanned[] | {address: $a, path: pstr, path_array: .} ] as $unplanned
| [ $F.resource_drift // [] | .[]
    | select(.mode == "managed") | select(.address as $x | $mine | any(.[]; . == $x) | not)
    | select((.change.before | norm) != (.change.after | norm)) | .address ] | unique as $outside
| { decision: (if $conflicts != [] or (($ARGS.named.strict // false) and ($unplanned != [] or $outside != []))
               then "block" else "apply" end),
    strict: ($ARGS.named.strict // false),
    conflicts: $conflicts,
    unplanned_drift: $unplanned,
    drift_outside_plan: $outside,
    checked: [ $checked[] | {address, actions, planned: (.planned | map(pstr))} ] }
