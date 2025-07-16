# Local LoadBalancer metallb

最近在调研一些 Helm Chart 的时候，总会出现他们默认提供的 values 里对于 SVC 的 Type 都是 LoadBalancer，但是我的本地 Kubernetes 根本不支持安装 LoadBalancer 类型的 SVC，每次都得手动修改 SVC 部分配置使用 NodePort 以便于我可以在集群外部访问到服务。

## How

最近正好在使用一个新的 Local LoadBalancer provider: [metallb](https://github.com/metallb/metallb).

这个库挺好用的，直接就能使用本地能够访问到的 ip 作为 LoadBalancer 的 External IP，不过文档写的是真不咋地，也没有一个 Getting Start，那我就勉勉强强给写一个吧 🫠

### MetalLB Getting Start

- Install Orbstack: `brew install orbstack`
- Start Kubernetes via Orbstack: `orb start k8s`
- Install MetalLB

```bash
helm repo add metallb https://metallb.github.io/metallb
# frr: 开启 BGP 这对于我本地测试来说，没有任何作用
helm upgrade --install metallb metallb/metallb --version 0.15.2 --set "speaker.frr.enabled=false" -n metallb --create-namespace
```

- Detect Node IP: `kubectl get node -o wide | awk 'NR!=1{print $6}'` 为了知道本机可以连接到 Orbstack 启动的 Kubernetes IP 段得先获取一下 node ip，假如 node ip 是: `198.19.249.2`，那么就可以给 Metallb 配置的 ip 段为: `198.19.249.100-198.19.249.200`。**切记：**不要使用 en0 对应的 ip 段，可能会对局域网产生影响。

- Configure Metallb

```bash
kubectl apply -n metallb -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
spec:
  addresses:
    - 198.19.249.100-198.19.249.200
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2adv
spec:
  ipAddressPools:
    - default-pool
EOF
```

- Test

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:mainline-alpine3.22
        ports:
        - name: http
          containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: nginx
  type: LoadBalancer
EOF
```

等待一会，查看 Service 是否获取到了 External IP：`kubectl get svc nginx`
