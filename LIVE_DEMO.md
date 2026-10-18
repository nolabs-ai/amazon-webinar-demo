# Running the demo live

How to run it. What to say and show around it is the presenter's choice
(`PRESENTER_GUIDE.md` has the facts and claims). Preparation is in `RUNBOOK.md`;
do not build, change credentials, scale nodes or debug the platform on air.

## Before

- `scripts/reset-demo.sh --repo MateSaary/webinar-demo-sandbox`
- `scripts/check-ready.sh` says READY.
- Terminal in the repository root; notifications, history and account IDs hidden.
- Backup recording and its PR within reach.

## Run

```text
scripts/run-webinar.sh
```

It starts the Job on the frozen image and prints a `[DEVELOPER]` section, a
`[REVIEWER]` section and a `[VERIFICATION]` block. Each line is an observed
`ALLOW` or `DENY` decision; the full transcript is saved to `artifacts/`.

## Success

- `[VERIFICATION]` shows three `PASS` lines (PR open and unmerged, reviewer
  comment added, credential files unreadable), then `DEMO COMPLETE`.
- On GitHub, a new draft PR exists from `demo/webinar-fix`, with the reviewer's
  comment, and it is not merged.

## If it fails

Do not debug on air. Play the recording and show the backup PR.

## After

- If the PR was merged, run the reset: it restores `main` so the next run finds
  the bug again.
- Pause per `RUNBOOK.md` (sections 7–8) once the PR is no longer needed.
