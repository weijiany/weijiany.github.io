# AWS VPC CNI 网络策略

在使用 EKS 的时候，会有一个安全的点可以考虑 -> 我们在 EKs 中部署的很多的第三的东西，实际上我们作为 DevOps，并不知道它的底层是怎么实现的，这个时候就很麻烦，很怕别人的东西引入了一个什么样的 bug 导致可以被黑客进入到 Pod 里 💥 所有的 Pod 都可以别人通过 API 访问到了！这可不是一个好的事情，容易丢工作的说~ 汪~

所以呢，今天就来分享一个还挺有意思的东西(aws vpc cni network policy)

## AWS VPC CNI

### 什么是 [AWS VPC CNI](https://github.com/aws/amazon-vpc-cni-k8s) 呢？

简单来说：它就是 Kubernetes 里众多 CNI 的一种实现。

只不过它是基于 AWS VPC 来实现的，不像别的 CNI 插件一样。像 flannel、calico 这种都是会使用 Kubernetes 中的 IP address 来给 Pod 添加 IP，这里更多使用的是 Linux 提供的 network namespace、veth-pair 来实现这种功能，靠 Linux 的 virtual network 来做。

但是 AWS 它另辟蹊径：它会给每一个运行在 EC2 上的 Pod 放上一个 ENI(也就是网卡) 来实现在 EKS 中给 Pod assign IP，于是这里就有个很坑爹的问题，一个 EC2 所能 attach 的 ENI 是有限的，这就导致 CPU、Memory 有时候还没有达到 80%，但是却出现 EC2 的 ENI 已经用尽了……

不过有一种解决办法，在 VPC-CNI 上称之为: [ENABLE_PREFIX_DELEGATION](https://github.com/aws/amazon-vpc-cni-k8s?tab=readme-ov-file#enable_prefix_delegation-v190)，开启这个功能之后，EC2 会给 ENI 分配一个 /28 的网络块，这样这个 ENI 就可以控制的是这个 /28 下的所有 ip 而不仅仅是几个独立的 ip。

**Note: **这里会出现 ENI 本来可以支持 20 个 ip，但是开启了 ENABLE_PREFIX_DELEGATION 会减少一个 ENI 能管理的 ip 数量。

### 怎么使用 AWS VPC CNI 实现 NetworkPolicy 呢？

在 kubernetes 中，可以使用 NetworkPolicy 来限制网络之间的访问。

在添加了 VPC-CNI addon 之后，如果没有任何的配置，默认的 [NETWORK_POLICY_ENFORCING_MODE](https://github.com/aws/amazon-vpc-cni-k8s?tab=readme-ov-file#network_policy_enforcing_mode-v1171) 是 standard，这意味着默认所有的 Pod 在任何一个 namespace 都可以互相访问，这不是我们想要的，这就导致可能出现如果第三方引入了 bug，就会导致我们的数据被拖走。所以如果想要限制访问，需要把 `NETWORK_POLICY_ENFORCING_MODE` 值设置为: strict，这意味着，任何一个 Pod 在没有配置任何的 NetworkPolicy 都不能互相访问。

**注意: 甚至同一个 namespace 的 pod 都不能互相访问 😉 (是不是非常严格)**

除了需要修改 `NETWORK_POLICY_ENFORCING_MODE` 值为: strict，还需要开启一个 VPC-CNI 内部的 controller 才可以。可以通过在 VPC-CNI addon 配置界面 -> Advanced configuration 中添加 `{"enableNetworkPolicy":"true"}` 才可以，这样会修改 kube-system namespace 下的 amazon-vpc-cni configmap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/instance: aws-vpc-cni
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: aws-node
    app.kubernetes.io/version: v1.18.1
    helm.sh/chart: aws-vpc-cni-1.18.1
    k8s-app: aws-node
  name: amazon-vpc-cni
  namespace: kube-system
data:
  branch-eni-cooldown: "60"
  enable-network-policy-controller: "true" # 这个值变为 true
  enable-windows-ipam: "false"
  enable-windows-prefix-delegation: "false"
  minimum-ip-target: "3"
  warm-ip-target: "1"
  warm-prefix-target: "0"
```

之后就可以创建 NetworkPolicy 来限制不同 namespace 之间的访问了。

**注意：** 
1. 通过 fargate 启动的 pod 不会收到 NetworkPolicy 的影响 https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy.html
2. 必须两边都配置才可以访问通，在一个 namespace 允许 egress(出)，在另一个 namespace 允许 ingress(进)
3. NetworkPolicy 都只是针对新创建的 Pod，所以每次修改了 NetworkPolicy 最好都是直接重启一起受到影响的 Pod

### Example

- 允许相同 namespace 互相访问
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: np
  spec:
    podSelector: {}
    policyTypes:
      - Ingress
      - Egress
    ingress:
      - from:
          - podSelector: {}
    egress:
      - to:
          - podSelector: {}
  ```

- 允许访问外网，但是使用 pod ip 还是不能访问的
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: np
  spec:
    podSelector: {}
    policyTypes:
      - Egress
    egress:
      - to:
          - ipBlock:
              cidr: 0.0.0.0/0
  ```

- 允许访问 coredns 来解析 svc
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: np
  spec:
    podSelector: {}
    policyTypes:
      - Egress
    egress:
      - to:
          - namespaceSelector: {}
            podSelector:
              matchLabels:
                k8s-app: kube-dns
        ports:
          - port: 53
            protocol: UDP
  ```

- 允许一个 namespace 的所有 pod 访问当前 namespace
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: np
  spec:
    podSelector: {}
    policyTypes:
      - Ingress
    ingress:
      - from:
          - podSelector: {}
      - from:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: demo
  ```

这里有一个非常好用的网站，可以傻瓜式配置 NetworkPolicy: https://editor.networkpolicy.io
