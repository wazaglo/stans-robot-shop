# EKS cluster setup

## Create

The cluster definition lives in [`../eksctl/cluster.yaml`](../eksctl/cluster.yaml).

```bash
eksctl create cluster -f eksctl/cluster.yaml
aws eks update-kubeconfig --name wisdom-eks --region us-east-1
```

This creates:

- a VPC `192.168.0.0/16` across `us-east-1c` and `us-east-1f`
- 2 public + 2 private subnets per AZ pair
- the EKS control plane, Kubernetes 1.34
- node group `ng-micro-17`, `t3.micro`, `AL2023_x86_64_STANDARD`, 20Gi `gp3`
- `vpc-cni` configured with `ENABLE_PREFIX_DELEGATION=true`

Expect **15-25 minutes**. `eksctl` does not create things directly -- it builds
CloudFormation stacks, one for the control plane and one per node group, and
waits on them. If it appears to hang, that is normal; check
`CloudFormation > Stacks` for progress.

## If you prefer the console

`EKS > Clusters > Create cluster` with these non-default values:

| Field | Value |
|---|---|
| Kubernetes version | 1.34 |
| Subnets | the two **private** ones |
| Node IAM role | `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryReadOnly` + `AmazonEKS_CNI_Policy` |
| AMI type | Amazon Linux 2023 (AL2023_x86_64_STANDARD) |
| Capacity type | On-Demand |
| Instance type | `t3.micro` |
| Disk | 20Gi, `gp3` |
| Desired / min / max | 2 / 1 / 7 |
| Labels / taints | none |

Then `Add-ons > vpc-cni > Edit configuration` and set
`ENABLE_PREFIX_DELEGATION=true`, `WARM_PREFIX_TARGET=1`.

**Ordering matters.** Set prefix delegation before the node group's first boot.
Editing the add-on afterwards does not change existing nodes -- the `--max-pods`
value is in the node group's launch template user-data. Verify:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" maxPods="}{.status.capacity.pods}{"\n"}{end}'
```

`34` is correct. `4` means prefix delegation did not take effect and the node
group must be recreated.

## Verify

```bash
kubectl get nodes
kubectl get pods -n kube-system
aws eks list-addons --cluster-name wisdom-eks --region us-east-1
```

Expect `coredns`, `kube-proxy`, `vpc-cni` active and every `kube-system` pod
`Running`.

## Add-ons

`aws-ebs-csi-driver` is installed separately in
[05-ebs-csi-driver.md](05-ebs-csi-driver.md) because it needs an IAM role whose
trust policy references the cluster's OIDC issuer, which only exists once the
control plane is up.

```bash
kubectl get storageclass
```

`eksctl` leaves an in-tree `gp2` class using the retired
`kubernetes.io/aws-ebs` provisioner. On Kubernetes 1.34 it will not provision
anything, because in-tree volume plugins were removed. The EKS add-on installs
the `ebs.csi.aws.com` class alongside it. Verify Redis's PVC binds:

```bash
kubectl get pvc -n robot-shop
```

`Bound` means EBS works.

## Node sizing

`desiredCapacity: 2` is the minimum that can run this app at all, and even then
memory is the binding constraint. `maxSize: 7` is a ceiling, not a
recommendation -- see the capacity section in [`../README.md`](../README.md) and
issue 8 in [`../docs/troubleshooting.md`](../docs/troubleshooting.md) before
raising it.

## Delete

```bash
eksctl delete cluster --name wisdom-eks --region us-east-1
```

Takes 10-20 minutes. The VPC, subnets, NAT gateway and node group go with it.
ECR repositories do **not** -- delete those separately.
