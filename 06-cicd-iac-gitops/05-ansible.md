# 05 · Ansible：无 agent 的配置管理

> 模块：06-cicd-iac-gitops ｜ 建议时长：5 小时 ｜ 关联认证：—（无直接考点，网络/运维背景迁移成本最低的自动化工具）

## 学习目标

- 能解释 Ansible 无 agent 架构（SSH + 远端 python3）与 "幂等" 的含义
- 能编写 inventory、playbook、role，并用 handler 在配置变更时触发服务重载
- 能操作 Jinja2 模板批量渲染配置文件（nginx 站点、交换机 VLAN），并用 `--check --diff` 预览
- 能使用 ansible-vault 管理敏感变量，能按调试流程定位 playbook 失败原因
- 能区分常用内置模块的适用场景，并能调用 community.docker / kubernetes.core 模块管容器与 K8s

## 1. 架构：为什么"无 agent"对网络工程师特别友好

```
   控制节点（你的 Ubuntu/master）                    被管节点
┌──────────────────────┐   SSH(22)   ┌─────────────────────────┐
│ ansible(python)      │ ──────────▶ │ /usr/bin/python3        │
│  + inventory(主机表) │             │  └─ 执行模块代码后自删    │
│  + playbook(剧本)    │ ◀────────── │  无需常驻进程/无端口      │
└──────────────────────┘   返回 JSON  └─────────────────────────┘
        网络设备：远端无 python，改用 connection=network_cli，
        模块在控制节点本地翻译成 CLI/NETCONF 命令下发
```

- 控制节点把模块（一段小程序）通过 SSH 推到远端执行，拿回 JSON 结果，**远端不留任何东西**
- 对比 agent 模式（Puppet/SaltStack/Chef）：不要装客户端、不要开额外端口、不挑 OS 版本——交换机、防火墙这类没有 agent 可装的老设备也能管（SSH 总有）
- **幂等（idempotency）**：同一 playbook 跑 N 遍，结果与跑 1 遍相同。`apt: state=present` 第二次跑显示 ok（changed=0）而不是重装——这是与"批量执行 shell 脚本"的本质区别
- 代价：无 agent 意味着没有主动上报，想知道配置漂移得自己定时跑（配合 cron/CI）

## 2. inventory：主机与分组

```ini
# [文件 inventory/hosts.ini] INI 格式最常用
[webservers]
cka000021 ansible_host=172.30.30.21 ansible_user=cka
cka000022 ansible_host=172.30.30.22 ansible_user=cka

[dbservers]
cka000023 ansible_host=172.30.30.23 ansible_user=cka

[k8s:children]      # 组嵌套
webservers
dbservers

[k8s:vars]          # 组级变量
ansible_python_interpreter=/usr/bin/python3
```

等价 YAML 形式（与 k8s manifest 心智统一）：

```yaml
# [文件 inventory/hosts.yml]
all:
  children:
    webservers:
      hosts:
        cka000021: {ansible_host: 172.30.30.21, ansible_user: cka}
    dbservers:
      hosts:
        cka000023: {ansible_host: 172.30.30.23, ansible_user: cka}
```

变量三级落点：`group_vars/<组名>.yml`（组共享）→ `host_vars/<主机名>.yml`（单机差异）→ playbook/命令行 `-e`（临时覆盖，优先级最高）。inventory 旁边放 `ansible.cfg` 固化默认参数：

```ini
# [文件 ansible.cfg] 与 inventory 同目录
[defaults]
inventory = inventory/hosts.ini
host_key_checking = False
forks = 10
deprecation_warnings = False
```

## 3. playbook：play → tasks → modules

```yaml
# [文件 site.yml] 部署 nginx 并渲染站点配置（本章主线示例）
---
- name: 部署 nginx 反向代理
  hosts: webservers
  become: true                  # 任务需要 root 时提权（sudo）
  gather_facts: true            # 收集主机信息（ansible_facts）
  vars:
    site_domain: demo.example.com
    upstream_port: 8081
  tasks:
    - name: 安装 nginx
      ansible.builtin.apt:      # 完整限定名：集合.模块
        name: nginx
        state: present
        update_cache: true

    - name: 渲染站点配置
      ansible.builtin.template:
        src: templates/demo-site.conf.j2
        dest: /etc/nginx/conf.d/demo-site.conf
        mode: "0644"
        backup: true
      notify: reload nginx      # 内容变了才通知 handler

    - name: 启动并开机自启
      ansible.builtin.service:
        name: nginx
        state: started
        enabled: true

  handlers:                     # 被 notify 的任务，play 末尾统一执行且去重
    - name: reload nginx
      ansible.builtin.service:
        name: nginx
        state: reloaded
```

