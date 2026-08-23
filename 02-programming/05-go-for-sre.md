# 05 · Go for SRE：选学进阶，通向 Operator

> 模块：02-programming ｜ 建议时长：6 小时 ｜ 关联认证：—（为 06 模块 CRD/Operator 开发与阅读 k8s 源码铺路）

## 学习目标

- 能解释云原生生态为什么选择 Go：单二进制、静态类型、原生并发、交叉编译
- 能读懂并修改典型 Go 程序：包/函数/结构体/接口/错误处理的最小集
- 能用 goroutine + channel + `sync.WaitGroup` 写受控并发程序（worker pool 模式）
- 能写出批量并发 HTTP 探测工具，并说出 `context` 超时传播的作用
- 能描述 client-go 的 Informer 机制（ListWatch + 本地缓存 + 事件回调），为 Operator 打底

---

## 1. 为什么云原生生态用 Go

| 特性 | 对 SRE 的实际意义 |
|---|---|
| 编译为单静态二进制 | `GOOS=linux GOARCH=amd64 go build` 得到一个文件，扔进 distroless/alpine 甚至 scratch 镜像就能跑，无运行时依赖 |
| 交叉编译 | 在 Windows/Mac 上为 Linux arm64 交叉编译，CI 一个命令产出全平台产物 |
| 原生并发（goroutine） | 几 MB 栈起步的轻量线程，百万级并发连接是 k8s 组件的日常 |
| 静态类型 + 编译期检查 | 重构工具时编译器替你兜住一大类错误，适合"半年改一次"的运维工具 |
| 标准库即平台 | net/http、encoding/json、context 开箱即用，少拉第三方依赖 |

生态事实：Kubernetes、Docker/containerd、Prometheus、etcd、Istio、CoreDNS、Calico 全是 Go。读它们的源码、给它们写扩展（Operator、 Admission Webhook、自定义 controller），Go 是唯一入口——这就是本章存在的理由。

```bash
# [任意节点] Ubuntu 22.04/24.04 安装（以 go.dev 官方下载为准，版本号查询官网）
sudo apt-get update && sudo apt-get install -y golang-go
go version

# [任意节点] 五分钟验证"单二进制"：写的程序编译后扔到无 Go 环境的目录也能跑
mkdir -p ~/hello && cd ~/hello && go mod init hello
cat > main.go <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("hello from go")
}
EOF
go build -o hello . && ./hello && ldd hello || echo "static binary: no .so deps"
```

---

## 2. 语法最小集：运维者视角

不需要系统学 Go，先掌握读改现有工具所需的骨架。

### 2.1 变量、函数、结构体

```go
// [任意节点] 保存为 ~/hello/basics/main.go，go run basics/main.go
package main

import "fmt"

// 结构体：k8s API 对象在 Go 里的形态就是结构体嵌套
type NodeInfo struct {
	Name    string  // 字段导出：大写开头 = 包外可见（JSON 序列化也认它）
	Ready   bool
	DiskPct float64
}

// 方法：挂在类型上的函数
func (n NodeInfo) Status() string {
	if n.Ready && n.DiskPct < 85 {
		return "healthy"
	}
	return "degraded"
}

func main() {
	// 变量声明的三种形态
	var count int          // 零值 0 —— Go 没有未初始化，只有零值
	name := "cka000001"    // 短声明，函数内最常用
	pct := 87.5            // 类型推断为 float64

	_ = count
	fmt.Printf("%s disk=%.1f%%\n", name, pct)

	node := NodeInfo{Name: "cka000001", Ready: true, DiskPct: 23.4}
	fmt.Println(node.Name, node.Status())

	// 切片与 map：运维数据结构双雄
	nodes := []string{"cka000001", "cka000002", "cka000003"}
	for i, n := range nodes {
		fmt.Println(i, n)
	}
	status := map[string]bool{"cka000001": true, "cka000002": false}
	if !status["cka000002"] {
		fmt.Println("cka000002 not ready")
	}
	// 注意：map 取不存在的 key 返回零值，不报错 —— 判断存在用 v, ok := m[k]
	v, ok := status["cka000009"]
	fmt.Println(v, ok) // false false
}
```

