# 发布元数据：01-cks-lab-apiserver-paralysis

> 本文件是发布运营信息，不要粘贴进掘金正文。out/ 下的同名 .md 才是纯净可贴的终稿。

标签：`Kubernetes` `CKS` `安全` `踩坑` `SRE`

发布策略：

- 工作日晚 8-10 点发布
- 发布后 30 分钟内自回复一条置顶评论，只放正文里没有的东西：
  1. 书站链接：https://thneoly.github.io/sre-learning-hub
  2. 一个批量扫描 /etc/kubernetes/manifests/ 下所有静态 Pod manifest 是否引用
     Secret/ConfigMap 等 API 资源的检测脚本（呼应正文「10 秒自检」一节）
- 注意：恢复脚本和 EncryptionConfiguration 正文已完整给出，评论区不要重复贴，
  否则读者追过去发现没有新东西，互动反而变负体验
- 备选标题（可 A/B）：「给静态 Pod 挂 Secret？kubelet 会当场处决你的 apiserver」
