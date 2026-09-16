# Lab 03 · Ansible Playbook：批量部署 nginx + 站点配置 + 健康检查

> 难度：★★☆ ｜ 考点：Ansible 幂等性 / 模块化任务编排 / --check 干跑 ｜ 前置：01-linux 的 lab 01 ｜ 预计 30~50 分钟

## 场景

你要给 30 台 Web 服务器统一部署 nginx：装包、下发一个带主机名的自定义首页、确保服务启动且开机自启、部署后自动做 HTTP 健康检查，最后在每台机器上落一个**结果文件**供运维平台采集。手头只有一台 Ubuntu VM，先用 `localhost` 模式把 playbook 和幂等性打磨好——Ansible 的价值恰恰在于：同一份 playbook 在 1 台和 30 台机器上没有区别，跑一百遍结果也一样（idempotency）。

约定（判分脚本按此检查）：playbook 文件名 `deploy-nginx.yml`；首页路径 `/var/www/html/index.html`；健康检查 URL `http://localhost/`；结果文件 `/var/tmp/nginx-lab-status.json`，内容含 `"status": "ok"`。

## 任务清单

1. 安装 ansible-core（apt 或 pipx 二选一，Ubuntu 24.04 建议 pipx），确认 `ansible-playbook --version` 可用。
2. 编写 `deploy-nginx.yml` 及 `templates/index.html.j2`，要求：
   - play 头部：`hosts: localhost`、`connection: local`、`become: true`；
   - 用 `ansible.builtin.apt` 安装最新版 nginx；
   - 用 `ansible.builtin.template` 渲染 `index.html.j2` 到 `/var/www/html/index.html`（页面标题与正文都含 `ansible-lab`，正文带 `inventory_hostname`）；
   - 用 `ansible.builtin.service` 确保 nginx `started` 且 `enabled: true`；
   - 用 `ansible.builtin.uri` 对 `http://localhost/` 发 GET 做健康检查，`register` 结果并设 `changed_when: false`，任务上标 `check_mode: false`（保证 `--check` 干跑时也能真正探测）；
   - 用 `ansible.builtin.assert` 校验返回码为 200 且响应体含 `ansible-lab`；
   - 用 `ansible.builtin.copy` 的 `content:` 把结果写入 `/var/tmp/nginx-lab-status.json`（含 `"status": "ok"` 与健康检查的 HTTP 码）。
3. 第一次执行（`-K` 输入 sudo 密码），确认全部 task 通过且 `curl http://localhost/` 返回自定义页面。
4. **幂等性验证**：原样再跑一遍，确认汇总行 `changed=0`（uri 任务因 `changed_when: false` 不计变更；template/copy 因内容一致不再触发）。
5. **干跑验证**：`ansible-playbook --check deploy-nginx.yml` 同样 `changed=0`，说明系统已收敛到 playbook 声明的状态。

## 验收标准

终态要求（在 VM 上可验证）：

- `deploy-nginx.yml` 能通过 `ansible-playbook --syntax-check`；
- VM 上 nginx 已安装并运行、`systemctl is-enabled nginx` 返回 `enabled`；
- `curl -s http://localhost/` 返回的页面含 `ansible-lab`；
- `/var/tmp/nginx-lab-status.json` 存在且内容含 `"status": "ok"`；
- 重复执行 playbook 汇总 `changed=0`。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [Ubuntu VM]
cd ~/labs/ansible-nginx
chmod +x /path/to/check.sh
/path/to/check.sh .        # 参数为 playbook 所在目录，默认当前目录
```

## 提示（卡住再看）

<details><summary>提示 1：为什么 uri 任务要 changed_when: false 和 check_mode: false？</summary>

`uri` 每次发请求都会把任务标成 changed——不压掉它，幂等性验证永远 `changed=1`；`check_mode: false` 则相反，它让该任务在 `--check` 干跑时**仍然真正执行**（GET 是只读操作，安全），否则干跑时拿不到 HTTP 码，后面的 assert 会因缺少 `health.status` 而失败。一个压"变更"、一个放行"只读探测"，两件事方向相反但都是为幂等/干跑服务。
</details>

<details><summary>提示 2：结果文件里的 HTTP 码怎么带进去？</summary>

uri 任务 `register: health` 后，`health.status` 就是 HTTP 响应码（200）。copy 的 `content:` 里用 Jinja2 直接插值：`{"status": "ok", "http_code": {{ health.status }}}`。注意 content 是字符串模板，JSON 里的数字不能加引号。
</details>

<details><summary>提示 3：怎么让"改首页内容"触发服务刷新？</summary>

静态页其实不用 reload nginx；但如果是改 nginx.conf，就体现 handlers 的价值：task 上 `notify: reload nginx`，handler 里 `ansible.builtin.service: state: reloaded`。handler 只在任务真正 changed 时触发，且一轮 play 只跑一次——这就是 Ansible 版的"条件重启"。
</details>

<details><summary>提示 4：改成管理 30 台真机要动哪里？</summary>

只动两处：inventory 文件里写 `[webservers]` + 主机列表（或 dynamic inventory），play 头部 `hosts: webservers`、去掉 `connection: local`；配合 `--ask-pass -K` 或免密 sudo/ssh。tasks 本体一行不改——这就是"面向状态描述"与"面向命令执行"脚本的根本差别。
</details>