### 2.2 错误处理：Go 的哲学是"错误是值"

```go
// [任意节点] 保存为 ~/hello/errors/main.go
package main

import (
	"fmt"
	"os"
)

func readHosts() ([]byte, error) {
	data, err := os.ReadFile("/etc/hosts")
	if err != nil {          // Go 没有 try/except：每一步显式检查 err
		return nil, fmt.Errorf("read /etc/hosts: %w", err) // %w 包装，保留错误链
	}
	return data, nil
}

func main() {
	data, err := readHosts()
	if err != nil {
		fmt.Fprintln(os.Stderr, "fatal:", err)
		os.Exit(1)           // 退出码给 shell/cron 看，与 Python 章一致
	}
	fmt.Printf("read %d bytes\n", len(data))
}
```

`if err != nil` 会大量重复——这是特性不是缺陷：每个可能失败的点都被显式处理，读代码时控制流一目了然。`fmt.Errorf("...: %w", err)` 的包装链可用 `errors.Is` / `errors.As` 判因。

### 2.3 接口：k8s 一切抽象的底座

```go
// [任意节点] 保存为 ~/hello/iface/main.go
package main

import "fmt"

// 接口 = 方法集合。谁实现了这些方法，谁就是这个接口 —— 无需声明
type Notifier interface {
	Send(title, body string) error
}

type SlackNotifier struct{ Webhook string }
func (s SlackNotifier) Send(title, body string) error {
	fmt.Printf("slack -> %s: %s\n", s.Webhook, title)
	return nil
}

type LogNotifier struct{}
func (LogNotifier) Send(title, body string) error {
	fmt.Printf("log -> %s\n", title)
	return nil
}

// 调用方只依赖接口，不关心具体实现 —— 测试时可注入 fake
func alert(n Notifier, title string) {
	_ = n.Send(title, "auto body")
}

func main() {
	alert(SlackNotifier{Webhook: "https://hooks/x"}, "disk 91%")
	alert(LogNotifier{}, "disk 91%")
}
```

client-go 的 `clientset.Interface`、各种 `Fetcher`/`Reconciler` 全是这套玩法——**面向接口编程**让你能在测试里塞假实现、在 Operator 里替换缓存客户端。

---

## 3. goroutine 与 channel

### 3.1 心智模型

```
        main goroutine
             |
     go f()--+--go g()--+--go h()      # go 关键字 = 起一个并发执行体
             |          |
             v          v        (调度器把 goroutine 多路复用到 OS 线程)
        +----------------------------+
        |  Go runtime scheduler      |
        +----------------------------+
             |            |
        channel 是它们之间唯一的推荐通信方式:
        ch <- v   发送        v := <-ch   接收
        "不要通过共享内存来通信，而要通过通信来共享内存"
```

### 3.2 最小示例与最常见的坑

```go
// [任意节点] 保存为 ~/hello/conc/main.go
package main

import (
	"fmt"
	"sync"
	"time"
)

func main() {
	// 坑 1：main 不等 goroutine —— 注释掉 WaitGroup 相关行试试，程序直接退出
	var wg sync.WaitGroup
	for _, node := range []string{"cka000001", "cka000002", "cka000003"} {
		wg.Add(1)
		go func(n string) {           // Go 1.22 前必须把循环变量作参数传入
			defer wg.Done()
			time.Sleep(100 * time.Millisecond)
			fmt.Println("checked", n)
		}(node)
	}
	wg.Wait()

	// channel：生产者-消费者
	results := make(chan string, 3)   // 带缓冲，容量 3
	go func() {
		for _, n := range []string{"a", "b", "c"} {
			results <- n
		}
		close(results)                // 发送方 close，接收方 range 才能结束
	}()
	for r := range results {
		fmt.Println("got", r)
	}
}
```

三个纪律：起 goroutine 前先想好它怎么结束（`WaitGroup` 等待或 channel 关闭）；**发送方负责 close channel**，接收方 close 是经典 panic；无缓冲 channel 的收发会同步阻塞，用它当"汇合点"。

