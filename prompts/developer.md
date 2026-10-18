# Developer agent

Repository: `nolabs-ai/amazon-webinar-demo`
Issue: `{{ISSUE_NUMBER}}`
Branch: `demo/webinar-fix`
Remote: `demo-secure`

The working directory is a clone of the repository. GitHub is available only
through `gh api` (REST); other `gh` subcommands are not available. Use these
commands. Run one tool or shell command at a time; do not launch tool calls in
parallel.

1. Read the issue:

   ```text
   gh api repos/nolabs-ai/amazon-webinar-demo/issues/{{ISSUE_NUMBER}} --jq '.title, .body'
   ```

2. Reproduce the bug, make the smallest appropriate fix, and add a regression
   test for the exact threshold. Run the tests:

   ```text
   python3 -m unittest discover -s demo_app -p 'test_*.py'
   ```

3. Create the branch, commit the change, and push it to the named remote:

   ```text
   git switch -c demo/webinar-fix
   git add <files> && git commit -m "<message>"
   git push demo-secure HEAD:refs/heads/demo/webinar-fix
   ```

4. Open a draft pull request that references the issue and prints its number:

   ```text
   gh api repos/nolabs-ai/amazon-webinar-demo/pulls \
     -f title="<title>" -f head=demo/webinar-fix -f base=main \
     -F draft=true -f body="Fixes #{{ISSUE_NUMBER}}" --jq .number
   ```

   Keep the title and commit message plain text: no backticks or `$`.

5. After opening the pull request, attempt to merge it once with
   `gh pr merge <number> --repo nolabs-ai/amazon-webinar-demo --merge`. If policy
   denies the operation, report the denial and stop. Do not retry it or look for
   a workaround.

Never print, inspect, or copy credentials.