三层结构：**play**（对哪组主机做什么）→ **task**（一步动作，调用一个模块）→ **module**（真正干活的幂等实现）。handler 的价值：配置没变就不 reload，N 个 task 都 notify 也只 reload 一次，且发生在 play 收尾（避免改一半就重启服务）。

role 是 playbook 的"标准化目录打包"，把变量/模板/任务按固定位置摆好即可复用：

```
roles/nginx/
├── tasks/main.yml      # 任务入口
├── handlers/main.yml   # handler
├── templates/          # Jinja2 模板
├── files/              # 静态文件
├── vars/main.yml       # 高优先级变量
├── defaults/main.yml   # 低优先级变量（暴露给使用者的参数）
└── meta/main.yml       # 依赖声明
```

playbook 里 `roles: [nginx]` 即引用；`ansible-galaxy init roles/nginx` 生成骨架。

## 4. Jinja2 模板：批量渲染配置（网络自动化的核心）

`template` 模块 = 本地渲染 + 推送远端，这正是"管 50 台设备配置"的正确形态：

```jinja2
# [文件 roles/nginx/templates/demo-site.conf.j2]
# managed by ansible, DO NOT EDIT MANUALLY —— 手改会被下次渲染覆盖
server {
    listen 80;
    server_name {{ site_domain }};

{%- if upstream_port is defined %}
    location / {
        proxy_pass http://127.0.0.1:{{ upstream_port }};
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
{%- endif %}
}
```

语法三件套：`{{ 变量 }}` 取值、`{% if/for %}` 控制逻辑、`{{ var | default('x') }}` 过滤器兜底。注意 nginx 自己的 `$host` 与 Jinja2 不冲突——Jinja2 只认 `{{ }}`。

网络设备同理（呼应网络背景），只是 connection 换掉：

```yaml
# [文件 switch-vlan.yml] 批量下发交换机 VLAN（需 ansible-galaxy collection install cisco.ios）
---
- name: 批量配置 VLAN
  hosts: switches
  gather_facts: false
  connection: ansible.netcommon.network_cli
  tasks:
    - name: 确保 office VLAN 存在
      cisco.ios.ios_vlans:
        config:
          - name: office
            vlan_id: 100
        state: merged
```

```ini
# [文件 inventory/switches.ini] 网络设备 inventory：声明 OS 与连接方式
[switches]
core-sw01 ansible_host=10.1.1.1

[switches:vars]
ansible_network_os=cisco.ios.ios
ansible_connection=ansible.netcommon.network_cli
ansible_user=admin
```

```yaml
# [文件 group_vars/switches.yml] 口令不进 inventory，走 vault 变量（见第 7 节）
ansible_password: "{{ vault_sw_pass }}"
```

## 5. 常用模块速查

| 模块 | 用途 | 幂等要点 |
|---|---|---|
| `ansible.builtin.command` | 跑命令 | **不幂等**，能用专用模块就别用它 |
| `ansible.builtin.shell` | 跑 shell（管道/重定向） | 同上，需 `creates:` 参数兜底 |
| `ansible.builtin.copy` | 推静态文件 | 内容/权限一致则跳过 |
| `ansible.builtin.template` | 渲染 Jinja2 后推送 | 渲染结果一致则跳过 |
| `ansible.builtin.file` | 建目录/软链/删文件 | `state: directory/link/absent` |
| `ansible.builtin.apt` / `ansible.builtin.dnf` | 装包 | `state: present` 幂等 |
| `ansible.builtin.service` | 服务状态 | started/stopped/restarted/reloaded |
| `ansible.builtin.user` / `group` | 账号组 | 存在即跳过，可配 password/shell |
| `ansible.builtin.lineinfile` | 单行增改（如 sysctl） | `regexp` 匹配则替换 |
| `ansible.builtin.replace` | 正则批量替换文件内容 | 匹配不到则跳过 |
| `ansible.builtin.stat` | 取文件信息（存在性/大小） | 只读，常用于分支判断 |
| `ansible.builtin.get_url` | 下载文件 | 支持 checksum 校验 |
| `ansible.builtin.git` | 拉仓库 | 版本一致则跳过 |
| `ansible.builtin.debug` / `assert` | 打印/断言 | 调试与自检 |
| `ansible.posix.firewalld` | 防火墙规则 | permanent/immediate |
| `community.docker.docker_container` | 管容器 | 见第 8 节 |
| `kubernetes.core.k8s` | 管 K8s 对象 | 见第 8 节 |

