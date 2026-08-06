# CI notes

## Push events do not trigger workflow runs on this repository

Observed 2026-08-06. `workflow_dispatch` and `repository_dispatch` create runs
normally. Pushes create none — not to branches, not to tags.

This is why releases are published through `scripts/publish.sh` (which calls the
workflow via the API) rather than by simply pushing a tag.

### It is not a workflow-configuration problem

The reproduction is a workflow with no filters at all, on a Linux runner, so
neither branch/path filters nor macOS runner capacity are involved:

```yaml
name: Ping
on: push
jobs:
  ping:
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
```

Committed and pushed to `main`. Result: **zero** workflow runs created, polled
over two minutes. The same repository ran `workflow_dispatch` jobs to completion
before and after.

### Ruled out

| Checked | Result |
| --- | --- |
| `repos/:owner/:repo/actions/permissions` | `enabled=true`, `allowed_actions=all` |
| Workflow registration | all workflows `state=active`, correct paths |
| Repository rulesets | `0` |
| Token scopes | includes `repo` and `workflow` |
| Push actually reached GitHub | yes — commits and tags confirmed on the remote |
| Push attribution | `PushEvent` recorded with `actor=SidPad03`, a real user |
| Repo visibility | public, not a fork, default branch `main` |
| Disable + re-enable Actions via API | no change |

### Where to look next

The remaining candidates are settings the REST API does not expose:

- Repository **Settings → Actions → General**
- Account **https://github.com/settings/actions**

If both look correct, this is worth a GitHub Support ticket — the `Ping`
workflow above is a minimal, self-contained reproduction.

### When it starts working

`publish.yml` already carries the right trigger:

```yaml
on:
  push:
    branches: [main]
    paths: ["VERSION"]
```

It is inert today and becomes the automatic path the moment push events fire
again. Nothing needs to change.

## Why there is no build pipeline

There was one briefly (`swift build` + packaging on `macos-26`) and it worked —
but macOS runners queued badly, twice sitting unassigned for 10+ minutes before
GitHub cancelled the job outright. Since the app has to be built on a Mac anyway,
it is simpler to build locally and let CI do only the part that needs GitHub:
tagging and publishing. `publish.yml` therefore runs on Linux and never compiles.
