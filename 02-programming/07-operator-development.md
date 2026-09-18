# 07 · CRD 与 Operator 开发：把运维知识写进控制循环

> 模块：02-programming ｜ 建议时长：7 小时 ｜ 关联认证：—（无直接考点；是 04-k8s-fundamentals 声明式控制循环的亲手实现，也是读懂各类开源/自研 Operator 的钥匙）

## 学习目标

- 能解释 CRD / CR / 自定义控制器 / Operator 四个概念的关系，说出"扩展 k8s = 注册一对新 API + 新控制循环"
- 能写出 CronTab 风格的 API 类型定义（GVK、spec/status 分工、markers），生成并部署 CRD、创建 CR
- 能读懂并写出 controller-runtime 的 Reconcile：level-triggered、幂等、只在变化时写 status
- 能用 kubebuilder 搭出项目骨架，跑通 make manifests → make install → make run → CR 创建 → 子资源出现的完整闭环
- 能把 [05 章](./05-go-for-sre.md)手写的 Informer 认知映射到 Manager/Cache/workqueue，并说出 webhook 在 apiserver 请求链的哪个环节介入

## 1. 概念对齐：k8s 的扩展模型

[04-k8s-fundamentals/01 §4](../04-k8s-fundamentals/01-why-kubernetes.md) 给出过所有控制器的共同形状：**取期望状态 → 取实际状态 → 补差值**，无限循环。kube-controller-manager 里几十个循环管的是内置资源（Deployment→Pod、Node→Pod 驱逐）。k8s 把这套机制原样开放出来：你注册自己的 API，跑自己的循环——这就是扩展模型的全部（概念全景见 [04-k8s-fundamentals/15 扩展模型](../04-k8s-fundamentals/15-extension-model.md)，本章负责"动手写"）。

| 概念 | 是什么 | 谁来写 |
|---|---|---|
| CRD（CustomResourceDefinition） | 新资源类型的 schema，注册进 apiserver，kubectl 与 etcd 立刻认识它 | 平台/Operator 作者 |
| CR（Custom Resource） | 该类型的实例，用户 `kubectl apply` 的对象 | 用户 |
| 自定义控制器 | watch CR 并调谐实际状态的循环进程（Go + client-go/controller-runtime） | Operator 作者 |
| Operator | "CRD + 控制器 + 某个运维领域的知识"的打包交付物（部署/扩缩/备份/恢复自动化） | Operator 作者 |

```
 kubectl apply（CronTab CR，期望状态）
        │  watch（list-watch，见 04-k8s-fundamentals/02 §6）
        ▼
 kube-apiserver ◄──► etcd            ← CRD 已提前注册 CronTab 这类对象
        │
 你的 Operator（普通 Go 进程，跑在 Deployment 里）
   Reconcile：期望（ct.spec） vs 实际（现存 CronJob）
        │ create/update/delete（子资源带 ownerReferences）
        ▼
 CronJob ──(内置控制器)──► Job ──► Pod ──(kubelet 执行)
```

两个容易误解的点：**Operator 不是 apiserver 的插件**——它就是用 [05 章](./05-go-for-sre.md)的 client-go 机制 watch 集群的普通进程，挂了只影响"没人调谐 CR"，集群本身无恙；**CRD 只是"数据结构"，不含行为**——没有控制器时 CR 只是躺在 etcd 里的空壳，行为全部在你写的 Reconcile 里。真实参照物：[11-otel/04](../11-otel/04-k8s-deployment-and-operator.md) 部署的 OTel Operator 就是同一套机制的产品化形态。扩展的另一条腿是 webhook（改/拦写进 etcd 的对象，见 §6）。

## 2. API 定义与 CRD 部署

### 2.1 GVK：资源的全名

- **Group**：按组织隔离命名空间，习惯用倒序域名（`stable.example.com`）；内置核心组为空（所以 Pod 的 apiVersion 就是 `v1`）
- **Version / Kind**：版本（`v1`……成熟度阶梯）与类型名（`CronTab`）；apiVersion = group/version，`kubectl api-resources --api-group=...` 可查已注册的组

### 2.2 类型定义：Go 类型即真相

