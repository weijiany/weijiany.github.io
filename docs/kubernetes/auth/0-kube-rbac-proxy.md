# kube-rbac-proxy

今天在过 OTEL-operator 的时候发现，OTEL-operator 使用了一个名为：[kube-rbac-proxy 的 sidecar.](https://github.com/open-telemetry/opentelemetry-helm-charts/blob/ddda95b32ec4f87909e4de312f13140593018b09/charts/opentelemetry-operator/values.yaml#L222-L226)

于是花时间了解一下什么是 [kube-rbac-proxy. 🥳](https://github.com/brancz/kube-rbac-proxy/)。

```python
print("Hello, MkDocs!")

## Introduction

kube-rbac-proxy 是一个基于 K8S RBAC 来做 auth 并且防护后面代理的服务，暂时还处于 v0 阶段，还没有正式 release 只不过可以浅尝一下。OTEL-operator 可以通过 enable kube-rbac-proxy 来对 `/metrics` 接口做 auth，以便于只允许 prometheus 带着固定的 service-account token 才可以访问。

## Precondition

在介绍 kube-rbac-proxy 之前，需要提一下 `kubectl auth can-i` 这个命令。这个命令主要是用来查看当前用户对于当前 cluster (kube-config) 的资源都有什么权限

```
Resources                                        Non-Resource URLs        Resource Names     Verbs
pods/exec                                        []                       []                 [*]
pods/portforward                                 []                       []                 [*]
pods/eviction                                    []                       []                 [create]
selfsubjectreviews.authentication.k8s.io         []                       []                 [create]
selfsubjectaccessreviews.authorization.k8s.io    []                       []                 [create]
selfsubjectrulesreviews.authorization.k8s.io     []                       []                 [create]
...
```

类似于这种输出，可以很直观的看到 resource 与 verb 之间的关系。那么 k8s 是怎么实现这套机制的呢？在 k8s 官方文档中有一章节讲 [Checking API access](https://kubernetes.io/docs/reference/access-authn-authz/authorization/#checking-api-access) 提到：可以使用 SelfSubjectAccessReview 来检查当前用户对于哪些资源的权限。

> SelfSubjectAccessReview is part of the authorization.k8s.io API group, which exposes the API server authorization to external services. Other resources in this group include:
>
> **SubjectAccessReview**
> Access review for any user, not only the current one. Useful for delegating authorization decisions to the API server. For example, the kubelet and extension API servers use this to determine user access to their own APIs.
> **LocalSubjectAccessReview**
> Like SubjectAccessReview but restricted to a specific namespace.
> **SelfSubjectRulesReview**
> A review which returns the set of actions a user can perform within a namespace. Useful for users to quickly summarize their own access, or for UIs to hide/show actions.

我本地集群使用 [orbstack](https://orbstack.dev/) 启动的，可以使用 `SubjectAccessReview` 来检查 `system:kube-scheduler` 对于 default namesapce 下的 pod 有没有 Get 权限

```shell
create -f - -o yaml << EOF
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: "system:kube-scheduler"
  resourceAttributes:
    namespace: "default"
    verb: "get"
    resource: "pods"
EOF

# Output
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
metadata:
  creationTimestamp: null
spec:
  resourceAttributes:
    namespace: default
    resource: pods
    verb: get
  user: system:kube-scheduler
status:
  allowed: true
  reason: 'RBAC: allowed by ClusterRoleBinding "system:kube-scheduler" of ClusterRole
    "system:kube-scheduler" to User "system:kube-scheduler"'
```

## How

有了 `SubjectAccessReview` 就可以验证当前用户权限，但是目前来看都是对于 K8S 内置的资源，但是像 OTEL-operator 实际上是对 `/metrics` 接口做 auth，在 K8S 中怎么实现呢？

K8S 已经实现可以对 ClusterRole 添加 `nonResourceURLs` 字段，以便于给 ClusterRole 对应接口的权限，基于上述 `/metrics` 接口的 ClusterRole yaml:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: allow-access-otel-operator
rules:
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]
```

再把 allow-access-otel-operator ClusterRole 绑定到 ServiceAccount 上以后，pod 在使用 ServiceAccount 会自动在 `/var/run/secrets/kubernetes.io/serviceaccount` 挂载 ServiceAccount token，可以通过在请求接口的时候带着：`Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)` header 这样 auth 请求就能通过。

## Example

<details>
<summary>kube-rbac-proxy -> nginx deployment yaml</summary>

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels:
    app: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      serviceAccountName: nginx-service-account
      containers:
      - name: nginx
        image: nginx:mainline-alpine3.22
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
      - name: kube-rbac-proxy
        args:
        - --secure-listen-address=0.0.0.0:8443
        - --upstream=http://127.0.0.1:80/
        - --v=0
        image: quay.io/brancz/kube-rbac-proxy:v0.19.1
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8443
          name: https
          protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
  labels:
    app: nginx
spec:
  type: ClusterIP
  ports:
  - name: https
    port: 8443
    targetPort: https
    protocol: TCP
  selector:
    app: nginx
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nginx-service-account
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nginx-rbac-proxy-role
rules:
# kube-rbac-proxy 需要这些权限做认证
- apiGroups: ["authentication.k8s.io"]
  resources: ["tokenreviews"]
  verbs: ["create"]
- apiGroups: ["authorization.k8s.io"]
  resources: ["subjectaccessreviews"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nginx-rbac-proxy-binding
subjects:
- kind: ServiceAccount
  name: nginx-service-account
  namespace: default
roleRef:
  kind: ClusterRole
  name: nginx-rbac-proxy-role
  apiGroup: rbac.authorization.k8s.io
```
</details>
<br>

<details>
<summary>another pod to access kube-rbac-proxy</summary>

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: curl
spec:
  serviceAccountName: test-service-account
  containers:
  - name: curl
    image: alpine/curl:8.14.1
    command: ["sleep", "3600"]
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-service-account
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nginx-pod-reader
rules:
- nonResourceURLs: ["/"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nginx-pod-reader-binding
  labels:
    app: test
subjects:
- kind: ServiceAccount
  name: test-service-account
  namespace: default
roleRef:
  kind: ClusterRole
  name: nginx-pod-reader
  apiGroup: rbac.authorization.k8s.io
```

测试：
```yaml
kubectl  exec -it pods/test-pod -- sh

# 会返回 nginx 首页
curl -H 'Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)' https://nginx-service:8443/ -k
```
</details>
<br>