### 3.3 worker pool：受控并发（SRE 最常用形态）

```go
// [任意节点] 保存为 ~/hello/pool/main.go
package main

import (
	"fmt"
	"sync"
	"time"
)

type Job struct{ Host string }
type Result struct {
	Host string
	Err  error
}

func worker(id int, jobs <-chan Job, results chan<- Result, wg *sync.WaitGroup) {
	defer wg.Done()
	for j := range jobs {                 // channel close 后循环自动退出
		time.Sleep(50 * time.Millisecond) // 模拟 ssh 采集
		fmt.Printf("worker %d -> %s\n", id, j.Host)
		results <- Result{Host: j.Host}
	}
}

func main() {
	jobs := make(chan Job, 100)
	results := make(chan Result, 100)
	var wg sync.WaitGroup

	for w := 1; w <= 4; w++ {             // 固定 4 个 worker：并发上限天然受控
		wg.Add(1)
		go worker(w, jobs, results, &wg)
	}

	hosts := []string{"cka000001", "cka000002", "cka000003",
		"cka000004", "cka000005", "cka000006"}
	for _, h := range hosts {
		jobs <- Job{Host: h}
	}
	close(jobs)                           // 投递完毕，关闭输入

	go func() { wg.Wait(); close(results) }() // 全部 worker 结束后关闭输出

	for r := range results {              // 消费结果
		fmt.Printf("done: %s err=%v\n", r.Host, r.Err)
	}
}
```

与 Python 章的 `ThreadPoolExecutor` 对照：同样的"任务队列 + 固定工人 + 结果汇总"，Go 用两个 channel 与一个 WaitGroup 表达，且并发单元是用户态调度，开销远低于线程。**并发上限 = worker 数**，而不是任务数——这是它与 `go 一把梭` 的本质区别。

---

## 4. 实战：批量并发 HTTP 探测工具

综合运用：并发 + 超时 + 结果收集 + 退出码。这个工具稍加改造就是拨测平台的核心。

```go
// [任意节点] 保存为 ~/httpcheck/main.go，目录内 go mod init httpcheck
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"sync"
	"time"
)

type ProbeResult struct {
	URL      string `json:"url"`
	Status   int    `json:"status"`
	Duration string `json:"duration"`
	Err      string `json:"error,omitempty"`
}

func probe(ctx context.Context, client *http.Client, url string) ProbeResult {
	start := time.Now()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return ProbeResult{URL: url, Err: err.Error()}
	}
	resp, err := client.Do(req)
	d := time.Since(start)
	if err != nil {
		return ProbeResult{URL: url, Duration: d.String(), Err: err.Error()}
	}
	defer resp.Body.Close()
	return ProbeResult{URL: url, Status: resp.StatusCode, Duration: d.String()}
}

func main() {
	timeout := flag.Duration("timeout", 3*time.Second, "单请求超时")
	workers := flag.Int("workers", 8, "并发数")
	flag.Parse()

	urls := flag.Args()
	if len(urls) == 0 {
		fmt.Fprintln(os.Stderr, "usage: httpcheck [-timeout 3s] [-workers 8] URL...")
		os.Exit(2)
	}

	client := &http.Client{Timeout: *timeout}
	jobs := make(chan string)
	results := make(chan ProbeResult, len(urls))

	var wg sync.WaitGroup
	for i := 0; i < *workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for url := range jobs {
				// 每个请求一个可取消的 ctx：整体超时/中断可传播（此处演示独立超时）
				ctx, cancel := context.WithTimeout(context.Background(), *timeout)
				results <- probe(ctx, client, url)
				cancel() // 防泄漏：ctx 用完必须 cancel
			}
		}()
	}

	for _, u := range urls {
		jobs <- u
	}
	close(jobs)

	go func() { wg.Wait(); close(results) }()

	failed := 0
	var all []ProbeResult
	for r := range results {
		all = append(all, r)
		mark := "OK  "
		if r.Err != "" || r.Status >= 500 {
			mark = "FAIL"
			failed++
		}
		fmt.Printf("[%s] %3d %8s %s %s\n", mark, r.Status, r.Duration, r.URL, r.Err)
	}

	out, _ := json.MarshalIndent(all, "", "  ")
	fmt.Println(string(out))

	if failed > 0 {
		os.Exit(1) // 有失败：退出码 1，接 cron/告警
	}
}
```

