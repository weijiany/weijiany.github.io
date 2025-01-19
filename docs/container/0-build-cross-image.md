# Build cross images

日常使用 mac 作为开发电脑，这就导致有些时候在 build image，需要同时 build 两个 platform arm, amd 的 images，arm 有时候会用来验证 image 是否可以正常工作，amd 的用来在线上运行。那么使用怎么构建多个 platform 的 inage 就成了一个问题。

## 使用多个 platform node

在使用 docker、buildah、buildx 这种工具的时候，能构建出什么 platform image 都是基于 node platform 来决定的。所以比较简单的方法就是使用多个 platform node 来直接 build 多个 images。最后创建 manifest 来做到 cross platform。

但是也有一个小缺点：会启动多个 node 导致 cost 增加

## 使用 qemu 通过模拟 architecture

[qemu](https://github.com/multiarch/qemu-user-static) 可以模拟 architecture 来完成构建多个 platform image 它只有一个不好的地方：速度慢，因为是通过软件模拟的 architecture 基础功能，这就导致会比直接使用 node 速度慢很多，但是在我的体验来说，还能接受。

现在基本上都是使用 kubernetes pod 作为 ci agent，那么就需要在每一个 agent node 上通过 DaemonSet 启动 qemu 这个工具。这里有个 DaemonSet 的例子：

```yaml
---
# Source: qemu-user-static/templates/daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: qemu-user-static
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: qemu-user-static
      app.kubernetes.io/instance: qemu-user-static
  template:
    metadata:
      labels:
        app.kubernetes.io/name: qemu-user-static
        app.kubernetes.io/instance: qemu-user-static
    spec:
      initContainers:
        - name: qemu
          image: "multiarch/qemu-user-static:7.2.0-1" # tag refer to https://github.com/multiarch/qemu-user-static/tags
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
            seLinuxOptions:
              level: s0
          args:
            - --reset
            - -p
            - "yes"
      containers:
        - image: "registry.k8s.io/pause:3.10"
          name: pause
```

qemu 装好后就可以使用 buildah、buildx 这种命令直接 build cross imaeg。
