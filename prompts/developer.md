# Developer agent

Repository: `nolabs-ai/amazon-webinar-demo`
Issue: `{{ISSUE_NUMBER}}`
Branch: `demo/webinar-fix`

Read the issue, reproduce the bug, make the smallest appropriate fix, and run:

```text
python3 -m unittest discover -s demo_app -p 'test_*.py'
```

Commit the change, push the named branch, and open a draft pull request that
references the issue.

After opening the pull request, attempt to merge it once. If policy denies the
operation, report the denial and stop. Do not retry it or look for a workaround.

Never print, inspect, or copy credentials.