```bash
# [任意节点] 构建、运行、交叉编译
cd ~/httpcheck && go build -o httpcheck .
./httpcheck -workers 4 -timeout 2s \
  http://127.0.0.1:6443/healthz \
  http://127.0.0.1:10248/healthz \
  http://127.0.0.1:2379/health 2>&1 | head -5
echo "exit=$?"

GOOS=windows GOARCH=amd64 go build -o httpcheck.exe .   # 交叉编译给 Windows
GOOS=linux  GOARCH=arm64 go build -o httpcheck-arm .    # 给 arm 节点
```

`context` 的意义浓缩在这段里：超时随 ctx 进入 `http.NewRequestWithContext`，请求层、连接层、重试层共享同一个截止时间，一处取消全线停止——这是 Go 并发代码"可停止"的关键，也是 client-go 里一切操作的第一个参数都是 `ctx` 的原因。

---

## 5. client-go：为 Operator 铺路

### 5.1 是什么

client-go 是 Kubernetes 官方 Go 客户端库，kube-controller-manager 自己就用它。读写集群的层级：

```
你的 Operator/工具
   |
   | client-go
   v
+------------------+     ListWatch(HTTP)     +---------------+
| Informer 框架     | <--------------------- | kube-apiserver |
|  - Lister(本地缓存)|                        +---------------+
|  - DeltaFIFO      |     watch 增量推送
|  - EventHandlers  | <---------------------
+------------------+
   | 事件回调: OnAdd/OnUpdate/OnDelete
   v
你的 Reconcile 逻辑 -> 写回 apiserver (clientset)
```

### 5.2 最小代码：列 Pod 的两种方式

```go
// [任意节点] 保存为 ~/k8sclient/main.go，目录内执行：
//   go mod init k8sclient
//   go get k8s.io/client-go@v0.29.0 k8s.io/api@v0.29.0 k8s.io/apimachinery@v0.29.0
// 版本与集群 minor 对齐，以 client-go README 的兼容表为准
package main

import (
	"context"
	"flag"
	"fmt"
	"path/filepath"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

func main() {
	var kubeconfig string
	if home := homedir.HomeDir(); home != "" {
		flag.StringVar(&kubeconfig, "kubeconfig",
			filepath.Join(home, ".kube", "config"), "kubeconfig 路径")
	}
	flag.Parse()

	// 1. 加载配置并构造 clientset —— 一切调用的入口
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		panic(err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err)
	}

	// 2. 方式 A：一次性 GET（等价 kubectl get pods）
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	pods, err := clientset.CoreV1().Pods("kube-system").List(ctx, metav1.ListOptions{})
	if err != nil {
		panic(err)
	}
	for _, p := range pods.Items {
		fmt.Printf("%s/%s %s\n", "kube-system", p.Name, p.Status.Phase)
	}
}
```

`clientset.CoreV1().Pods(ns).List(ctx, ...)` 与 `kubectl get pods` 一一对应；写操作同理（`Create`/`Update`/`Delete`）。高频场景不要每次都 List 打 apiserver——上 Informer：

