#!/usr/bin/env bash
#
# Build every service image from the Dockerfile in its own directory and push
# it to ECR under the name the Helm chart expects.
#
#   ./scripts/build-push.sh              # build + push every service
#   ./scripts/build-push.sh cart web     # only these
#   TAG=2.1.2 ./scripts/build-push.sh    # override the tag
#
# Repository naming is not cosmetic. EKS/helm/templates/*.yaml render images as
#   {{ .Values.image.repo }}/rs-<service>:{{ .Values.image.version }}
# so with image.repo = <account>.dkr.ecr.<region>.amazonaws.com/robot-shop the
# registry path has to be robot-shop/rs-<service>. A repo named robot-shop/cart
# builds and pushes fine and then fails at runtime with ImagePullBackOff.

set -euo pipefail

REGION="${REGION:-us-east-1}"
ACCOUNT="${ACCOUNT:-$(aws sts get-caller-identity --query Account --output text)}"
REPO_PREFIX="${REPO_PREFIX:-robot-shop}"
TAG="${TAG:-2.1.0}"
PREFIX="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${REPO_PREFIX}"

# service-directory:registry-image-suffix
# The suffix is not always the directory name: mysql/ publishes as rs-mysql-db
# and mongo/ publishes as rs-mongodb.
SERVICES=(
  "cart:rs-cart"
  "catalogue:rs-catalogue"
  "dispatch:rs-dispatch"
  "mongodb:mongo"
  "mysql:rs-mysql-db"
  "payment:rs-payment"
  "ratings:rs-ratings"
  "shipping:rs-shipping"
  "user:rs-user"
  "web:rs-web"
)

cd "$(dirname "$0")/.."

selected=("$@")
if [ ${#selected[@]} -eq 0 ]; then
  for entry in "${SERVICES[@]}"; do selected+=("${entry%%:*}"); done
fi

echo "==> ECR login (${ACCOUNT} / ${REGION})"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

for svc in "${selected[@]}"; do
  entry=""
  for e in "${SERVICES[@]}"; do
    [ "${e%%:*}" = "$svc" ] && entry="$e" && break
  done
  if [ -z "$entry" ]; then
    echo "!! unknown service '$svc' (known: ${selected[*]})" >&2
    exit 1
  fi

  dir="${entry%%:*}"
  image="${entry##*:}"
  repo="${PREFIX}/${image}"

  # Create the repository up front. ECR rejects a push to a repository that does
  # not exist yet, and unlike Docker Hub there is no implicit creation.
  if ! aws ecr describe-repositories --repository-names "$repo" --region "$REGION" >/dev/null 2>&1; then
    echo "==> creating repository ${repo}"
    aws ecr create-repository --repository-name "$repo" --region "$REGION" >/dev/null
  fi

  echo "==> building ${dir} -> ${repo}:${TAG}"
  docker build -t "${repo}:${TAG}" "./${dir}"

  echo "==> pushing ${repo}:${TAG}"
  docker push "${repo}:${TAG}"
done

echo
echo "Done. Deploy with:"
echo "  helm install robot-shop ./EKS/helm --namespace robot-shop \\"
echo "    --set image.repo=${PREFIX} --set image.version=${TAG}"
