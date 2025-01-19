# 认识 kubernetes CNI

在使用 `kubeadm init` 初始化完集群之后，运行 `kubectl get node` node 的状态都是 `NotReady`

```shell
NAME     STATUS     ROLES           AGE     VERSION
master   NotReady   control-plane   6d11h   v1.29.0
worker   NotReady   <none>          6d11h   v1.29.0
```

这是因为当前集群之内并没有一个 cni 插件，导致 kubernetes 并不知道如何给 pod 分配 ip，所以集群中的 node 状态就是 NotReady
了。

## 什么是 CNI 呢？

CNI 的全称是 Container Network
Interface，它为容器提供了一种基于插件结构的标准化网络解决方案。以往，容器的网络层是和具体的底层网络环境高度相关的，不同的网络服务提供商有不同的实现。CNI
从网络服务里抽象出了一套标准接口，从而屏蔽了上层网络和底层网络提供商的网络实现之间的差异。并且，通过插件结构，它让容器在网络层的具体实现变得可插拔了，所以非常灵活。

CNI 隶属于 CNCF([Cloud Native Computing Foundation](https://www.cncf.io/))，Github: [cni](https://github.com/containernetworking/cni)
在[plugin](https://github.com/containernetworking/plugins) 代码库中，有很多 example 作为参考。

接下来准备使用 CNI plugin 中的 bridge 做实现。

## Go Go

按顺序运行下面命令(我这里使用的是 aws arm64 的 vm，以及 1.4.0 的 cni plugin)
```shell
ip netns add lab-ns # 创建一个 network namespace 以便于后面 cni 在运行的过程中使用这个 network namespace

cd ~
mkdir -p test-cni/plugins
cd test-cni/plugins
curl -OL https://github.com/containernetworking/plugins/releases/download/v1.4.0/cni-plugins-linux-arm64-v1.4.0.tgz
tar -zxf cni-plugins-linux-arm64-v1.4.0.tgz
cat > lab-br0.conf <<"EOF" # 配置详情：https://github.com/containernetworking/cni/blob/main/SPEC.md#section-1-network-configuration-format
{
    "cniVersion": "1.0.0",
    "name": "lab-br0",
    "type": "bridge",
    "bridge": "lab-br0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "subnet": "10.1.0.0/16",
        "gateway": "10.1.0.1",
        "routes": [
            {
                "dst": "0.0.0.0/0"
            }
        ]
    }
}
EOF
```

- cniVersion: 来自于 github 现在支持的 cni 版本
- name: 在一台机器上，这个 name 需要唯一
- type: 使用在当前磁盘上的那一个 cni plugin
- bridge: 网桥的名字
- isGateway: 只有设置为 true 才会给创建出来的网桥设置 ip
- ipMasq: 在插件支持的情况的，设置ip伪装。当宿主机充当的网关无法路由到分配给容器的IP子网的网关的时候，这个参数是必须有的。(别的地方抄过来的)
- ipam: ip address management 不同 cni plugin 应该有不同的 key value
  - type: 使用在当前磁盘上的那一个 cni plugin
  - subnet: 给 container 的 subnet address
  - gateway: gateway 地址
  - routes: 在创建出来的 network namespace 中设置的 route table

```shell
# 所有的参数解释：https://github.com/containernetworking/cni/blob/main/SPEC.md#parameters
CNI_COMMAND=ADD CNI_CONTAINERID=lab-ns CNI_NETNS=/var/run/netns/lab-ns CNI_IFNAME=eth0 CNI_PATH=`pwd` ./bridge <./lab-br0.conf
# 这个命令会输出：
# {
#     "cniVersion": "1.0.0",
#     "interfaces": [
#         {
#             "name": "lab-br0",
#             "mac": "c6:5e:52:2b:67:8d"
#         },
#         {
#             "name": "veth7e65c23d",
#             "mac": "d6:03:a5:19:9e:2b"
#         },
#         {
#             "name": "eth0",
#             "mac": "06:04:03:ac:ac:9c",
#             "sandbox": "/var/run/netns/lab-ns"
#         }
#     ],
#     "ips": [
#         {
#             "interface": 2,
#             "address": "10.1.0.2/16",
#             "gateway": "10.1.0.1"
#         }
#     ],
#     "routes": [
#         {
#             "dst": "0.0.0.0/0"
#         }
#     ],
#     "dns": {}
```

### verify

验证 vm interface
```shell
ip a s

···
# 这里 lab-br0 就是刚刚 bridge cni 创建的网桥
# veth7e65c23d 是 veth 其中一边
8: lab-br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    link/ether c6:5e:52:2b:67:8d brd ff:ff:ff:ff:ff:ff
    inet6 fe80::c45e:52ff:fe2b:678d/64 scope link
       valid_lft forever preferred_lft forever
9: veth7e65c23d@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue master lab-br0 state UP group default
    link/ether d6:03:a5:19:9e:2b brd ff:ff:ff:ff:ff:ff link-netns lab-ns
    inet6 fe80::d403:a5ff:fe19:9e2b/64 scope link
       valid_lft forever preferred_lft forever

# 另一边在 network namespace 里
ip netns exec lab-ns ip a s

# 在 lab-ns 这个 network namespace 中只有一块网卡，网卡名字是从：CNI_IFNAME 来的 
1: lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
2: eth0@if9: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default
    link/ether 06:04:03:ac:ac:9c brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.1.0.2/16 brd 10.1.255.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::404:3ff:feac:ac9c/64 scope link
       valid_lft forever preferred_lft forever

# 在 network namespace 中验证可以访问 network gateway
ip netns exec lab-ns ping 10.1.0.1 -c 3

# 在 network namespace 中验证可以访问自己
ip netns exec lab-ns ping 10.1.0.2 -c 3
```


## teardown

```shell
export NS_NAME="lab-ns"
export BR_NAME="lab-br0"

# 删除测试创建的 network namespace
ip -all netns delete lab-ns

# 删除 host-local 创建的 network bridge
# 在删除 bridge 前，必须先把 bridge 停掉
ip link set lab-br0 down
brctl delbr lab-br0

# 删除 cni 用来存储 metadata 的数据
rm -rf /var/lib/cni/networks/lab-br0/
```
