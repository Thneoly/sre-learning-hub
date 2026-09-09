# Lab 08 · Helm Chart 全生命周期：打包、坏升级、回滚与 OCI 分发

> 难度：★★☆ ｜ 考点：chart 开发（values/模板函数）/ release Secret 与 revision / `--wait`、`--atomic`、rollback / OCI registry 分发 ｜ 前置：第 08 章（08-helm）、03-docker/labs/08（本地 registry，需先把它跑起来）、练习集群可用 ｜ 预计 40~60 分钟

## 资源前置（先读再动手）

- 资源需求很低：本地 registry（registry:2）约 50MB 内存，`helm-lab08` 命名空间里最多 2 副本 demo-app Pod（requests 50m/64Mi each）——集群与 VM 本身的开销远大于本 lab 新增部分。动手前按任务 1 预检 registry 在跑即可。
- **收尾要求**：check.sh 通过后按 solution 末尾"收尾（判分之后）"段清理（`helm uninstall` + 删 `helm-lab08` 命名空间；`lab08-registry` 建议保留，volume 里有数据）——**先判分再清理**，check.sh 依赖 release Secret、Deployment 与 registry API 在线。

## 场景

团队要把 demo-app 应用打包成 Helm chart 交付：开发者改 chart、CI 负责升级发布，发布必须有保底——坏版本要么被人手动回滚，要么被 `--atomic` 自动回退；chart 本体要发布到内部 OCI registry 供别的环境拉取安装。你是第一次走完整流程的人，需要把 chart 的"出厂改造 → lint → 安装 → 升级 → 坏升级 → 回滚 → atomic → push/pull"全链路跑通并留下可核查的证据。

约定（判分脚本按此检查）：

- 工作目录 `~/labs/helm-chart`，chart 名 `demo-app`（`helm create demo-app` 出厂结构）；
- release 名 `demo-app`，命名空间 `helm-lab08`；本地 registry 复用 03-docker/labs/08 的 `lab08-registry`（`localhost:5000`，volume `lab08-data`）；
- chart 发布到 `oci://localhost:5000/charts/demo-app`，版本 `0.2.0`；pull 回来的包放在 `~/labs/helm-chart/pulled/`。

## 任务清单

1. **前置**：确认本地 registry 在跑。若 03-docker/labs/08 的 `lab08-registry` 容器不存在，按该 lab 的方式启动（registry:2、`5000:5000`、volume `lab08-data`、`--restart always`），`curl http://localhost:5000/v2/` 返回 `{}`。
2. `helm create demo-app`，按第 08 章实战的方式改造出厂模板：values 增加 probes（enabled/path）与 resources（requests 50m/64Mi、limits 128Mi），deployment 模板加条件渲染的 livenessProbe/readinessProbe。注意第 08 章踩过的坑：出厂 `values.yaml` 已有 `resources: {}`，**先删再追加**，否则重复键报错；出厂还自带 `livenessProbe:`/`readinessProbe:` 默认块，**也要删掉**（否则 `probes.enabled=false` 时探针不消失，渲染产物还会出现重复键）。
3. `helm lint demo-app` 通过；`helm template` 渲染验证 probes 与 resources 缩进正确，`--set probes.enabled=false` 时探针消失。
4. `helm package` 后 `helm upgrade --install demo-app ... -n helm-lab08 --create-namespace --wait`（revision 1），确认 Pod Running；观察 release Secret：命名形如 `sh.helm.release.v1.demo-app.v1`。
5. 正常升级：replicaCount 1→2（revision 2），`helm history` 与 Deployment 副本核对。
6. **坏升级（假成功场景）**：不带 `--wait`，`--set image.tag=this-tag-does-not-exist` 升级——命令"成功"返回但镜像是坏的；用 `kubectl get pods` 证明实际不健康，`helm history` 里该 revision 仍标 deployed。这就是第 08 章说的"没有 --wait 的成功可能毫无意义"。
7. 手动 `helm rollback` 回到 revision 2，确认副本与镜像恢复正常（rollback 产生新 revision，只增不减）。
8. **atomic 保底**：再次用坏 tag 升级但加 `--atomic --timeout 2m`——命令以非零退出码失败并自动回退；`helm history` 末尾多出 failed 与自动回滚的记录，Deployment 保持健康。
9. bump chart 版本为 `0.2.0`，`helm package` 后 `helm push <tgz> oci://localhost:5000/charts --plain-http`（明文 HTTP registry 必须带此 flag，见提示 3）；`curl` registry API 确认 `charts/demo-app` 与 tag `0.2.0` 存在；`helm show chart oci://... --plain-http` 看元数据；`helm pull ... --plain-http` 到 `pulled/` 目录，解开核对 Chart.yaml 版本。