```go
// [任意节点] 方式 B：Informer —— List 一次全量 + 之后只吃 watch 增量，本地缓存供读
package main

import (
	"fmt"
	"path/filepath"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

func main() {
	kc := filepath.Join(homedir.HomeDir(), ".kube", "config")
	config, _ := clientcmd.BuildConfigFromFlags("", kc)
	clientset, _ := kubernetes.NewForConfig(config)

	factory := informers.NewSharedInformerFactory(clientset, 30*time.Second)
	podInformer := factory.Core().V1().Pods().Informer()

	// 注册事件回调：这是 Operator 反应逻辑的挂点
	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj interface{}) {
			p := obj.(*corev1.Pod)
			fmt.Printf("ADD    %s/%s\n", p.Namespace, p.Name)
		},
		UpdateFunc: func(_, newObj interface{}) {
			p := newObj.(*corev1.Pod)
			fmt.Printf("UPDATE %s/%s %s\n", p.Namespace, p.Name, p.Status.Phase)
		},
		DeleteFunc: func(obj interface{}) {
			p := obj.(*corev1.Pod)
			fmt.Printf("DELETE %s/%s\n", p.Namespace, p.Name)
		},
	})

	stop := make(chan struct{})
	defer close(stop)
	factory.Start(stop)                                   // 启动 ListWatch
	cache.WaitForCacheSync(stop, podInformer.HasSynced)   // 等首次全量同步完成
	fmt.Println("cache synced, watching pods...")
	<-stop                       // 阻塞运行；kubelet 重启 Pod 时观察事件输出
}
```

运行后在另一个终端 `kubectl delete pod -n kube-system <某个deployment的pod>`，本程序会打出 ADD（重建）与 DELETE 事件。这就是 controller 的骨架：**watch 期望状态变化 → 对比实际 → 调谐（reconcile）**。06 模块的 CRD/Operator 开发（controller-runtime、kubebuilder）把这套骨架封装成了 `Reconcile(ctx, req)` 一个函数——本章的 Informer 认知正是读懂它的前置条件。

---

## 实战演练

```bash
# [任意节点] 1. 环境与单二进制验证
go version
cd ~/hello && go build -o hello . && file hello && ./hello

# [任意节点] 2. 并发对比：worker pool vs 串行
cd ~/hello/pool && go run main.go        # 6 任务 4 worker，总耗时约 6/4*50ms
cd ~/httpcheck && ./httpcheck -workers 1 http://127.0.0.1:6443/healthz
./httpcheck -workers 8 http://127.0.0.1:6443/healthz   # 观察 duration 差异

# [任意节点] 3. Informer 观察
cd ~/k8sclient && go run main.go          # 窗口 A，看到 "cache synced"
kubectl delete pod -n kube-system -l k8s-app=kube-proxy   # [master] 窗口 B
# 回到窗口 A：出现 DELETE 与 ADD（DaemonSet 重建）

# [任意节点] 4. 交叉编译产物检查
cd ~/httpcheck && GOOS=linux GOARCH=arm64 go build -o httpcheck-arm . && file httpcheck-arm
```

验证：步骤 1 输出 hello 且 `file` 显示 executable；步骤 2 worker pool 版总耗时明显小于任务数×单任务耗时；步骤 3 能实时看到 Pod 删除与重建事件；步骤 4 `file` 显示 ARM aarch64 目标格式。

---

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 程序跑完 goroutine 输出没出现 | main 先退出，不等 goroutine | `sync.WaitGroup`：Add/Done/Wait 三件套 |
| `fatal error: all goroutines are asleep - deadlock` | 无缓冲 channel 收发双方都在等，或忘了 close | 检查发送方 close；缓冲容量覆盖生产量 |
| `send on closed channel` panic | 多个发送方/接收方误 close | 只有唯一发送方 close；多发送方用 WaitGroup 汇合后统一 close |
| go.mod 里 client-go 版本与集群不匹配导致 API 报错 | client-go 与集群 minor 版本需对齐 | 查 client-go README 兼容矩阵，pin `k8s.io/client-go@v0.XX.0` |
| goroutine 里循环变量全是最后一个值 | Go 1.22 前循环变量复用 | 把变量作参数传给 goroutine，或升级 Go 1.22+ |
| ctx 泄漏（pprof goroutine 持续增长） | `WithTimeout` 后没 `cancel()` | `defer cancel()` 紧跟创建处 |
| 编译慢/拉依赖失败 | GOPROXY 默认不可达 | `go env -w GOPROXY=https://goproxy.cn,direct`（国内环境） |
| `undefined: v1.Pod` | API 类型按组/版本分包 | import `corev1 "k8s.io/api/core/v1"` 等别名 |

