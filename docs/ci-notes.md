# CI notes

## Why releases are triggered through the API

`scripts/publish.sh` invokes `publish.yml` with `gh workflow run` instead of
relying on the push trigger. That was a workaround for symptoms observed on
2026-08-06, and it is kept because it is deterministic — but the diagnosis below
matters if you are wondering whether something is wrong with the repository.

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

### The push trigger is already wired up

`publish.yml` carries:

```yaml
on:
  push:
    branches: [main]
    paths: ["VERSION"]
```

So pushing a `VERSION` bump publishes automatically whenever Actions is healthy.
`publish.sh` calling the workflow explicitly is belt-and-braces: it also means
`publish.sh` can watch the run and report failure, which a bare push cannot.

## Why there is no build pipeline

There was one briefly — `swift build` plus packaging on `macos-26` — and it ran
green. It was removed deliberately, not because it failed:

- The app must be built on macOS anyway (the Apple frameworks are only in the
  macOS SDK), so CI compiling it duplicates what the developer already does.
- macOS runners are the slowest and scarcest tier.
- The build that ships is then the one that was actually tested locally, rather
  than a second, separately-produced binary.

`publish.yml` therefore runs on Linux and never compiles: it tags the commit and
uploads whatever installers are committed under `releases/`. The `pre-push` hook
in `.githooks/` is what keeps that folder honest.