## 验收标准

终态（kubectl / curl / 文件只读可验证）：

- `helm-lab08` 命名空间存在 `sh.helm.release.v1.demo-app.v*` 命名的 Secret，数量（revision 数）**≥ 4**，且存在 `status=deployed` 标签的 release Secret；
- Deployment `demo-app` Available、replicas 2/2、容器带 livenessProbe 与 resources（requests.memory 为 64Mi——按约定清单第 2 条的值）；
- 当前镜像**不含**坏 tag（`this-tag-does-not-exist` 不出现在 Deployment 镜像里）；
- `curl http://localhost:5000/v2/_catalog` 含 `charts/demo-app`，`/v2/charts/demo-app/tags/list` 含 `0.2.0`；
- `~/labs/helm-chart/pulled/demo-app-0.2.0.tgz` 存在。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：为什么第 6 步 helm 会"假成功"？</summary>

Helm 默认的成功标准只是"资源已 apply 到 API Server"，不验证运行健康。镜像 tag 不存在时 API Server 照样接受 Deployment，拉镜像失败发生在 kubelet——命令早已返回成功。`--wait` 把成功定义改成 Deployment available 才返回；`--atomic` 再加一层"失败自动 rollback"。详见第 08 章第 5 节与自测第 3 题。

</details>

<details><summary>提示 2：rollback 之后 revision 号为什么不是倒退的？</summary>

release 历史是只追加的：rollback = 把旧 revision 的内容重新应用一遍并**新增一条记录**（`helm history` 里显示为 rollback 类型）。所以做完 1→2→3(坏)→rollback→atomic(坏) 后 revision 总数会到 5~6，满足判分"≥4"。

</details>

<details><summary>提示 3：helm push 到 localhost:5000 要配 TLS 吗？</summary>

不用配证书，但要加 `--plain-http`。helm 3.8+ OCI 已 GA；旧版 helm 曾把 `localhost`/`127.0.0.1` 自动视为 insecure（明文 HTTP），新版（实测 v3.21）不再自动降级——明文 registry 必须显式 `--plain-http`，否则报 `blob upload Location ... downgrades scheme from https`。`helm show` / `helm pull` / `helm upgrade --install oci://...` 同理。换成 VM 对外 IP 同样走 `--plain-http` 或配 TLS（03-docker/labs/08 提示 1 的同理）。helm 版本用 `helm version --short` 确认 ≥ v3.8。

</details>

<details><summary>提示 4：release Secret 去哪看？labels 是什么？</summary>

`kubectl -n helm-lab08 get secret` 直接能看到 `sh.helm.release.v1.demo-app.vN`。每个 Secret 带 labels：`owner=helm`、`name=<release名>`、`status=deployed/pending-upgrade/failed...`、`version=N`——判分脚本就用 label selector 找 deployed。这是第 08 章第 5 节"release 元数据存在目标命名空间 Secret"的现场证据。

</details>

<details><summary>提示 5：--atomic 那步命令失败了，怎么让脚本继续跑？</summary>

这是预期行为：`--atomic` 失败时以非零退出码返回（这正是它比裸 upgrade 强的地方）。命令行里写 `helm upgrade ... --atomic || echo "预期失败：已自动回退"`，然后看 `helm history` 收尾。

</details>