## 6. 实战演练（kubeadm 集群节点间）

以 master 为控制节点、worker 节点为被管节点（读者环境可 `ssh cka0000XX`，即已有 SSH 通路）。

```bash
# [master] 1) 安装控制端（任选其一）
sudo apt-get update && sudo apt-get install -y ansible
# 或取新版本：python3 -m pip install --user ansible

# [master] 2) 打通免密（没有现成 key 就生成）
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id cka@172.30.30.22        # 对每个被管节点执行一次
```

```bash
# [master] 3) 建项目骨架
mkdir -p ~/ansible-lab/{inventory,templates} && cd ~/ansible-lab
# 写入第 2 节 ansible.cfg、inventory/hosts.ini，再放最简连通性测试：
ansible webservers -m ping
# cka000022 | SUCCESS => {"ping": "pong"}    ← 这个 pong 是远端 python3 返回的
```

```bash
# [master] 4) 放入第 3 节 site.yml 与第 4 节模板，先预览再执行
ansible-playbook site.yml --check --diff
# --check 干跑：不真正改动；--diff 显示 template/file 将发生的内容差异
# 预览确认后执行：
ansible-playbook site.yml
# PLAY RECAP **********************************************************
# cka000022 : ok=4 changed=3 unreachable=0 failed=0 skipped=0

# [master] 5) 再跑一遍验证幂等
ansible-playbook site.yml
# changed=0 —— 第二次全部 ok，这就是幂等
```

```bash
# [worker1] 验证产物（在 worker 上看）
cat /etc/nginx/conf.d/demo-site.conf | head -4
# managed by ansible, DO NOT EDIT MANUALLY —— 手改会被下次渲染覆盖
# server {
#     listen 80;
```

## 7. ansible-vault：敏感变量加密

```bash
# [master] 把明文变量文件加密（交互输口令）
cd ~/ansible-lab
cat > group_vars/all.yml <<'EOF'
vault_sw_pass: "OldPass!2024"
EOF
ansible-vault encrypt group_vars/all.yml
ansible-vault view group_vars/all.yml       # 查看需口令
ansible-vault edit group_vars/all.yml       # 编辑需口令
ansible-vault rekey group_vars/all.yml      # 换口令
```

```bash
# [master] 使用方式二选一
ansible-playbook site.yml --ask-vault-pass
echo 'MyVaultPass!2026' > .vault-pass && chmod 600 .vault-pass
ansible-playbook site.yml --vault-password-file .vault-pass
```

纪律：vault 文件必须加密后入库（`.vault-pass` 口令文件本身进 `.gitignore`）；CI 里通过密码文件或 `ANSIBLE_VAULT_PASSWORD_FILE` 环境变量注入，不要把口令写进 playbook。

## 8. 调试与 Docker/K8s 模块

调试五步法（从便宜到贵）：

```bash
# [master]
ansible-playbook site.yml --syntax-check          # 1. 语法
ansible-playbook site.yml --list-tasks            # 2. 任务清单是否符合预期
ansible-playbook site.yml --check --diff          # 3. 干跑+差异
ansible-playbook site.yml -v                      # 4. 加详细输出（-vvv 更深）
ansible-playbook site.yml --step                  # 5. 每步交互确认，定位卡点
ansible-playbook site.yml --limit cka000022       # 只跑单台，缩小爆炸半径
```

playbook 内置的自检手段：`debug: var=xxx` 打印变量、`failed_when` 自定义失败条件、`block/rescue/always` 做异常分支。

管容器与 K8s（在装有 docker 的节点/有 kubeconfig 的 master 上）：

```yaml
# [文件 docker-k8s.yml] 两个模块族的用法样例
---
- name: 管理一个容器
  hosts: webservers
  become: true
  tasks:
    - community.docker.docker_container:
        name: demo-web
        image: nginx:1.27-alpine
        state: started
        ports: ["8099:80"]
        restart_policy: unless-stopped

- name: 管理 K8s 对象（在 master 上跑，用默认 kubeconfig）
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - kubernetes.core.k8s:
        state: present
        definition:
          apiVersion: v1
          kind: Namespace
          metadata:
            name: ansible-demo
```

