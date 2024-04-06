# 认识 AWS SSO

今天在工作中第一次想研究研究，为什么每次通过 OKTA、Mirosoft AD 登录 AWS 之后，会出现很多个 account 的选择窗口呢，而且为什么点了一个 account
之后，会出现选择多个 role 呢？

(自己没有 AWS 账号，截图是费劲了 😭)

## AWS SSO

在 AWS 中，可以在对应的 account 中 enable aws sso 完了之后，就可以创建 permission set 了，这个 permission set 的作用，就是给其他人
assume 用的，它的 trust relationship 是：
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "sso.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
```
可以被任何人 assume 过来。当任何人通过第三方登录以后，会创建一个新的 role 这个 role 才是最终在 aws sso 界面上创建的 role，这样通过中间的
assume 操作实现了限制登录的时间。

## 通过 Terraform 创建

```terraform
# It's used to get the SSO instance arns and identity_store_ids.
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssoadmin_instances
data "aws_ssoadmin_instances" "goudan" {}

resource "aws_ssoadmin_permission_set" "permission_set" {
  name             = "goudan_role"
  instance_arn     = tolist(data.aws_ssoadmin_instances.goudan.arns)[0]
  session_duration = "PT2H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin_4_permission_set" {
  instance_arn       = aws_ssoadmin_permission_set.permission_set.instance_arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  permission_set_arn = aws_ssoadmin_permission_set.permission_set.arn
}
```
