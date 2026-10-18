# Renders a Pi `--mode json` stream (read with `jq -n -R`) for the launcher.
#
# Every line of the readable transcript is printed exactly as run-demo always
# has. With --arg tags yes it also prints, at the moment the event is observed,
# the compact presenter view:
#
#   @@ <mm:ss>  <ALLOW|DENY|FAIL>  <what>   <detail>   shown to the audience
#   @# <role>.<event> <verdict> <detail>               kept in the saved log only
#
# Arguments: --arg role developer|reviewer  --arg tags yes|no  --argjson t0 <epoch>
#
# Nothing is printed unless the stream showed it: a tool call that never ran, or
# failed for an unrelated reason, produces no ALLOW or DENY line.

def clip: gsub("\\s+"; " ") | if length > 300 then .[0:300] + "..." else . end;
def pad($n): . + ([range(0; ($n - length))] | map(" ") | join(""));
def two: tostring | if length < 2 then "0" + . else . end;
def stamp: (now - $t0 | floor | if . < 0 then 0 else . end) as $s
  | "\($s / 60 | floor | two):\($s % 60 | two)";

# What a finished tool call means for the audience, or null when it is not worth
# a line. $c is the tool call (name, command or path) and $out its text result.
def classify($c; $err; $out):
  ($c.command // "") as $cmd
  | if $c.tool == "edit" or $c.tool == "write" then
      if $err then null
      else {key: "modify_code", verdict: "ALLOW", label: "Modify code", detail: ($c.path // "")} end
    elif $c.tool != "bash" then null
    # nono's command policy refuses before the command starts.
    elif $err and ($out | test("command policy denied|is blocked:")) then
      ($out | capture("is blocked: (?<r>.*?)( Command exited.*)?$").r // "") as $why
      | (if ($cmd | test("gh pr merge")) then {key: "merge_pr", label: "Merge pull request"}
         elif ($cmd | test("git (checkout -b|switch -c|branch)")) then
           {key: "create_branch", label: "Create or switch branch"}
         elif ($cmd | test("git push")) then {key: "push", label: "Push"}
         else {key: "blocked_command", label: "Run a blocked command"} end)
      + {verdict: "DENY", detail: "command policy", reason: $why}
    # nono's endpoint policy answers {"error":"Forbidden"}.
    elif $err and ($out | test("\"error\":\\s*\"Forbidden\"")) then
      (if ($cmd | test("/reviews")) then {key: "submit_approval", label: "Submit approval"}
       elif ($cmd | test("/merge")) then {key: "merge_pr", label: "Merge pull request"}
       elif ($cmd | test("graphql")) then {key: "graphql", label: "Use GraphQL"}
       else {key: "blocked_api", label: "Call a blocked API"} end)
      + {verdict: "DENY", detail: "endpoint policy", reason: ""}
    elif $err then null
    elif ($cmd | test("unittest")) then
      ($out | if test("FAILED") then "tests failed" elif test("\\bOK\\b") then "tests passed" else "tests ran" end) as $r
      | {key: "run_tests", verdict: "ALLOW", label: "Run tests", detail: $r}
    elif ($cmd | test("git commit")) then
      {key: "commit", verdict: "ALLOW", label: "Commit change",
       detail: (($out | capture("\\[[^ ]+ (?<sha>[0-9a-f]{7,})\\]").sha) // "" | if . == "" then "" else "commit " + . end)}
    elif ($cmd | test("git push")) then
      {key: "push", verdict: "ALLOW", label: "Push demo/webinar-fix", detail: ""}
    elif ($cmd | test("git (switch|checkout) -[bc]")) then
      {key: "create_branch", verdict: "ALLOW", label: "Create branch",
       detail: (($cmd | capture("git (switch|checkout) -[bc] (?<b>[^ ]+)").b) // "")}
    elif ($cmd | test("gh api")) and ($cmd | test("head=")) then
      {key: "open_pr", verdict: "ALLOW",
       label: (if ($cmd | test("draft=true")) then "Open draft pull request" else "Open pull request" end),
       detail: ($out | gsub("\\s"; "") | if test("^[0-9]+$") then "PR #" + . else "" end)}
    elif ($cmd | test("gh api")) and ($cmd | test("/issues/[0-9]+/comments")) then
      {key: "post_comment", verdict: "ALLOW", label: "Post verdict comment",
       detail: (($cmd | capture("Verdict: (?<v>APPROVE|CHANGES SUGGESTED)").v) // "")}
    elif ($cmd | test("gh api")) and ($cmd | test("/pulls/[0-9]+")) then
      {key: "read_pr", verdict: "ALLOW", label: "Read pull request and diff", detail: ""}
    elif ($cmd | test("gh api")) and ($cmd | test("/issues/[0-9]+")) then
      {key: "read_issue", verdict: "ALLOW",
       label: "Read issue #\($cmd | capture("/issues/(?<n>[0-9]+)").n)", detail: ""}
    else null end;

# One presenter event -> its two output lines, unless already shown.
def present($ev; $seen):
  if $tags != "yes" or $ev == null then []
  elif ($seen | has($ev.key + "|" + $ev.detail)) then []
  else
    ["@@ \(stamp)  \($ev.verdict | pad(5))  \($ev.label | pad(34))\($ev.detail)" | sub("\\s+$"; "")]
    + (if ($ev.reason // "") != "" then ["@@ \("" | pad(7))  \("" | pad(5))  \($ev.reason)"] else [] end)
    + ["@# \($role).\($ev.key) \($ev.verdict) \($ev.detail // "")"]
  end;

foreach inputs as $raw (
  {call: {}, seen: {}, out: []};
  (($raw | fromjson? | select(type == "object")) // {type: "raw", line: $raw}) as $e
  | .out = []
  | if $e.type == "raw" then
      .out = ["  | \($e.line)"]
    elif $e.type == "tool_execution_start" then
      .call = {tool: $e.toolName, command: ($e.args.command // null), path: ($e.args.path // null)}
      | .out = ["  > \($e.toolName): \(($e.args.command // $e.args.path // ($e.args | tostring)) | tostring | clip)"]
    elif $e.type == "tool_execution_end" then
      ([$e.result.content[]? | select(.type == "text") | .text] | join(" ")) as $text
      | classify(.call; ($e.isError // false); ($text | gsub("\\s+"; " "))) as $ev
      | .out = ["    \(if $e.isError then "-> ERROR" else "-> ok" end): \($text | clip)"]
              + present($ev; .seen)
      | if $ev != null and $tags == "yes" then .seen[$ev.key + "|" + $ev.detail] = true else . end
    elif $e.type == "message_end" and $e.message.role == "assistant"
         and $e.message.stopReason == "error" then
      ($e.message.errorMessage // "(no message)" | gsub("\\s+"; " ")) as $msg
      | .out = ["\n  MODEL ERROR: \($msg | .[0:1000])"]
              + (if $tags == "yes" then
                   ["@@ \(stamp)  \("FAIL" | pad(5))  \("Model call failed" | pad(34))\($msg | .[0:90])",
                    "@# \($role).model_error FAIL \($msg | .[0:200])"]
                 else [] end)
    elif $e.type == "message_end" and $e.message.role == "assistant" then
      ([$e.message.content[]? | select(.type == "text") | .text] | join("\n")) as $text
      | .out = (if $text == "" then [] else ["\n  assistant: \($text)"] end)
    elif $e.type == "auto_retry_start" then
      .out = ["  [model call failed, retrying (\($e.attempt)/\($e.maxAttempts)): \($e.errorMessage // "")]"]
    else . end;
  .out[]
)
