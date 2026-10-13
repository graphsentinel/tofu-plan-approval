# Writes to ConfigMap $ns/$name in an audit log (jq -s, one event per line). Used by checks 08 and 12.
#
#   API call   a completed create/update/patch with an explicit 2xx status
#   dry run    an API call with dryRun=All in its query: it writes nothing
#   persisted  an API call that is not a dry run; its response carries the object's resourceVersion and uid
#   mutation   a persisted write whose data.value differs from the persisted value before it, in resourceVersion
#              order. The request body cannot tell: a server-side apply sends the new value, so request and
#              response are equal even when the field changed.
#
# Inconclusive, never guessed: a persisted write without a numeric resourceVersion or a uid (incomplete), more
# than one uid (the object was recreated), or equal resourceVersions written by different actors (ambiguous).
def actor: ((.user.username // "") + " " + (.impersonatedUser.username // ""));
[ .[] | select(.objectRef.resource == "configmaps" and .objectRef.namespace == $ns and .objectRef.name == $name
               and (.verb | test("^(create|update|patch)$")) and .stage == "ResponseComplete"
               and ((.responseStatus.code | type) == "number") and .responseStatus.code >= 200 and .responseStatus.code < 300)
      | { actor: actor, flux: (actor | test("kustomize-controller|flux")), verb,
          dry: ((.requestURI // "") | test("[?&]dryRun=All(&|$)")),
          rv: ((if (.responseObject | type) == "object" then .responseObject.metadata.resourceVersion else null end)
               | if . == null then null else (tonumber? // null) end),
          uid: (if (.responseObject | type) == "object" then .responseObject.metadata.uid else null end),
          val: (if (.responseObject | type) == "object" then (.responseObject.data.value? // null) else null end),
          t: (.stageTimestamp // "") } ] as $ev
| ([ $ev[] | select(.dry | not) ]) as $p
| ([ $p[] | select(.rv != null and .uid != null) ] | sort_by(.rv, .t) | group_by(.rv)) as $groups
| ([ range(1; $groups | length) as $i
     | { flux: $groups[$i][0].flux, actor: $groups[$i][0].actor,
         from: $groups[$i - 1][0].val, to: $groups[$i][0].val } | select(.from != .to) ]) as $mut
| { calls:            ([ $ev[] | select(.verb != "create") ] | length),
    flux_calls:       ([ $ev[] | select(.flux and .verb != "create") ] | length),
    flux_dry_runs:    ([ $ev[] | select(.flux and .dry) ] | length),
    flux_writes:      ([ $p[]  | select(.flux and .verb != "create") ] | length),
    mutations:        ($mut | length),
    flux_mutations:   ([ $mut[] | select(.flux) ] | length),
    flux_transitions: ([ $mut[] | select(.flux) | "\(.from)->\(.to)" ] | join(",")),
    incomplete:       ([ $p[] | select(.rv == null or .uid == null) ] | length),
    ambiguous:        ([ $groups[] | select(([ .[].actor ] | unique | length) > 1 or ([ .[].val ] | unique | length) > 1) ] | length),
    uids:             ([ $p[] | .uid | select(. != null) ] | unique) }
