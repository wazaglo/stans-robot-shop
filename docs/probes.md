# Probes

What each service exposes, how it was verified, and why liveness is off by
default.

Every endpoint in the table below was read out of the service source and, for
the exec probes, executed against the real base image. Nothing is inferred
from convention.

## What is enabled by default

Readiness probes on seven of twelve workloads:

| Service | Probe | Path / command | Source of truth |
|---|---|---|---|
| cart | httpGet | `/health` :8080 | `cart/server.js` |
| catalogue | httpGet | `/health` :8080 | `catalogue/server.js` |
| user | httpGet | `/health` :8080 | `user/server.js` |
| shipping | httpGet | `/health` :8080 | `shipping/src/.../Controller.java:57` |
| ratings | httpGet | `/_health` :80 | `ratings/html/src/Controller/HealthController.php:16` |
| mongodb | exec | `mongo --quiet --eval db.adminCommand({ping:1}).ok` | tested on `mongo:5` |
| mysql | exec | `mysqladmin ping -h 127.0.0.1 -u shipping -psecret` | tested on `mysql:5.7` |

Five are HTTP against a service source file, two are exec against a real base
image.

**No liveness probe is enabled on any workload.** See below for why.

## Services with no probe, and why

| Service | Reason |
|---|---|
| dispatch | Pure RabbitMQ consumer. No `net.Listen`, no `ListenAndServe`, no HTTP handler in `main.go`, so there is no port to probe. An HTTP or `tcpSocket` probe would fail forever. It also does not need one: the process either holds a channel or it has exited, and the kubelet restarts an exited container without any probe. |
| redis | Opt-in. `redis-cli ping` returns PONG, exit 0 -- verified. Left off because nothing gates on it and an exec probe every few seconds is overhead on a small node. Uncomment in `values.yaml` to enable. |
| rabbitmq | Opt-in, same reasoning. `rabbitmq-diagnostics -q ping` prints "Ping succeeded", exit 0 -- verified. Needs ~10s to start, so the commented values use `initialDelaySeconds: 15`. |
| web | The ALB already health-checks this one. `target-type: ip` means the ALB registers pod IPs and only routes to ready ones, so a second probe would duplicate that. nginx also fails to start at all if it cannot resolve its upstreams, so a hung-but-serving web pod is not the failure mode to worry about. |
| payment | Verified endpoint, template not wired. `payment/payment.py:40` has `@app.route('/health', methods=['GET'])` returning `OK`, so the probe is straightforward -- but `payment-deployment.yaml` has **no `readinessProbe` guard**, so setting the value does nothing today. Adding it is the same three lines used by the other services. Left alone here to keep this change to documentation. |
| load-gen | Not deployed by this chart. |

## Readiness, not liveness

A readiness probe removes a pod from the Service's endpoints when it fails.
Traffic stops. The container keeps running.

That is the correct response to a service being briefly slow or waiting on a
dependency. `ratings` was observed sitting at `0/1` for several minutes during
the build while MySQL ran its init scripts, then flipping to `1/1` on its own
once MySQL was up. A short failure window would have made that look like a
crash loop.

## Why liveness is off by default

A liveness probe **kills the container** when it fails.

On a node where memory is the binding constraint, that is the wrong response.
The service is slow because the node is out of memory. The liveness probe kills
the container, the kubelet restarts it, it allocates against the same
constrained node, and the cycle repeats. The service is now restarting
instead of slow, and the cluster is worse off than before the probe existed.

This is not hypothetical. During the build of this project, 12 services on
4 `t3.micro` nodes drove nodes to 92-99% memory, kubelets stopped posting
status, all four nodes went `NodeStatusUnknown`, and the storefront returned
503. See [troubleshooting.md #8](troubleshooting.md#8-whole-cluster-went-notready-under-full-load).
A liveness probe in that situation would have restarted containers on a node
that had no memory to give them.

A liveness probe is a claim that the process is wedged *and cannot recover*. It
is worth making only with measurements of a specific service under real
pressure, and then with a wide window.

### If you add one

```yaml
cart:
  livenessProbe:
    httpGet:
      path: /health
      port: 8080
    initialDelaySeconds: 30
    periodSeconds: 10
    failureThreshold: 6      # ~60s of continuous failure before restart
```

`periodSeconds` x `failureThreshold` is the real number that matters: 10 x 6
means 60 seconds of *continuous* failure. A GC pause, a slow DNS response, or a
momentary node stall will not reach it. Keep it above 60 seconds. Restarting a
service that was merely slow costs more than the outage it prevents.

## The mysql probe credentials

The mysql exec probe restates `MYSQL_USER` and `MYSQL_PASSWORD` from
`mysql/Dockerfile` in `values.yaml`. Those values therefore appear in the pod
spec, where anyone with read access to the Deployment can see them.

That is acceptable for a demo whose credentials are already baked into a public
image, and the coupling is documented in `values.yaml` so it is not a silent
trap. For anything real, define a Secret and reference it:

```yaml
mysql:
  readinessProbe:
    exec:
      command:
        - sh
        - -c
        - mysqladmin ping -h 127.0.0.1 -u "$MYSQL_USER" -p"$MYSQL_PASSWORD"
```

with the credentials supplied by a `Secret` and the Deployment reading them
from `secretKeyRef`.

## Why mysqladmin ping needs credentials

`mysqladmin` treats an authentication failure as "the server is alive", which
is defensible for liveness and useless for readiness. Measured on `mysql:5.7`:

| Case | Output | Exit |
|---|---|---|
| `mysqladmin ping` (no credentials) | `error: 'Access denied for user 'root'@'127.0.0.1'` | **0** |
| `mysqladmin ping -u nope -pwrong` | `error: 'Access denied for user 'nope'@'127.0.0.1'` | **0** |
| `mysqladmin ping -u shipping -psecret` | `mysqld is alive` | 0 |

An unauthenticated probe would pass permanently. Passing the application
credentials changes the behaviour that matters:

| Case | Exit |
|---|---|
| before mysqld accepts connections (init scripts running, ~15s) | 1 |
| once up | 0 |

That transition is the entire reason to probe mysql. The image runs
`/docker-entrypoint-initdb.d/` on first boot, so without the probe, `shipping`
and `ratings` race it and log connection errors on startup before recovering
on their own.

`mongo` needed no such treatment. Tested on `mongo:5`:

| Case | Exit |
|---|---|
| no server listening | 1 |
| live server | 0 |

## Disabling a probe

Any probe can be turned off with `--set`, without editing values:

```bash
helm upgrade robot-shop ./EKS/helm -n robot-shop \
  --set cart.readinessProbe=null
```

## Adding a probe to a service with none

The template has to reference it. redis and rabbitmq have the plumbing:

```bash
helm upgrade robot-shop ./EKS/helm -n robot-shop -f my-probes.yaml
```

```yaml
redis:
  readinessProbe:
    exec:
      command: ["redis-cli", "ping"]
    initialDelaySeconds: 5
    periodSeconds: 5
    failureThreshold: 6
```

`web`, `dispatch` and the OpenShift `Route` do not have the guard in their
templates, so adding a value alone will not render anything. Add the same
three-line `with` block next to `containerPort` in the template first, and make
sure it goes *after* the whole `ports:` list, not between entries --
`rabbitmq` has two `containerPort` lines and putting the probe between them
produces invalid YAML.