```go
// [任意节点] api/v1/crontab_types.go —— kubebuilder 脚手架生成后你主要编辑的文件
package v1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// CronTabSpec 用户想要的：spec 永远是用户的领地
type CronTabSpec struct {
	CronSpec string `json:"cronSpec"`           // 必填：调度表达式
	Image    string `json:"image"`              // 任务镜像
	Replicas int32  `json:"replicas,omitempty"` // CronJob 无对应字段，留作扩展点
}

// CronTabStatus 控制器观察到的：status 永远是控制器的领地
type CronTabStatus struct {
	Phase string `json:"phase,omitempty"` // Pending / Ready
}

//+kubebuilder:object:root=true
//+kubebuilder:subresource:status
//+kubebuilder:printcolumn:name="Cron",type=string,JSONPath=`.spec.cronSpec`

// CronTab is the Schema for the crontabs API
type CronTab struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec   CronTabSpec   `json:"spec,omitempty"`
	Status CronTabStatus `json:"status,omitempty"`
}

//+kubebuilder:object:root=true
type CronTabList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []CronTab `json:"items"`
}

func init() { SchemeBuilder.Register(&CronTab{}, &CronTabList{}) }
```

`//+kubebuilder:` 注释是给 controller-gen 的指令（markers）：`object:root=true` 声明 CRD 顶层类型，`subresource:status` 把 status 拆成独立子资源（用户改不进 status、控制器可单独更新它），`printcolumn` 决定 `kubectl get` 的列。json tag 是 CRD schema 的直接来源——**手写 CRD YAML 容易漏字段，从 Go 类型生成则永远与代码一致**。

### 2.3 生成与部署

```bash
# [任意节点] kubebuilder 脚手架内
make generate     # 生成 api/v1/zz_generated.deepcopy.go（勿手改）
make manifests    # 生成 config/crd/bases/stable.example.com_crontabs.yaml
# [master] 部署 CRD 并等聚合层就绪
kubectl apply -f config/crd/bases/stable.example.com_crontabs.yaml
kubectl wait --for=condition=Established crd/crontabs.stable.example.com --timeout=30s

# [master] 创建一个 CR：此刻它只是躺在 etcd 里的空壳
kubectl apply -f - <<'EOF'
apiVersion: stable.example.com/v1
kind: CronTab
metadata:
  name: demo
spec:
  cronSpec: "*/1 * * * *"
  image: busybox:1.36
  replicas: 1
EOF
kubectl get crontabs        # 能列出 demo，status 为空——还没有控制器认领
```

一个必须知道的语义：v1 CRD 要求 **structural schema**，未在 schema 里声明的字段会在写入时被**静默剪掉**（pruning）——"我 apply 的字段怎么不见了"几乎都栽在这里。解法就是本节的路线：字段以 Go 类型为准、由工具生成 schema，不手搓 YAML。

## 3. controller-runtime 与 Reconcile 循环

### 3.1 库的分工

controller-runtime 是 kubebuilder 背后的运行时库（Kubernetes SIG 官方维护），把 [05 章 §5](./05-go-for-sre.md) 手写的 Informer 骨架封装成三个角色：

| 角色 | 职责 |
|---|---|
| Manager | 进程总管：连接配置、缓存、健康探针、metrics、leader 选举、优雅退出 |
| Cache | 每种 GVK 一个共享 informer，读请求走本地缓存（读写分离） |
| Controller | 事件 → workqueue（去重、限速、指数退避）→ 你的 Reconcile |

### 3.2 Reconcile 的契约

`Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error)`——签名本身就是三条铁律：

| 铁律 | 含义 |
|---|---|
| req 只有名字 | 拿到 namespace/name 后自己 Get 最新对象——不假设"为什么被触发"。事件（edge）会丢会重，当前状态（level）不会 |
| 返回值三态 | 返回 `error` → workqueue 指数退避重试；返回 `Result{RequeueAfter: d}` → 周期性对账；全空 → 本轮结束等下个事件 |
| 幂等 | 同一对象跑 N 次结果一致。事件至少一次投递，重复调谐是常态——与 [06-celery §6.2](./06-celery-task-queue.md) 的 at-least-once 幂等是同一条纪律 |

level-triggered 是与脚本思维的分水岭：脚本问"发生了什么"，Reconcile 问"现在该是什么样"。

### 3.3 可运行的 Reconcile：CronTab → CronJob

