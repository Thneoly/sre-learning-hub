# Lab 03 · 解答：Ansible Playbook 部署 nginx

> 配套 task.md 使用。环境：一台干净的 Ubuntu 22.04/24.04 VM（有 sudo 权限、可 apt 联网）。

## 第 0 步：理解设计

Ansible 的执行模型：把"期望状态"描述成一串 task，控制机逐台 SSH（本 lab 是 localhost 直连）按序执行，每个模块自己判断"当前是否已处于该状态"——已满足就返回 `ok`，不满足才动手并返回 `changed`：

```
playbook（期望状态清单）
 ├─ task1 apt:nginx          ── 已装？── ok（不动手）
 ├─ task2 template:index     ── 内容变？── changed（渲染文件）
 ├─ task3 service:started    ── 已跑？── ok
 ├─ task4 uri:GET /          ── 只读探测，changed_when:false 压成 ok
 ├─ task5 assert:200+关键词  ── 纯断言
 └─ task6 copy:结果文件      ── 内容变？── changed（写 /var/tmp/nginx-lab-status.json）
```

收敛后重复执行应得 `changed=0`——这就是幂等性，也是 playbook 与 shell 脚本的本质区别。

## 第 1 步：安装 ansible-core

```bash
# [Ubuntu VM]
# Ubuntu 22.04：
sudo apt update && sudo apt install -y ansible python3-yaml
# Ubuntu 24.04（apt 源里没有 ansible，用 pipx）：
sudo apt install -y python3-pip pipx python3-yaml
pipx install ansible-core && pipx ensurepath
# 重开 shell 后验证：
ansible-playbook --version    # 预期显示 ansible-core 2.x
```

建项目目录：

```bash
# [Ubuntu VM]
mkdir -p ~/labs/ansible-nginx/templates && cd ~/labs/ansible-nginx
```

## 第 2 步：写模板与 playbook

`templates/index.html.j2`（Jinja2 变量来自 facts 与 play vars）：

```html
<!-- 文件: ~/labs/ansible-nginx/templates/index.html.j2 -->
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>ansible-lab</title>
</head>
<body>
  <h1>ansible-lab</h1>
  <p>host: {{ inventory_hostname }} | site: {{ site_title }} | v{{ site_version }}</p>
</body>
</html>
```

`deploy-nginx.yml`：

```yaml
# 文件: ~/labs/ansible-nginx/deploy-nginx.yml
- name: 批量部署 nginx 站点并做健康检查
  hosts: localhost
  connection: local
  become: true
  gather_facts: true
  vars:
    site_title: ansible-lab
    site_version: "1.0"

  tasks:
    - name: 安装 nginx
      ansible.builtin.apt:
        name: nginx
        state: present
        update_cache: true
        cache_valid_time: 3600

    - name: 渲染自定义首页
      ansible.builtin.template:
        src: templates/index.html.j2
        dest: /var/www/html/index.html
        mode: "0644"

    - name: 启动 nginx 并设为开机自启
      ansible.builtin.service:
        name: nginx
        state: started
        enabled: true

    - name: HTTP 健康检查
      ansible.builtin.uri:
        url: http://localhost/
        return_content: true
      register: health
      changed_when: false
      check_mode: false

    - name: 校验健康检查结果
      ansible.builtin.assert:
        that:
          - health.status == 200
          - "'ansible-lab' in health.content"
        fail_msg: "健康检查不通过：code={{ health.status | default('N/A') }}"

    - name: 写部署结果文件
      ansible.builtin.copy:
        dest: /var/tmp/nginx-lab-status.json
        mode: "0644"
        content: |
          {"status": "ok", "host": "{{ inventory_hostname }}", "http_code": {{ health.status }}, "version": "{{ site_version }}"}
```

关键点逐条说：

- `become: true`：apt/service/写 /var/www 都要 root，play 级声明一次即可；
- `update_cache: true` + `cache_valid_time: 3600`：合并 apt update 与安装，且缓存 1 小时内不重复刷新，兼顾首次可用与幂等；
- `template` 而非 `copy`：首页内容要插变量（inventory_hostname），Jinja2 渲染是 Ansible 的标配手法；
- `uri` + `changed_when: false`：GET 请求不改变系统状态，压掉 changed 计数，幂等性验证才能过；
- `check_mode: false`：`--check` 干跑时也真实探测（只读安全），否则 assert 拿不到 `health.status`；
- 结果文件用 `copy: content:` 而不是 shell 重定向：内容一致时不重写、不产生 changed，仍是幂等的。

## 第 3 步：首次执行

```bash
# [Ubuntu VM]
cd ~/labs/ansible-nginx
ansible-playbook -K deploy-nginx.yml
# -K：交互输入 sudo 密码（become 提权）
```

预期 PLAY RECAP：

