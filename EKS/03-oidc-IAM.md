# OIDC provider and IRSA

## Why this is needed

Every pod in `kube-system` on a managed node group runs under the same EC2
instance profile. Giving that profile permission to create load balancers or EBS
volumes means giving those permissions to *every* pod on the node -- including
anything that gets compromised.

IRSA (IAM Roles for Service Accounts) fixes this. The cluster runs an OIDC
issuer. A pod with an annotated ServiceAccount can exchange a signed JWT for
temporary AWS credentials, and IAM decides whether to hand them over by checking
the token's `aud` and `sub` claims.

Robot Shop needs this for exactly two things:

| Workload | Needs | Why |
|---|---|---|
| `aws-load-balancer-controller` | `elasticloadbalancing:*`, `ec2:Describe*` | creates the real ALB behind `ingress.yaml` |
| `ebs-csi-controller` | `ec2:CreateVolume`, `AttachVolume`, ... | provisions the `gp2` volume for Redis |

Without either, the Ingress stays `pending` with no external address, and Redis's
PVC never binds.

## 1. Find the cluster's issuer

```bash
aws eks describe-cluster --name wisdom-eks --region us-east-1 \
  --query 'cluster.identity.oidc.issuer' --output text
```

```
https://oidc.eks.us-east-1.amazonaws.com/id/BF7DCAA15E253D53B9F8BBD2CB7F7EF6
```

In the console: `EKS > Clusters > wisdom-eks > Overview`, **OpenID Connect provider URL**.

## 2. Create the provider in IAM

Console: `IAM > Access management > Identity providers > Add provider`

- Provider type: `OpenID Connect`
- Provider URL: the issuer from step 1, no trailing slash
- Audience: `sts.amazonaws.com`

Or:

```bash
eksctl utils associate-iam-oidc-provider --cluster wisdom-eks --approve
```

Verify:

```bash
aws iam list-open-id-connect-providers
```

A provider URL is regional. One created in `us-east-1` will not satisfy a
cluster in another region.

## 3. Create a role scoped to one ServiceAccount

Trust policy -- note **both** conditions:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<account-id>:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/<oidc-id>" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.us-east-1.amazonaws.com/id/<oidc-id>:aud": "sts.amazonaws.com",
        "oidc.eks.us-east-1.amazonaws.com/id/<oidc-id>:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
      }
    }
  }]
}
```

`aud` proves the token was minted for AWS STS. `sub` proves *which* workload is
asking. Without `sub`, any service account in any namespace can assume the role.

### The Console will not add `sub` for you

Creating a Web identity role through the console produces:

```json
"Condition": { "StringEquals": { "oidc...:aud": "sts.amazonaws.com" } }
```

`aud` only. The role works, so nothing looks wrong -- but it is far more
permissive than intended. Check and fix it by hand:

```bash
aws iam get-role --role-name AmazonEKS_EBS_CSI_DriverRole \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals' --output json
```

Both keys must be present. See
[`../docs/troubleshooting.md`](../docs/troubleshooting.md) #9.

## 4. Point the ServiceAccount at the role

The EKS add-ons in the next two steps do this for you. If you install either by
hand, the annotation is the mechanism:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ebs-csi-controller-sa
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/AmazonEKS_EBS_CSI_DriverRole
```

## Roles used here

| Role | `sub` |
|---|---|
| `AmazonEKSLoadBalancerControllerRole` | `system:serviceaccount:kube-system:aws-load-balancer-controller` |
| `AmazonEKS_EBS_CSI_DriverRole` | `system:serviceaccount:kube-system:ebs-csi-controller-sa` |

## Verify

```bash
kubectl get sa -n kube-system -o custom-columns=\
NAME:.metadata.name,ROLE:.metadata.annotations.eks\.amazonaws\.com/role-arn
```

Both should show a role ARN. Then confirm the controller is actually using it:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver -c ebs-csi-controller \
  | grep -i 'identity\|token\|provider'
```

An `AccessDenied` or `WebIdentityErr` in that output means the trust policy and
the ServiceAccount annotation disagree -- usually a typo in the `sub` claim.