```go
// [任意节点] internal/controller/crontab_controller.go（kubebuilder v4 布局；v3 为 controllers/）
package controller

import (
	"context"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	crontabv1 "example.com/crontab-operator/api/v1"
)

// CronTabReconciler reconciles a CronTab object
type CronTabReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// RBAC 同样用 markers 声明，make manifests 生成 config/rbac/role.yaml
//+kubebuilder:rbac:groups=stable.example.com,resources=crontabs,verbs=get;list;watch
//+kubebuilder:rbac:groups=stable.example.com,resources=crontabs/status,verbs=get;update;patch
//+kubebuilder:rbac:groups=batch,resources=cronjobs,verbs=get;list;watch;create;update;patch;delete

func (r *CronTabReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	// 1. 取期望状态。NotFound = CR 已删除：子 CronJob 靠 ownerReferences 级联回收（04-k8s-fundamentals/01 §6）
	var ct crontabv1.CronTab
	if err := r.Get(ctx, req.NamespacedName, &ct); err != nil {
		if apierrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err // 基础设施故障：交给 workqueue 退避重试
	}

	// 2. 取实际状态：用一个与 CR 同名同 namespace 的 CronJob 承载
	var cj batchv1.CronJob
	err := r.Get(ctx, req.NamespacedName, &cj)

	switch {
	case apierrors.IsNotFound(err): // 缺失 → 创建，并声明属主（级联删除的钩子）
		desired := &batchv1.CronJob{
			ObjectMeta: metav1.ObjectMeta{Name: ct.Name, Namespace: ct.Namespace},
			Spec: batchv1.CronJobSpec{
				Schedule: ct.Spec.CronSpec,
				JobTemplate: batchv1.JobTemplateSpec{Spec: batchv1.JobSpec{
					Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{
						RestartPolicy: corev1.RestartPolicyOnFailure,
						Containers:    []corev1.Container{{Name: "worker", Image: ct.Spec.Image}},
					}},
				}},
			},
		}
		if err := ctrl.SetControllerReference(&ct, desired, r.Scheme); err != nil {
			return ctrl.Result{}, err
		}
		if err := r.Create(ctx, desired); err != nil && !apierrors.IsAlreadyExists(err) {
			return ctrl.Result{}, err
		}

	case err != nil: // 真实的读取故障
		return ctrl.Result{}, err

	default: // 存在 → 对账漂移：期望变了就收敛实际
		containers := cj.Spec.JobTemplate.Spec.Template.Spec.Containers
		if cj.Spec.Schedule != ct.Spec.CronSpec ||
			(len(containers) > 0 && containers[0].Image != ct.Spec.Image) {
			cj.Spec.Schedule = ct.Spec.CronSpec
			containers[0].Image = ct.Spec.Image
			if err := r.Update(ctx, &cj); err != nil {
				return ctrl.Result{}, err
			}
		}
	}

	// 3. 写 status：只在值变化时写——无条件 Update = 事件 → 调谐 → 写 → 再事件的死循环
	if ct.Status.Phase != "Ready" {
		ct.Status.Phase = "Ready"
		if err := r.Status().Update(ctx, &ct); err != nil {
			return ctrl.Result{}, err
		}
	}
	return ctrl.Result{}, nil
}

// SetupWithManager 把 05 章手写的 AddEventHandler + 启动 + 等缓存收敛成两行声明
func (r *CronTabReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&crontabv1.CronTab{}).
		Owns(&batchv1.CronJob{}).
		Complete(r)
}
```

读这段代码的三个观察点：全程没有"事件类型"分支——Add/Update/Delete 统一收敛成"看一眼当前该是什么样"；`r.Get` 走本地缓存、`r.Create/Update` 直达 apiserver（[05 章 §5](./05-go-for-sre.md) 的读写分离被 Client 一层封装）；删除路径一行都没写——级联回收外包给 garbage collector，只有需要清理**集群外**资源（云盘、外部 DNS 记录）时才需要 finalizer（[04-k8s-fundamentals/01 §7](../04-k8s-fundamentals/01-why-kubernetes.md)）。

## 4. kubebuilder 项目骨架

