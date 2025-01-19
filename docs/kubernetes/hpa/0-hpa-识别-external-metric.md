# HPA 识别 external metric

使用 kubernetes 的运维，一定都会遇到需要配置 hpa(Horizontal Pod Autoscaling) 的时候，毕竟现在使用 kubernetes 其中一方面很大程度都是为了在业务低谷期通过 auto-scaling 省钱。

但是 kubernetes 内置的 metric 只能支持使用 CPU + memory，只有这两个 metric 肯定不足以满足现在这个时代这么复杂的需求，于是 external metric 出现了。

## HPA 如何使用 external metric

这里以 [KEDA](https://github.com/kedacore/keda/) 举例子(一个可以支持 scale to zero 的工具)。

按照 [KEDA 官方文档使用 helm 安装](https://keda.sh/docs/2.16/deploy/)完毕以后，可以在命令行敲一个：

```shell
$ kubectl get apiservices | grep keda

v1beta1.external.metrics.k8s.io        keda/keda-operator-metrics-apiserver    True        145d
```

这里的 [`v1beta1.external.metrics.k8s.io`](https://kubernetes.io/docs/reference/external-api/external-metrics.v1beta1/) 就是 kubernetes hpa 会通过这个 api 来获取 external metric。按照官网定义的，hpa 默认每 [15s](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#how-does-a-horizontalpodautoscaler-work) 会从 kube-controller-manager 获取 metric。

这个 apiservice 对象 yaml 为：

```yaml
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata:
  annotations:
    meta.helm.sh/release-name: keda
    meta.helm.sh/release-namespace: keda
  labels:
    app.kubernetes.io/component: operator
    app.kubernetes.io/instance: keda
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: v1beta1.external.metrics.k8s.io
    app.kubernetes.io/part-of: keda-operator
    app.kubernetes.io/version: 2.16.1
    helm.sh/chart: keda-2.16.1
  name: v1beta1.external.metrics.k8s.io
spec:
  caBundle: ....
  group: external.metrics.k8s.io
  groupPriorityMinimum: 100
  service:
    name: keda-operator-metrics-apiserver
    namespace: keda
    port: 443
  version: v1beta1
  versionPriority: 100
```

可以看到这里的 apiservice 最后会路由到一个 KEDA 的 svc 上，这个 svc 最后才是实际上用来提供 external metric 的地方，这一套流程 Prometheus、Datadog 也都是一样，**且这些使用 external metric 的工具，最后必须创建一个 name 为：`v1beta1.external.metrics.k8s.io` 的 api service，这就导致如果想要切换 external metric 只能先卸载再重装 🫠**