# Prerequisites

Three CLIs plus Docker. Everything below was used to build this.

| Tool | Used for | Check |
|---|---|---|
| `aws` | IAM, ECR, ELB, and token auth for `kubectl` | `aws --version` |
| `kubectl` | talking to the cluster | `kubectl version --client` |
| `eksctl` | creating the cluster and node group | `eksctl version` |
| `helm` | rendering and deploying the app | `helm version` |
| `docker` | building images to push to ECR | `docker version` |

`aws` must be v2 and reasonably current. Older versions have their own
`InvalidParameterCombination` quirks against EKS APIs.

## Authenticate

```bash
aws configure
# or
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

The identity you authenticate as is the one that ends up owning everything
created below -- cluster, node group, IAM roles, ECR repositories.

## Connect to the cluster

`eksctl create cluster` writes a kubeconfig for you. If the context is missing:

```bash
aws eks update-kubeconfig --name wisdom-eks --region us-east-1
kubectl config get-contexts
```

If `kubectl` reports `context was not found` while `~/.kube/config` visibly
contains your cluster, the `contexts:` block is empty or stale -- a partially
written kubeconfig. `update-kubeconfig` repairs it; do not hand-edit the file.

## IDE

[Lens IDE](https://k8slens.dev/) reads the same `~/.kube/config`, so once
`kubectl get nodes` works, add the cluster from that file in
**Catalog > Clusters > Add from Kubeconfig**. It is the fastest way to watch
workloads, inspect events, and read logs during setup.

## Kubernetes dashboard (optional)

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/master/aio/deploy/recommended.yaml
```

Note this is a community project, not officially supported, and it cannot be
reached through the private subnets the nodes live in without extra work.
Lens is the better option for this cluster.