```bash
# [任意节点] 安装 kubebuilder（版本与系统以官方 quickstart 为准）
curl -L -o kubebuilder "https://go.kubebuilder.io/dl/latest/$(go env GOOS)/$(go env GOARCH)"
chmod +x kubebuilder && sudo mv kubebuilder /usr/local/bin/ && kubebuilder version
# [任意节点] 骨架两步：init 生成工程，create api 生成类型/控制器/CRD/RBAC 初稿
mkdir crontab-operator && cd crontab-operator
kubebuilder init --domain example.com --repo example.com/crontab-operator
kubebuilder create api --group stable --version v1 --kind CronTab --resource --controller

# 把 §2 的类型填进 api/v1/crontab_types.go、§3 的 Reconcile 填进
# internal/controller/crontab_controller.go，然后：
make manifests generate         # 类型 → CRD；markers → RBAC
make install                    # apply CRD（需 kustomize，脚手架会自动准备）
make run                        # 本地跑控制器进程，连练习集群，日志直接可见
```

`cmd/main.go` 需要看懂的只有三段（脚手架生成，节选）：

```go
// [任意节点] cmd/main.go 节选（省略处以脚手架产物为准）
scheme := runtime.NewScheme()
utilruntime.Must(clientgoscheme.AddToScheme(scheme))
utilruntime.Must(crontabv1.AddToScheme(scheme))   // 你的类型注册进 scheme，client 才认得

mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
	Scheme:                 scheme,
	HealthProbeBindAddress: ":8081",   // liveness/readiness 探针；LeaderElection 多副本时开
})

if err = (&controller.CronTabReconciler{         // 挂上 §3 的控制器
	Client: mgr.GetClient(),
	Scheme: mgr.GetScheme(),
}).SetupWithManager(mgr); err != nil {
	setupLog.Error(err, "unable to create controller", "controller", "CronTab")
	os.Exit(1)
}
```

本地 `make run` 用你 kubeconfig 的身份（练习集群是 admin，RBAC 不拦）；部署进集群则换 ServiceAccount，权限边界就是 markers 生成的 role.yaml。交付成 Deployment：`make docker-build docker-push IMG=<registry>/crontab-operator:v0.1.0 && make deploy IMG=<同>`。

## 5. Informer / workqueue：与 05 章手写版的衔接

[05 章 §5](./05-go-for-sre.md) 手写的 SharedInformerFactory + AddEventHandler，在 controller-runtime 里各归其位：

| 05 章手写 | controller-runtime 对应物 | 你额外得到的 |
|---|---|---|
| `informers.NewSharedInformerFactory` | Manager 的 Cache（内部仍是 informer/reflector） | 按 GVK 共享 informer，多控制器复用一份缓存 |
| `AddEventHandler(Add/Update/Delete)` | `.For(&CronTab{}).Owns(&CronJob{})` | 事件映射一行声明，子资源事件自动归因到属主再入队 |
| 自己在回调里防抖/去重 | workqueue（限速队列） | 同一 key 自动合并去重、指数退避、并发 worker |
| `cache.WaitForCacheSync` | `mgr.Start` 内部完成 | 缓存未同步前不消费事件 |
| clientset 读写都打 apiserver | mgr 的 Client | 读走缓存、写直达 apiserver（delegating client） |

连并发模型都是熟面孔：workqueue 的 worker 就是固定工人数的 [worker pool（05 章 §3.3）](./05-go-for-sre.md)，默认 1 个，用 `.WithOptions(controller.Options{MaxConcurrentReconciles: N})` 调大——**并发上限 = worker 数**，且同一 key 同时只有一个 Reconcile 在跑，所以 Reconcile 内部不需要对自己加锁。05 章关于 resourceVersion、watch 断线 410 重置、resync 兜底的结论在这里原样成立：Cache 断线重连对 Reconcile 完全透明，恢复后涌来的一批 Reconcile 恰好是 level-triggered 不怕的形态。

## 6. webhook 概览

[04-k8s-fundamentals/02 §2](../04-k8s-fundamentals/02-architecture-and-control-loop.md) 的 apiserver 请求链里，认证授权之后、写 etcd 之前有两道准入关卡，webhook 就挂在这（追加骨架用 `kubebuilder create webhook --group stable --version v1 --kind CronTab --defaulting --validation`）：

```
 kubectl ─► 认证 ─► 授权 ─►【mutating 准入】─► schema 校验/合并 ─►【validating 准入】─► etcd
                              ▲ 默认值注入                                     ▲ 拒绝非法
                              └───────── 你的 Operator 暴露的 HTTPS 服务 ───────┘
```

