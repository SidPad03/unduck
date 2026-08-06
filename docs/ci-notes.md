# CI notes

## The 2026-08-06 "workflows never run" scare

For a few hours it looked like this repository could not run CI at all: pushes
and tags created no workflow runs, and the jobs that did get created sat queued
until GitHub cancelled them. Both `build.yml` and `release.yml` were briefly
replaced by a Linux-only "publish what the developer committed" workflow.

That was an overreaction to a platform outage. The pipeline was restored.

**It was a GitHub incident, not this repository.**

GitHub Actions was in a **major outage from 15:22 UTC on 2026-08-06**, reporting
workflow runs failing or delayed, GitHub-hosted runner capacity constraints, and
**webhook delivery delays**. Delayed webhook/event delivery is exactly what makes
a push land normally while no workflow run is ever created.

Every observation below was made between 18:03 and 19:30 UTC that day — entirely
inside the outage window. Treat the conclusions as "what a broken Actions
backplane looks like", not as a property of this repo.

### What was observed

- Pushes to `main` and a `v*` tag created **zero** workflow runs.
- A workflow with no filters at all, on a Linux runner, also created zero runs:

  ```yaml
  name: Ping
  on: push
  jobs:
    ping:
      runs-on: ubuntu-latest
      steps:
        - run: echo ok
  ```

- `workflow_dispatch` reliably created runs.
- Runner assignment was erratic: `macos-26` jobs sat unassigned 10+ minutes and
  were cancelled outright twice; later an `ubuntu-latest` job did the same.

### What was ruled out at the time

| Checked | Result |
| --- | --- |
| `repos/:owner/:repo/actions/permissions` | `enabled=true`, `allowed_actions=all` |
| Workflow registration | all workflows `state=active`, correct paths |
| Repository rulesets | `0` |
| Token scopes | includes `repo` and `workflow` |
| Push actually reached GitHub | yes — commits and tags confirmed on the remote |
| Push attribution | `PushEvent` recorded with `actor=SidPad03`, a real user |
| Repo visibility | public, not a fork, default branch `main` |
| Disable + re-enable Actions via API | no change (settings restored afterwards) |

None of these were the cause.

### If it happens again

1. Check <https://www.githubstatus.com> first. It would have explained all of the
   above in one step.
2. If Actions is green and pushes still do not trigger, then look at repository
   **Settings → Actions → General** and account
   <https://github.com/settings/actions>.

### The pipeline itself was never broken

Worth recording, because it is easy to misread the outage as a code problem:
during the same window, `release.yml` ran **green end to end** on `macos-26` —
`swift build -c release`, icon generation, `.app`, `.pkg`, DMG creation, and the
GitHub Release with both assets attached. `build.yml` also completed
successfully once it got a runner. Everything that actually executed, worked.

Only scheduling was affected: two `macos-26` jobs and later an `ubuntu-latest`
job sat unassigned for 10+ minutes, and GitHub cancelled some of them outright.
A cancelled job reports `conclusion: cancelled` with **no steps and an empty
failure log** — which reads like a failure but means the job never started.

### If workflows stop running again

1. Check <https://www.githubstatus.com> **first**. It would have explained all of
   the above in one step.
2. Only if Actions is green: repository **Settings → Actions → General**, then
   account <https://github.com/settings/actions>.
3. Distinguish "cancelled with no steps" (never got a runner) from a real step
   failure before changing anything.

Resist restructuring the pipeline around a platform incident.
