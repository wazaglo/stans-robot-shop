# EBS CSI driver

Robot Shop's `redis` StatefulSet claims a `gp2` PersistentVolumeClaim
(`EKS/helm/values.yaml`, `redis.storageClassName`). Something has to turn that
claim into a real EBS volume. That is the CSI driver.

The `eksctl` cluster also leaves an in-tree `gp2` StorageClass behind:

```
NAME   PROVISIONER             RECLAIMPOLICY
gp2    kubernetes.io/aws-ebs    Delete
```

That provisioner is the **in-tree** plugin, removed in Kubernetes 1.34. It
still appears in `kubectl get storageclass` and will happily sit there accepting
claims that never bind. The add-on below installs the `ebs.csi.aws.com` class
next to it.

## 1. IAM role

`AmazonEBSCSIDriverPolicy` is AWS-managed, so this one resolves:

```bash
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster wisdom-eks \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve
```

`--role-only` creates just the IAM role and lets you wire it up yourself later.
`--approve` skips the interactive confirmation, which is necessary in a script.

## 2. Trust policy

The role's `sub` must be exactly:

```
system:serviceaccount:kube-system:ebs-csi-controller-sa
```

Check it -- the console will only add `aud`:

```bash
aws iam get-role --role-name AmazonEKS_EBS_CSI_DriverRole \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals' --output json
```

```json
{
  "oidc...:aud": "sts.amazonaws.com",
  "oidc...:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
}
```

Both keys required. See [03-oidc-IAM.md](03-oidc-IAM.md) #3 and
[`../docs/troubleshooting.md`](../docs/troubleshooting.md) #9.

## 3. Install the add-on

Console: `EKS > wisdom-eks > Add-ons > Get more add-ons > Amazon EBS CSI Driver`

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

eksctl create addon \
  --name aws-ebs-csi-driver \
  --cluster wisdom-eks \
  --service-account-role-arn arn:aws:iam::$ACCOUNT:role/AmazonEKS_EBS_CSI_DriverRole
```

`--force` is only needed to change configuration on an already-installed
add-on. Leave it off the first install.

## 4. Verify

```bash
aws eks describe-addon --cluster-name wisdom-eks --addon-name aws-ebs-csi-driver \
  --query 'addon.status'

kubectl get storageclass
```

```
NAME   PROVISIONER      RECLAIMPOLICY   VOLUMEBINDINGMODE
gp2    kubernetes.io/aws-ebs   Delete          WaitForFirstConsumer
gp2    ebs.csi.aws.com          Delete          WaitForFirstConsumer
gp3    ebs.csi.aws.com          Delete          WaitForFirstConsumer
```

Two classes named `gp2` is expected and not a problem: the in-tree one is inert
on 1.34, the `ebs.csi.aws.com` one does the work. The `redis` template requests
`gp2` and Kubernetes will bind it to a provisioner that actually functions.

## 5. Prove it works

Deploy the app, then:

```bash
kubectl get pvc -n robot-shop
```

```
NAME           STATUS    VOLUME                                     CAPACITY
data-redis-0   Bound     pvc-69fd8dad-5c65-488d-a3aa-8469ff5629a4   1Gi
```

`Bound` is the proof. Then confirm a volume really exists:

```bash
aws ec2 describe-volumes --region us-east-1 \
  --filters Name=tag:kubernetes.io/created-for/pvc/name,Values=data-redis-0 \
  --query 'Volumes[].{Id:VolumeId,Size:Size,State:State,Type:VolumeType}'
```

## Troubleshooting

**Add-on `DEGRADED`, "Too many pods"**

Not an IAM problem. The controller cannot be scheduled because every node is
full. This is `maxPods=4`, the prefix-delegation problem -- see
[`../docs/troubleshooting.md`](../docs/troubleshooting.md) #2. It is the single
most common failure in this whole build.

**PVC stuck `Pending`**

```bash
kubectl describe pvc data-redis-0 -n robot-shop | tail -15
```

`WaitForFirstConsumer` means the claim is held until a pod is actually
scheduled. If the pod is `Pending` for a memory reason, the volume is never
provisioned -- fix the scheduling problem first and the PVC resolves itself.

**`no topology key found for node ...`**

Transient during node startup. The driver reads the node's
`topology.ebs.csi.aws.com/zone` label, which does not exist for the first few
seconds after a node joins. It resolves on retry -- see
[`../docs/troubleshooting.md`](../docs/troubleshooting.md) #6.

**`AccessDenied` or `WebIdentityErr` in the controller logs**

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver \
  -c ebs-csi-controller --tail=30
```

Trust policy mismatch. Compare the `sub` in the role against the actual
ServiceAccount:

```bash
kubectl get sa ebs-csi-controller-sa -n kube-system -o jsonpath='{.metadata.name}{"\n"}'
```

## References

- [Amazon EBS CSI driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver)
- [Persistent storage for Amazon EKS](https://repost.aws/knowledge-center/eks-persistent-storage)