| 类型 | 做什么 | 例子 |
|---|---|---|
| mutating（defaulting） | 落库前最后一次改对象 | cronSpec 为空时补 `0 0 * * *` |
| validating | 校验并**拒绝**请求 | cronSpec 不是合法 cron 表达式 → 整个 apply 报错 |
| conversion | CRD 多版本互转 | v1beta1 ↔ v1 字段迁移 |

```go
// [任意节点] api/v1/crontab_webhook.go 节选（cron 解析用 github.com/robfig/cron/v3）
//+kubebuilder:webhook:path=/validate-stable-example-com-v1-crontab,mutating=false,failurePolicy=fail,groups=stable.example.com,resources=crontabs,verbs=create;update,versions=v1,name=vcrontab-v1.kb.io,sideEffects=none,admissionReviewVersions=v1

func (r *CronTab) ValidateCreate() (admission.Warnings, error) {
	if _, err := cron.ParseStandard(r.Spec.CronSpec); err != nil {
		return nil, fmt.Errorf("cronSpec 非法: %w", err)
	}
	return nil, nil
}
```

策略类的通用校验（禁用 latest 标签、强制镜像仓库前缀）用 Kyverno/OPA 这类策略引擎更划算；需要理解业务语义的默认值与校验才值得写进 Operator 的 webhook。两条运维红线：webhook 是 apiserver 的**同步依赖**——`failurePolicy=fail` 且 webhook 不可达时，匹配对象的全部 create/update 都被阻塞，包括别人滚动更新你的 CR；证书（脚手架默认自签，生产常配 cert-manager）过期同样锁死写路径，所以 webhook 的 Deployment 必须多副本、有探针，排障入口 `kubectl get validatingwebhookconfigurations`，紧急恢复手段是删掉对应配置——先恢复链路，再修 webhook。

## 实战演练

```bash
# [任意节点] 0. 前置：Go 1.22+、练习集群 kubeconfig、模块可拉取（GOPROXY 见 05 章常见坑）；
#    §4 的骨架三步 + 填入 §2/§3 的两个文件，CRD 已就位后本地跑控制器
make manifests generate && make install && make run

# [master] 2. 创建 CR，观察子资源与 status
kubectl apply -f config/samples/stable_v1_crontab.yaml
kubectl get crontabs -o wide                    # Phase 变 Ready
kubectl get cronjob demo -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'   # CronTab，出现同名 CronJob

# [master] 3. 改期望看对账：level-triggered 的直接体验
kubectl patch crontab demo --type=merge -p '{"spec":{"cronSpec":"*/5 * * * *"}}'
kubectl get cronjob demo -o jsonpath='{.spec.schedule}{"\n"}'   # 跟着变成 */5 ...

# [master] 4. 制造子资源漂移，验证自愈
kubectl set image cronjob/demo worker=nginx:1.27
kubectl get cronjob demo -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}{"\n"}'
# make run 的终端打出 updated CronJob：Owns() 把手改的镜像拉回 ct.spec.image

# [master] 5. 删 CR 看级联（04-k8s-fundamentals/01 §6 的属主链在自家 CR 上重演）
kubectl delete crontab demo && sleep 3 && kubectl get cronjob   # demo 一并消失
```

验证：步骤 2 status.phase=Ready 且 CronJob 的 ownerReferences 指向 CronTab；步骤 3/4 任何"破坏期望"的操作数秒内被拉回；步骤 5 级联删除发生。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `kubectl get crontabs` 报 the server doesn't have a resource type | CRD 未 apply 或未 Established | `make install`；`kubectl wait --for=condition=Established crd/...` |
| `make run` 报 no matches for kind "CronTab" | manifests 未重新生成/未安装 | `make manifests generate && make install` 后重跑 |
| 控制器日志无限刷 updated | status 无条件 Update，写完又触发自己 | status 仅在值变化时写；subresource 分离 spec/status |
| CR 改了但子资源不变 | Reconcile 写成了 edge 逻辑（只在创建时看一次期望） | 每轮全量对账：Get 期望 → Get 实际 → 差值收敛 |
| 手改 CronJob 后漂移不修复 | 没声明 `Owns(&batchv1.CronJob{})` | 加上 Owns，子资源事件归因属主再入队 |
| CR 卡在 Terminating | 控制器加了 finalizer 后自己挂了 | [04-k8s-fundamentals/01 §7](../04-k8s-fundamentals/01-why-kubernetes.md)：确认外部资源已处理再清 finalizer |
| 装了 webhook 后 kubectl apply 全部超时 | webhook 不可达且 failurePolicy=fail | 删 validating/mutatingwebhookconfiguration 先恢复链路，再修 webhook 与证书；RBAC forbidden 则检查 markers 生成的 role.yaml 是否覆盖 status 子资源 |
| apply 的字段静默消失 | CRD schema 未声明该字段，被 pruning（§2.3） | 字段从 Go 类型生成；检查 json tag 是否漏写 |

