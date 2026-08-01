## SOCKS5

```bash
bash <(curl -sL "https://raw.githubusercontent.com/moyuem/ddns-cf/main/socks.sh?t=$(date +%s)")
```

## Cloudflare DDNS

### 首次安装

```bash
curl -fsSL "https://raw.githubusercontent.com/moyuem/ddns-cf/main/ddns_cf.sh?t=$(date +%s)" | bash
```

配置完成后，脚本会安装持久化的 `ddns` 命令和定时任务。root 用户安装到
`/usr/local/bin/ddns`，普通用户安装到 `~/.local/bin/ddns`。

### 修复已安装的机器

旧版本通过 `bash <(curl ...)` 运行时，可能把 `ddns` 命令和 cron 指向临时的
`/dev/fd/*` 路径。进程退出后该路径失效，表现为 `ddns` 无法打开菜单，定时更新也不再运行。

请使用**与首次安装时相同的用户**执行以下命令。它会保留现有
`~/.ddns_cf.conf`，只重新安装 `ddns` 命令并修复本脚本创建的 cron：

```bash
curl -fsSL "https://raw.githubusercontent.com/moyuem/ddns-cf/main/ddns_cf.sh?t=$(date +%s)" | bash -s -- --repair
```

如果原来使用 root 安装：

```bash
curl -fsSL "https://raw.githubusercontent.com/moyuem/ddns-cf/main/ddns_cf.sh?t=$(date +%s)" | sudo bash -s -- --repair
```

验证修复结果：

```bash
command -v ddns
ddns
crontab -l | grep 'ddns_cf.sh auto schedule'
```

普通用户若当前终端的 `PATH` 尚未包含 `~/.local/bin`，可重新登录，或先执行：

```bash
export PATH="$HOME/.local/bin:$PATH"
```
