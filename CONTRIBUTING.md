# Contributing

## Before you open a pull request

```bash
make verify
```

That runs everything CI runs: `helm lint`, eleven value combinations rendered
and parsed, the documented defaults asserted, and the markdown links checked.
It takes a few seconds and it catches most of what has gone wrong in this
repository.

If you changed a Dockerfile, also build the services you touched:

```bash
docker build -t test:local ./cart
```

Nine of the ten build. `ratings` cannot, for reasons in
[docs/building.md](docs/building.md) -- that is not your fault and not a
regression.

## What CI enforces, and why

The workflow in `.github/workflows/chart.yml` is deliberately narrow. Each
check corresponds to a mistake that actually happened here.

| Check | The mistake it prevents |
|---|---|
| duplicate key check on `values.yaml` | A duplicated top-level `web:` resolved silently to the last value, rendering the web Service with no `spec.type`. YAML does not warn; the file still looked right. |
| eleven renders, each parsed | The rabbitmq readiness probe landed between two `containerPort` entries, producing output that did not parse. |
| six inputs the schema must reject | A schema that accepts everything provides no protection and looks like it does. |
| documented defaults asserted | The README and docs/probes.md quote specific numbers. If a change alters them, the documentation has become fiction. |
| exec-form `CMD` grep | `CMD ['dispatch']` is shell form. The container exited with `/bin/sh: 1: [dispatch]: not found` and crashlooped. |
| `.dockerignore` present per service | A stray `node_modules` or `target/` in a context makes the image non-reproducible. |
| shellcheck on `build-push.sh` | — |

CI does not build or push images. That needs ECR credentials, which should not
be available to a pull request, and `ratings` would fail regardless.

## Conventions worth knowing

**Naming.** The chart builds images as `{{ .Values.image.repo }}/rs-<service>`.
The suffix is not always the directory name: `mysql/` publishes as
`rs-mysql-db` and `mongo/` publishes as `rs-mongodb`. `scripts/build-push.sh`
encodes that mapping. A repository named `robot-shop/cart` pushes fine and then
fails at runtime with `ImagePullBackOff`.

**Probes.** Each probe path must be verified in the service source or by running
it against the real base image. A probe that always succeeds is worse than no
probe. `docs/probes.md` records how each one was checked, including the
`mysqladmin` behaviour that makes an unauthenticated probe useless.

**Liveness stays off.** Do not add a default `livenessProbe`. On a
memory-constrained node it converts a slow service into a restart loop. See
[docs/probes.md](docs/probes.md).

**Scheduling features are opt-in.** `topologySpreadConstraints`, `antiAffinity`
and `podDisruptionBudgets` are all empty by default. They change scheduling for
anyone who upgrades, so they ship disabled with a documented example.

**Resources belong in `values.yaml`.** Not hardcoded in templates. See the
`mysql` and `shipping` entries for the pattern, and why the JVM flags in
`shipping/Dockerfile` have to agree with the chart's memory limit.

**Do not use `PodSecurityPolicy`.** Removed in Kubernetes 1.25. The four
templates that once rendered `policy/v1beta1` were deleted rather than disabled.
Use `PodSecurityAdmission` for real admission control.

## Commit messages

Say what changed and why, and what you verified. The existing history is the
reference: each entry names the failure mode it prevents, and the measurements
that justify the choice. For example, the shipping JVM flags were not guessed --
the two candidate configurations were run under a 300Mi cgroup limit and
settled at 270Mi and 214Mi, and the second was chosen.

If a change fixes something, include the error message you saw. Several entries
here are only findable because the real text was pasted in.

## Documentation is part of the change

If you change behaviour, update the document that describes it in the same
commit. Most of the value in this repository is that the docs describe what
actually happened, including the parts that did not work. A commit that fixes
a bug and leaves the doc recommending the old workaround makes the repository
worse, not better -- that happened once here and was corrected separately.

`./scripts/check-links.py` runs as part of `make verify`, so a renamed document
fails CI rather than leaving a dead link behind.