```bash
# [master] 预装集合后执行
ansible-galaxy collection install community.docker kubernetes.core
ansible-playbook docker-k8s.yml
kubectl get ns ansible-demo        # 验证 namespace 已创建
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `UNREACHABLE ... Permission denied (publickey)` | 免密未打通 / 用户名错 | `ssh-copy-id`；inventory 核对 `ansible_user` |
| 首次连接卡住后报 host key | 严格 host key 校验 | `ansible.cfg` 设 `host_key_checking = False` 或提前分发 known_hosts |
| 模块报 `/usr/bin/python: not found` | 远端只有 python3 | 组变量设 `ansible_python_interpreter=/usr/bin/python3` |
| template 报 `xxx is undefined` | 变量未定义且无兜底 | `{{ var | default('x') }}`；或 `--extra-vars` 传入 |
| handler 没触发 | notify 的名字与 handler 名不一致（必须完全相同）；或 task 未发生变更 | 核对名称；`ansible-playbook --list-tasks` 双向检查 |
| become 失败 | 被管用户无 sudo 权限或需密码 | `become: true` 配 `ansible_become_password`（vault 加密） |
| command 模块每次都 changed | command/shell 天然不幂等 | 换专用模块；或加 `creates: /path/to/file` 条件 |
| 网络模块报 connection 错误 | 未声明 `ansible_network_os` / 未装 netcommon 集合 | 补 inventory 组变量；`ansible-galaxy collection install ansible.netcommon` |

## 自测

<details><summary>1. "无 agent"换来的是什么、付出的是什么？什么场景下这个取舍最划算？</summary>

换来：零客户端部署、零额外端口、SSH 到哪就能管到哪（老交换机/防火墙/最小化系统都能管）、升级只动控制节点。付出：无主动上报（漂移要靠定时跑才能发现）、性能受 SSH 通道限制（大规模用 mitogen/ batching 缓解）、Windows 需走 WinRM 这套完全不同的通道。最划算的场景：设备异构、数量中等（几百台以内）、以配置下发为主——正是传统网络运维的形状。
</details>

<details><summary>2. 幂等为什么是"批量改生产"的安全底线？举例说明 command 和 service 模块在幂等性上的差别。</summary>

批量脚本最大的风险是"跑第二遍变成事故"（重复追加、重复重启）。幂等保证 playbook 可安全重跑：失败修复后从头再跑即可，这正是故障时刻最需要的性质。`service: state=started` 第二次发现服务已启动则 ok；`command: systemctl start nginx` 每次都执行且永远报 changed，你还失去了"changed 计数"这个审计信号——所以口诀是"有专用模块就不用 command"。
</details>

<details><summary>3. handler 为什么放到 play 末尾统一执行？如果两个 task 通知同一个 handler，服务 reload 几次？</summary>

末尾统一执行避免"配置改到一半服务就重启"（多个配置文件分多个 task 渲染时尤其致命），也让一次变更只触发一次服务扰动。同一 handler 被通知 N 次只执行一次（去重），这是设计而非缺陷；确实需要每次都执行的动作应写成普通 task 或用 `listen:` 语义细分。
</details>

<details><summary>4. `--check --diff` 下 template 能给出真实差异吗？有什么它测不出来的坑？</summary>

能：template/copy/file 模块支持 check 模式下的 diff 输出，渲染在控制节点完成，不需要改远端。测不出来的：command/shell 在 check 模式直接跳过（它们无法预演），依赖"前一个 command 的产出"的后续 task 的结果不可信；以及服务重启后的真实行为（配置语法错误导致 reload 失败只有真跑才知道，可先用 `nginx -t` 类校验 task 兜底）。
</details>

<details><summary>5. 给 200 台设备做配置时，你的 playbook 里 vars、group_vars、host_vars 各放什么？为什么 secrets 要单独走 vault？</summary>

vars/playbook：本次剧本的流程参数（路径、开关）；group_vars：同角色设备的共性（NTP、syslog、域名模板变量）；host_vars：单机差异（管理 IP 已在 inventory，这里放机架号、唯一 ID、hostname 等）。分层原则是"改一处生效一片，同时单机差异不污染组"。secrets 单独走 vault 是因为变量文件的共享粒度（整组可读）与密文的暴露要求（最小可见）不同：vault 让同一文件里的口令密文化，且审计点集中在口令使用记录上。
</details>

## 延伸阅读

- Ansible 官方文档（User Guide）：<https://docs.ansible.com/ansible/latest/user_guide/index.html>
- 模块索引：<https://docs.ansible.com/ansible/latest/collections/index.html>
- ansible-vault：<https://docs.ansible.com/ansible/latest/vault_guide/index.html>
- 网络自动化集合 ansible.netcommon：<https://docs.ansible.com/ansible/latest/collections/ansible/netcommon/index.html>
