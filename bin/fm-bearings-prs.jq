# PR projection implementation for fm-bearings-snapshot.sh, whose header owns
# the contract. Inputs are canonical JSON, never another fleet-file parser.
($model[0]) as $model | ($scope[0]) as $scope | ($response[0]) as $response |
def github_identity:
  capture("^https://github[.]com/(?<owner>[A-Za-z0-9_.-]+)/(?<name>[A-Za-z0-9_.-]+)/pull/(?<number>[1-9][0-9]*)$")?;
def repo_of: .owner + "/" + .name;

if $mode == "scope" then
  . as $snapshot
  | ([ $model.landed[] | select(.pr_url != null)
       | {id,owner,project:.repo,url:.pr_url,priority:0,completed_at} ]
     + [ .recorded_prs[]
         | {id,owner:"(main)",project:.repo,url,priority:(.priority + 1),completed_at} ]
     + [ (.secondmate_current.records // [])[] as $home
         | $home.recorded_prs[]?
         | {id,owner:$home.id,project:.repo,url,priority:1,completed_at:null} ])
  | map(select(.url | type == "string") | . + {identity:(.url | github_identity)})
  | sort_by([.priority, .owner, .completed_at, .id])
  | unique_by(.url)
  | map(. + {repo:(.identity | repo_of),
      scope_age_seconds:(if .owner == "(main)" then 0 else
        .owner as $owner | ([$snapshot.secondmate_current.records[]?
          | select(.id == $owner) | .freshness.age_seconds][0] // null) end),
      scope_freshness:(if .owner == "(main)" then "fresh" else
        .owner as $owner | ([$snapshot.secondmate_current.records[]?
          | select(.id == $owner) | .freshness.status][0] // "unknown") end)})
  | group_by(.repo) as $groups
  | (if $all_repos == 1 then $groups else $groups[:$repo_limit] end) as $shown
  | {repos_total:($groups | length),repos_shown:($shown | length),
     total:($groups | map(length) | add // 0),
     rows:([$shown[] | group_by(.priority) | map(sort_by([.completed_at, .id]) | reverse) | add | .[:$pr_limit] | .[]]
       | to_entries | map(.value + {alias:("p" + (.key | tostring))}))}
elif $mode == "query" then
  "query { " + ([.rows[] |
    .alias + ": repository(owner:" + (.identity.owner | tojson) + ",name:" + (.identity.name | tojson)
    + ") { pullRequest(number:" + .identity.number + ") { url title state mergedAt updatedAt"
    + (if $include_prs == 1 then " isDraft reviewDecision mergeable commits(last:1) { nodes { commit { statusCheckRollup { state } } } }" else "" end)
    + " } }"] | join(" ")) + " }"
elif $mode == "result" then
  . as $snapshot
  | [$scope.rows[] as $row
      | (try $response.data[$row.alias].pullRequest catch null) as $pr
      | (try (any(($response.errors // [])[]; (.path // [])[0] == $row.alias or (.path // [] | length) == 0)) catch true) as $error
      | (try ($pr != null and $pr.url == $row.url and ($error | not)
         and ($pr.title | type == "string" and length > 0)
         and ([$pr.state] - ["OPEN","CLOSED","MERGED"] | length == 0)
         and (if $pr.state == "MERGED" then
                ($pr.mergedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
              else $pr.mergedAt == null end)) catch false) as $valid
      | {id:$row.id,owner:$row.owner,repo:$row.repo,project:$row.project,url:$row.url,
         title:(if $valid then $pr.title else null end),
         state:(if $valid then ($pr.state | ascii_downcase) else "unknown" end),
         merged_at:(if $valid then $pr.mergedAt else null end),
         observed_at:(if $valid then $now else null end),
         freshness:(if $valid then "fresh" else "unavailable" end),
         scope_freshness:$row.scope_freshness,
         scope_age_seconds:$row.scope_age_seconds,
         reason:(if $valid then null else $failure end),
         deployment:"unknown",
         review:(if $valid and $include_prs == 1 then ($pr.reviewDecision // "none") else "not_collected" end),
         mergeable:(if $valid and $include_prs == 1 then ($pr.mergeable // "UNKNOWN") else "not_collected" end),
         checks:(if $valid and $include_prs == 1 then
           ($pr.commits.nodes[0].commit.statusCheckRollup.state // "none")
           | if . == "SUCCESS" then "passing" elif . == "FAILURE" or . == "ERROR" then "failing"
             elif . == "PENDING" or . == "EXPECTED" then "pending" else "none" end
           else "not_collected" end)}] as $evidence
  | [$evidence[] | select(.state == "merged")] as $merged
  | ([ $snapshot.backlog.records[]
       | select(.structured and .kind == "program" and .state != "done")
       | . + {owner:"(main)",goal:.title,freshness:"fresh",age_seconds:0} ]
     + [ $snapshot.secondmate_current.records[]? as $home
         | $home.project_goals[]?
         | . + {owner:$home.id,freshness:$home.freshness.status,age_seconds:$home.freshness.age_seconds} ]) as $goals
  | ([$evidence[] | select(.freshness == "fresh")] | length) as $fresh
  | ($scope.total - ($scope.rows | length)) as $omitted
  | $model
  | .prs = (if $scope.total == 0 then "no recorded managed PRs"
            elif $fresh == 0 then "unavailable (" + $failure + ")"
            elif $fresh < $scope.total then "partial" else "fresh" end
            + "; \($fresh)/\($scope.total) recorded managed PRs observed; \($merged | length) confirmed merged")
  | .pr_evidence = $evidence
  | .merged_prs = ($merged | sort_by([.merged_at,.url]) | reverse)
  | .landed |= map(. as $landed
      | ([$evidence[] | select(.url == $landed.pr_url)][0] // null) as $pr
      | . + {state:(if .pr_url == null then "completed"
                     elif $pr.state == "merged" then "merged"
                     elif $pr.state == "open" or $pr.state == "closed" then $pr.state
                     elif .completion == "merged" then "recorded_merged" else "unverified" end),
             freshness:(if .pr_url == null then "recorded" else ($pr.freshness // "not_collected") end)}
      | if $pr.title != null then .what = $pr.title
        elif .pr_url != null then .what = "Recorded PR; title unavailable" else . end)
  | .project_progress = [
      $goals[:$goal_limit][]
      | . as $goal
      | {id,repo,goal,source:"structured-program",owner,freshness,age_seconds,
         dependencies:((.blocked_by_ids // []) | join(",")),
         pending:((.unresolved_blocker_ids // []) | join(",")),
         merged_prs:([$merged[] | select(.owner == $goal.owner)
           | .id as $id | select(($goal.blocked_by_ids // []) | index($id))] | length),
         deployment:"unknown"} ]
  | (if $include_prs == 1 then .candidate_prs = [$evidence[] | select(.state == "open")
       | {num:(.url | split("/")[-1]),task:.id,repo,url,title,review,mergeable,checks}] else . end)
  | .omitted += [
      (if $scope.repos_total > $scope.repos_shown then
         {surface:"PR repositories showing \($scope.repos_shown) of \($scope.repos_total)",reveal:"--all-pr-repos"} else empty end),
      (if $omitted > 0 then
         {surface:"managed PRs showing \($scope.rows | length) of \($scope.total)",reveal:"raise FM_BEARINGS_PR_LIMIT or use --all-pr-repos"} else empty end),
      (if any($evidence[]; .freshness != "fresh") then
         {surface:"PR truth unavailable for some recorded work",reveal:"retry the snapshot when GitHub is available"} else empty end),
      {surface:"PRs without structured links are outside the managed baseline",reveal:"record their PR URLs in the owning task"},
      ($snapshot.secondmate_current.records[]?
       | select(.recorded_prs == null or .project_goals == null)
       | {surface:("secondmate " + .id + " lacks current PR or goal fields"),reveal:"refresh the owning home ledger"}),
      ($snapshot.secondmate_current.records[]? as $home | $home.omitted[]?
       | select(.surface == "recorded_prs" or .surface == "project_goals")
       | {surface:("secondmate " + $home.id + " omitted \(.count) " + .surface),reveal:"raise the owning home ledger bound"}),
      (if ($goals | length) > $goal_limit then
         {surface:"project goals showing \($goal_limit) of \($goals | length)",reveal:"raise FM_BEARINGS_GATES"} else empty end),
      (if (.project_progress | length) == 0 then
         {surface:"project goal unavailable in structured program records",reveal:"record the project goal as a program with task dependencies"} else empty end)
    ]
else error("unknown PR projection mode") end