---

## 自测

<details><summary>1. 为什么 Kubernetes 生态的镜像可以是 distroless/scratch，而 Python 工具镜像必须带解释器？这对部署意味着什么？</summary>

Go 编译产物把运行时（runtime、GC、调度器）全部静态链进单个二进制，基础镜像只需一个空文件系统加程序本身；Python 是解释型，镜像里必须有 CPython、site-packages 与系统 libc 依赖。部署含义：Go 工具的交付物是"一个文件 + checksum"，跨环境一致性极强、攻击面小（无 shell 无包管理器）；Python 交付的是"解释器 + 依赖树"，依赖任何一层漂移行为就可能变化。这也是 k8s 组件能以极小镜像分发的原因。
</details>

<details><summary>2. 无缓冲 channel `ch := make(chan int)` 和 `make(chan int, 10)` 行为差异是什么？各适合什么场景？</summary>

无缓冲：发送阻塞直到有接收者就绪，收发双方"汇合"——天然做成同步点/信号量（例如用 `make(chan struct{})` 当 done 信号）。缓冲 10：前 10 次发送不阻塞，用于削峰——生产速率瞬时高于消费时暂存。选型判断：需要"等对方拿到再继续"用无缓冲；需要"投递后继续干别的、下游慢慢消化"用缓冲。注意缓冲只是延迟阻塞，不是无限队列；容量应按可承受的内存与背压策略定。
</details>

<details><summary>3. worker pool 为什么能控制并发上限？如果改成"每个任务一个 goroutine"会有什么问题？</summary>

并发度由 worker 数量决定：jobs channel 是共享队列，任意时刻在跑的 goroutine 恰好等于 worker 数，任务多于工人时排队等待。每任务一个 goroutine 时，并发上限=任务数：1 万个目标就是 1 万个并发连接、1 万份内存、远端 sshd/API 的连接风暴——正是第 2 章 `xargs -P` 讨论的问题在 Go 里的翻版。goroutine 虽轻（KB 级栈），但它持有的外部资源（fd、socket、远端配额）不轻。受控并发是跨语言通用的运维纪律。
</details>

<details><summary>4. `context.WithTimeout` 之后为什么必须 `defer cancel()`？不调用会怎样？</summary>

WithTimeout 返回的 ctx 内部挂着一个定时器和到期的取消传播机制，cancel 负责释放定时器、向所有子 ctx/IO 发取消信号并让 runtime 回收相关资源。不调用：请求即使提前完成，定时器也要等到超时时刻才触发，期间 ctx 及其引用的对象无法回收；循环里高频创建不 cancel 会持续泄漏内存与定时器（`go vet` 与 pprof 的 goroutine 增长能观测到）。`defer cancel()` 写在创建下一行是最便宜的保险。
</details>

<details><summary>5. Informer 为什么要维护本地缓存（Lister）而不是每次都向 apiserver 查询？watch 断线后如何恢复一致性？</summary>

controller 的调谐逻辑高频读对象，每次打到 apiserver 会让 apiserver 成为瓶颈且延迟不可控；Informer 启动时 List 一次全量进本地存储，此后靠 watch 增量维护，读走内存（Lister），写仍走 apiserver——读写分离换性能。断线恢复：watch 带有 resourceVersion，client-go 的 reflector 检测到断线后按版本重连（re-list 或 resume）；若 resourceVersion 过期被拒绝，则重新全量 List 重建缓存。这套"缓存 + 事件驱动 + 定期 resync 兜底"的最终一致模型，是所有 controller 的可靠性基石，也是 Operator 代码不害怕短暂网络抖动的原因。
</details>

---

## 延伸阅读

- Go 官方 Tour（交互式入门）：https://go.dev/tour/
- Effective Go：https://go.dev/doc/effective_go
- Go Concurrency Patterns（官方博客）：https://go.dev/blog/pipelines
- client-go GitHub（含版本兼容矩阵）：https://github.com/kubernetes/client-go
- Kubernetes 官方 sample-controller：https://github.com/kubernetes/sample-controller