## 自测

<details><summary>1. 为什么 Reconcile 收到的是"名字"而不是"事件对象"？如果设计成直接传事件会出什么问题？</summary>

事件是 edge 语义：会丢失（informer 断线重连的缝隙）、会重复（至少一次投递）、会乱序；对象名是 level 的锚点——拿着名字 Get 一次永远拿到当前真相。若直接传事件对象，控制器的正确性就依赖"我没错过任何事件"这个不成立的前提：watch 断线期间的增删改全部丢失且无从感知，状态从此漂移。level-triggered 把正确性从"事件不丢不重"转移到"每轮全量对账 + 幂等"，天然容忍事件丢失与重复——这也是 controller-runtime 里连事件类型都对 Reconcile 不可见的原因。
</details>

<details><summary>2. status 无条件 `r.Status().Update()` 为什么会造成死循环？画出事件链。</summary>

Reconcile 写 status → apiserver 更新对象、推进 resourceVersion → informer 收到该 CronTab 的 Update 事件 → 同一 key 入队 → 再次 Reconcile → 再次写 status（值没变，Update 仍产生新 resourceVersion）→ 无限循环。表现为日志刷屏、apiserver 写 QPS 异常。斩断手段：先比较后写（Phase 变了才 Update）；`subresource:status` 让这类写只影响 status 子资源；必要时在 SetupWithManager 加 predicates 过滤纯 status 变化的事件。
</details>

<details><summary>3. structural schema 的 pruning 语义是什么？为什么"从 Go 类型生成 CRD"比手写 CRD YAML 更稳？</summary>

pruning：写入 CR 时凡是不在 OpenAPI schema 里声明的字段直接丢弃且不报错——错误从"显式失败"变成"静默消失"，排查极难。手写 YAML 时 json tag 漏写、嵌套结构手滑，对应字段都会被剪掉而你只看到"字段不见了"。从 Go 类型经 controller-gen 生成，schema 与控制器实际读写的结构体同源：字段改名或删掉时编译器立刻报错，schema 永远覆盖代码用到的字段。
</details>

<details><summary>4. `Owns(&batchv1.CronJob{})` 不加会发生什么？它和 ownerReferences 是什么关系？</summary>

不加则控制器只 watch CronTab 自身：有人手改 CronJob 的镜像/schedule、或别的系统删了它时，期望状态（CR）没变就不触发 Reconcile，漂移永远无人纠正。Owns 声明"子资源事件也算我的"：子资源事件携带的 ownerReferences 被映射回属主 CronTab 再入队，同一套对账逻辑自然覆盖子资源。ownerReferences 是 apiserver 层的元数据（级联删除的依据），Owns 是控制器层对这份元数据的消费——一份数据两处受益。
</details>

<details><summary>5. webhook 的 failurePolicy=fail 与 ignore 怎么选？为什么 webhook 部署的可用性要求比控制器高一个量级？</summary>

fail：webhook 不可达时请求被拒——守住"所有入库对象都过校验"的不变量，代价是把写路径可用性绑死在 webhook 上。ignore：不可达时放行——链路可用，但校验存在失效窗口。关键校验默认用 fail，但必须按"apiserver 的同步依赖"规格部署：多副本、探针、证书自动轮换。可用性差异的根源在故障半径：控制器挂了只是"暂时没人调谐"，apiserver 一切如常；webhook 挂了是 apiserver 的写路径直接受阻——匹配资源的 create/update 全部停摆，故障被放大到整个集群。
</details>

## 延伸阅读

- Kubebuilder Book（官方教程，本章骨架的权威版本）：https://book.kubebuilder.io/
- controller-runtime 仓库（Manager/Cache/Client 的设计与 godoc）：https://github.com/kubernetes-sigs/controller-runtime
- Kubernetes 官方：Custom Resource Definitions（含 pruning/structural schema）：https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Kubernetes 官方：Operator 模式：https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