```text
# [Ubuntu VM] 输出（节选）
PLAY RECAP *********************************************************************
localhost : ok=7 changed=4 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0
```

（首次 changed 取决于机器初始状态，装包/渲染/写结果文件计 changed 是正常的。）验证终态：

```bash
# [Ubuntu VM]
curl -s http://localhost/
# 预期：<h1>ansible-lab</h1> 且 host: localhost
cat /var/tmp/nginx-lab-status.json
# 预期：{"status": "ok", "host": "localhost", "http_code": 200, "version": "1.0"}
systemctl is-enabled nginx && systemctl is-active nginx
# 预期：enabled / active
```

## 第 4 步：幂等性验证

```bash
# [Ubuntu VM]
ansible-playbook -K deploy-nginx.yml | tail -n 3
# 预期：localhost : ok=7 changed=0 ...（uri 因 changed_when:false 计 ok，
#       template/copy 因内容一致不再触发，apt 因已装返回 ok）
```

若 changed 不是 0，常见来源：模板里用了每次都变的值（如 `{{ ansible_date_time.epoch }}`）、copy 内容非确定、或 uri 没设 `changed_when: false`。

## 第 5 步：--check 干跑验证

```bash
# [Ubuntu VM]
sudo ansible-playbook --check deploy-nginx.yml | tail -n 3
# 预期：localhost : ok=7 changed=0 ...
```

`--check` 下会动手的模块全部改为"只报告将发生什么"，`check_mode: false` 标记的 uri 照常探测——干跑也能拿到真实的健康结论。这给了你一条安全预检路径：改完 playbook 先 `--syntax-check`（纯解析）、再 `--check`（干跑）、最后真跑，三级递进。

## 第 6 步（选做）：体验 notify/handler

把模板换成 nginx 配置类文件时，用 handler 做"变了才 reload"：

```yaml
# 文件: ~/labs/ansible-nginx/handler-demo-snippet.yml（片段，演示用）
    - name: 渲染 nginx 站点配置
      ansible.builtin.template:
        src: templates/site.conf.j2
        dest: /etc/nginx/conf.d/site.conf
      notify: reload nginx

  handlers:
    - name: reload nginx
      ansible.builtin.service:
        name: nginx
        state: reloaded
```

handler 只在 task 实际 changed 时被排队，play 结束统一执行且同名只跑一次；干跑/幂等场景下不触发，不产生多余重启。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 重跑 changed 一直不为 0 | uri 未压 changed，或模板/copy 内容非确定 | uri 加 `changed_when: false`；模板不要放时间戳类变量 |
| `--check` 时 assert 报 `'dict object' has no attribute 'status'` | check 模式下 uri 不发请求，register 里没有响应码 | uri 任务标 `check_mode: false`（本 solution 已处理） |
| apt 任务卡住 | apt 缓存锁被占用（unattended-upgrades） | 等待或 `sudo systemctl stop unattended-upgrades` 临时处理；playbook 里已用 `cache_valid_time` 减少刷新 |
| `become` 弹密码打断自动化 | 默认 sudo 需要交互 | CI 里用 NOPASSWD 的专用账号，或 `--become-password-file`（以官方文档为准），不要把密码写进 playbook |
| 修改 index.html.j2 后页面没变 | 忘了模板路径相对 playbook，改错了文件 | `src: templates/index.html.j2` 相对 playbook 所在目录；改完重跑 playbook 再 curl 验证 |
| 幂等 OK 但 `--check` 报 changed=1 | check 模式下某些模块（如会写文件的 command）不支持模拟 | 用原生模块替代 command/shell；确需时给该 task 标 `check_mode: false` 或 `ignore_errors` + 说明 |

## 判分脚本结果

```text
# [Ubuntu VM]
$ sudo ./check.sh .
PASS: deploy-nginx.yml 存在
PASS: ansible-playbook --syntax-check 通过
PASS: play 头部为 hosts=localhost / connection=local / become=true
PASS: 存在 apt 任务安装 nginx
PASS: 存在 template 任务部署 /var/www/html/index.html
PASS: 存在 service 任务（nginx started 且 enabled）
PASS: 存在 uri 健康检查任务（http://localhost/）
PASS: 存在 copy 任务写 /var/tmp/nginx-lab-status.json
PASS: curl http://localhost/ 返回 ansible-lab 页面
PASS: 结果文件含 "status": "ok"
PASS: systemctl is-enabled nginx 返回 enabled
PASS: --check 干跑 changed=0（系统已收敛）

SCORE: 12/12
```

## 延伸阅读

- Ansible 官方文档（Playbooks）：https://docs.ansible.com/ansible/latest/playbook_guide/playbooks.html
- 模块索引（apt/template/service/uri/assert/copy）：https://docs.ansible.com/ansible/latest/collections/ansible/builtin/
- check mode 与 changed_when：https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_checkmode.html
- Handlers 最佳实践：https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_handlers.html
