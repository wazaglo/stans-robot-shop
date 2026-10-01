# Building the images

Nine of the ten services in this repo build from their Dockerfile. `ratings`
does not, and this page explains why, what was actually done instead, and what
the options are.

```bash
./scripts/build-push.sh              # all ten
./scripts/build-push.sh cart web     # just these
```

## ratings cannot be built

```
E: Failed to fetch http://deb.debian.org/debian-security/pool/updates/main/u/unzip/unzip_6.0-26%2bdeb11u2_amd64.deb  404  Not Found
E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
ERROR: process "/bin/sh -c apt-get update && apt-get install -yqq unzip libzip-dev \
    && docker-php-ext-install pdo_mysql opcache zip" did not complete successfully: exit code: 100
```

**Cause.** `ratings/Dockerfile` starts from `php:7.4-apache`, which is built on
Debian bullseye. PHP 7.4 is end of life, so the image no longer receives
security updates, and its pinned package index is now behind the live Debian
archive. `apt-get update` succeeds, then `apt-get install unzip` requests
`unzip_6.0-26+deb11u2`, which has been superseded in `deb.debian.org` and now
404s.

This is upstream bit-rot, not a mistake in this repo, and it is not specific to
this deployment. Any `php:7.4-apache` build that installs packages from the
bullseye archive will fail the same way, and will keep failing as the archive
moves on. Retrying does not help, because the failure is deterministic.

**What was done instead.** The published image was pulled and re-pushed into
ECR, so the tag in this repository is a real ECR image and the chart pulls from
ECR like everything else:

```bash
docker pull robotshop/rs-ratings:2.1.0
docker tag  robotshop/rs-ratings:2.1.0 \
  <account>.dkr.ecr.us-east-1.amazonaws.com/robot-shop/rs-ratings:2.1.0
docker push <account>.dkr.ecr.us-east-1.amazonaws.com/robot-shop/rs-ratings:2.1.0
```

Note that `scripts/build-push.sh` does **not** do this. It runs `docker build`
for every service, so a full run fails on ratings. Build the other nine and
handle ratings explicitly, or skip it:

```bash
./scripts/build-push.sh cart catalogue dispatch mongodb mysql-db \
                         payment shipping user web
```

## Options, if you need to build it from source

In rough order of preference.

**1. Pin the base image by digest.** Does not fix anything on its own -- the
digest still points at the same bullseye archive. Useful only to stop the base
image drifting further while you decide.

**2. Install packages before switching to bullseye, or use a snapshot repo.**
Pointing `apt` at `snapshot.debian.org` restores the archive as it was when
the index was current, so the exact `unzip_6.0-26+deb11u2` resolves. It is
fiddly and the image then carries no security updates at all.

**3. Build against a PHP version that still has a maintained base.** This is
the real fix, and it is also the one that carries risk: the application code in
`ratings/html/` targets PHP 7.4 and was never tested on 8.x. Symfony, Doctrine
and the PHP extensions all changed between those versions. A bump needs the
app run to confirm it works, not just a green build.

```dockerfile
FROM php:8.2-apache
```

Expect to fix deprecation notices and possibly an extension or two.

**4. Use a pre-built PHP 7.4 image that already has the extensions**, if you
want PHP 7.4 semantics. You give up the `docker-php-ext-install` step but keep
the language version.

**Not recommended:** loosening the failure, for example `apt-get install
--allow-downgrades`, or pinning `unzip=1:6.0-26+deb11u1`. It trades a build
failure for an image with a knowingly vulnerable package.

## Verifying what you have

If you did not build it from source, confirm the image in ECR is the one you
expect rather than a stale layer:

```bash
aws ecr describe-images --repository-name robot-shop/rs-ratings --region us-east-1 \
  --query 'imageDetails[].{Tags:imageTags,Pushed:imagePushedAt,Size:imageSizeInBytes}' --output json
```

`ratings` is a PHP 7.4 image of roughly 500MB. Anything an order of magnitude
smaller is not it.

## The other nine

These build cleanly, verified individually with the `.dockerignore` files in
place:

| Service | Base | Notes |
|---|---|---|
| cart, catalogue, user | `node:14` | Node 14 is EOL but the Debian archive still resolves, so the build works. See the note below. |
| payment | `python:3.9` | Also EOL, but it installs no system packages, so it is unaffected. |
| dispatch | `golang:1.24` | dependencies pinned via `go.mod`/`go.sum` |
| web | `nginx:1.21.6` | |
| mongo | `mongo:5` | |
| mysql | `mysql:5.7` | slow build; the 15MB `scripts/10-dump.sql.gz` is copied in |
| shipping | `maven:3.8.8-eclipse-temurin-8` | multi-stage; JVM flags in the Dockerfile must match the chart's memory limit |

`node:14`, `python:3.9` and `php:7.4-apache` are all end-of-life. `ratings` is
the one that has actually broken, and the reason is specific rather than
general: **it is the only service that installs packages from its base image's
own Debian archive.** The other two run `npm install` or `pip install` against
language package indexes that are still maintained, so their EOL base images
do not affect the build today.

`ratings` runs `apt-get install unzip libzip-dev`, and that is the apt archive
rotting underneath a frozen PHP 7.4 image. If the other services ever gain an
`apt-get install` line, they inherit the same failure mode.

This is a property of the upstream sample application, which pins old runtimes
to stay compatible with its own code. Fixing it properly means upgrading the
languages, which means testing the application code -- see the options above.
