# Security Policy

## Reporting a vulnerability

This is a demonstration application. It is not a maintained product and there is
no supported release line.

If you believe you have found a vulnerability that would matter in a real
deployment, open an issue describing it. Please do not include anything that
would be actively harmful if public — no working exploits against running
systems, no credentials that are actually live.

You should get a response within a week. It may be "this is out of scope for a
demo", and often that would be the honest answer.

## This application is not hardened

Stan’s Robot Shop is a sample application for learning. Its own documentation
says the error handling is patchy and no security is built in. The specifics
below are not oversights to be reported; they are properties of a demo, listed
so nobody deploys it expecting otherwise.

### Credentials are committed

`mysql/Dockerfile` sets `MYSQL_ROOT_PASSWORD`, `MYSQL_USER=shipping` and
`MYSQL_PASSWORD=secret` as build arguments. The `ratings` service hardcodes
`ratings`/`iloveit` in `Kernel.php`, granted by `mysql/scripts/20-ratings.sql`.
`shipping` hardcodes `shipping`/`secret` in `JpaConfig.java`.

This is inherited from upstream and is appropriate only because the image is
public anyway. For anything real, credentials belong in a Secret referenced by
the Deployment, not baked into an image or a source file.

Note that the MySQL readiness probe in `EKS/helm/values.yaml` restates the
`shipping` credentials so it can authenticate. That makes them visible in the
pod spec, which is documented in [docs/probes.md](docs/probes.md) with the
Secret-based alternative.

### No network policy

Nothing restricts which pods may talk to which. Every service can reach every
other service and the data stores. The `web` Service was changed to `ClusterIP`
so the storefront is only reachable through the ALB, but the data tier is not
isolated from the business tier.

### No authentication or authorization

There is no user authentication, no session handling, and no authorisation
anywhere in the application. Any request that reaches a service is served.

### Services bind to all interfaces

Nothing listens on a restricted address. The ALB is the only thing limiting
exposure.

### Upstream dependencies are old

`node:14`, `python:3.9` and `php:7.4-apache` are all end-of-life. They are what
the upstream application pins, and upgrading them means changing application
code that was only ever tested against those versions.

`ratings` cannot be built at all, because `php:7.4-apache` no longer receives
Debian archive updates and its package index has moved on. See
[docs/building.md](docs/building.md). Running the published `2.1.0` image means
running PHP 7.4 with whatever its dependencies have become.

`npm install` reported 23 vulnerabilities while building this, 2 of them
critical, in the upstream dependency tree of the Node services. These were not
addressed because fixing them means upgrading application dependencies that the
upstream sample pins.

### Supply chain

Ten images are built from this repository and pushed to a private ECR registry.
Base images are referenced by tag, not by digest, so a rebuild is not
guaranteed to use the same base image as the previous build. `dispatch` is the
only service with its dependencies pinned, via the committed `go.mod` and
`go.sum`.

A registry with tag immutability enabled would prevent overwriting a tag that a
running cluster already pulled. This repository does not enforce it, because
mutable tags were needed while iterating on the build.

## If you are deploying this for real

Do not. Use it to learn the deployment mechanics, then delete it. If you need
the mechanics demonstrated against something production-shaped, that needs
different work: a network policy, real secret management, non-pinned base image
digests, current runtime versions, and a service mesh or equivalent to control
east-west traffic.
