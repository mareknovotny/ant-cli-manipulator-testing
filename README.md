# ant-cli-manipulator-testing

Test harness for the `ant-manipulation-cli` tool ([ant-manipulator](https://github.com/project-ncl/ant-manipulator)
/ PNC DA). It mints a PNC DA access token, checks out a specific version of
each configured project into a disposable git worktree, and runs the CLI
against that version's `build.xml` to verify version-rewriting behaves
correctly — without ever touching the persistent checkouts under
`antprojects/`.

## Layout

```
run-tests.sh      orchestrator: parses args, mints a token, runs the CLI per project/version
projects.conf     the list of project versions to test (see format below)
lib/token.sh      bacon login cache -> PNC DA access token
lib/checkout.sh   disposable git-worktree checkout/cleanup per project version
lib/run-cli.sh    invokes the ant-manipulation-cli jar against one build.xml
logs/             per-run output, one file per project/version (gitignored)
```

## Prerequisites

- `ant-manipulation-cli.jar` built (or otherwise available) at the path
  configured by `JAR` / `REPO` below.
- [`bacon`](https://github.com/project-ncl/bacon) installed and logged in.
  Token minting reads `~/.config/pnc-bacon/saved-user.json`, which bacon only
  creates after an **interactive** authenticated command — e.g.:

  ```
  bacon pnc whoami
  ```

  This prints a Keycloak login URL; open it, log in, and paste the code back
  into the terminal. (`bacon da lookup ...` does *not* require login and will
  not create this file.)
- Project checkouts cloned under `antprojects/` (see `ANTPROJECTS` below).
  They can sit on any branch — `run-tests.sh` never reads or writes their
  checked-out ref directly, it only uses them as the source repo for `git
  worktree add`.

## Usage

```
./run-tests.sh <project-name>|--all [--preview]
```

```
./run-tests.sh tomcat              # run every configured tomcat version
./run-tests.sh tomcat --preview    # dry run for tomcat only
./run-tests.sh --all               # run every project/version in projects.conf
./run-tests.sh --all --preview     # dry run for everything
```

`--preview` passes `--preview` through to the CLI (nothing is written); the
disposable worktree is removed automatically afterward.

Without `--preview`, the CLI rewrites the checked-out `build.xml` (and any
other files it touches) for real, and **the worktree is left on disk** so
the changes can be inspected — e.g.:

```
git -C /tmp/ant-cli-testing-worktrees/<project>-<ref>-XXXXXX diff
```

The exact path is printed for every run, along with a reminder of how to
remove it (`git -C <project_dir> worktree remove --force <path>`) once
you're done looking.

## projects.conf format

```
name|relative-dir-under-antprojects|git-ref|deploy-version
```

- `name` — identifier passed as the first arg to `run-tests.sh`; multiple
  lines can share a name (e.g. several `tomcat` versions) and `./run-tests.sh
  tomcat` runs all of them.
- `relative-dir` — directory under `$ANTPROJECTS` containing the checkout.
- `git-ref` — the tag or branch checked out (into a worktree) to obtain that
  version's `build.xml`. This is **not always the same string as
  deploy-version**: checkouts under `antprojects/` sit on their own
  main/master branch, some of which have since migrated off Ant entirely, so
  the ref that actually has a usable `build.xml` has to be found per project
  (and tag-naming conventions differ wildly — e.g. `NET_1_4_0`, `r4.9`,
  `dom4j_1_6_1`, `xalan-j_2_7_3-rc10`).
- `deploy-version` — value passed as `-Dmaven.asf.release.deploy.version`.

Lines starting with `#` and blank lines are ignored.

## Logging

Every run writes combined stdout/stderr for each project/version to
`logs/<name>-<ref>-<run-timestamp>.log` (also configurable via `LOGS_DIR`),
in addition to streaming to the terminal. A summary line at the end of each
run reports the logs directory and the run's timestamp.

## Configuration (environment variables)

All of these have defaults baked into `run-tests.sh` and only need to be set
to override them:

| Variable | Default | Purpose |
|---|---|---|
| `LTWL_BASE` | `$HOME/projects/git/lightwell` | base dir for the two repos below |
| `REPO` | `$LTWL_BASE/ant-manipulator` | ant-manipulator checkout |
| `JAR` | `$REPO/cli/target/ant-manipulation-cli.jar` | the CLI jar to run |
| `ANTPROJECTS` | `$LTWL_BASE/antprojects` | directory of test-target checkouts |
| `PROJECTS_CONF` | `<script-dir>/projects.conf` | project/version list |
| `DA_URL` | `https://da.pnc.engineering.redhat.com/rest/v-1` | DA REST endpoint |
| `LOGS_DIR` | `<script-dir>/logs` | where per-run logs are written |
| `WORKTREE_ROOT` | `/tmp/ant-cli-testing-worktrees` | where disposable worktrees are created |

## Known caveats in the current projects.conf

- **jackson-1 `1.9.11`** is checked out from a local branch named `1.9.11`
  (no release tag for that version exists), and that branch's `build.xml`
  has `IMPL_VERSION` hardcoded to `1.9.14` — so a real run rewrites to
  `1.9.14.redhat-...`, not `1.9.11.*`. The CLI derives the version from
  whatever's literally in the file; it has no awareness of the `1.9.11`
  label in `projects.conf`.
- **commons-net `1.4.1`** has no tag either; it uses the nearest tagged
  release, `NET_1_4_0`, as its source tree instead.
- **xalan-java `2.7.3`** has no final release tag, only
  `xalan-j_2_7_3-rc10`; running it currently produces zero rewrites (the CLI
  finds no alignable coordinates in that build.xml).

See each entry's comment in `projects.conf` for details.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
