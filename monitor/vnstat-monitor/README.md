# vnstat-monitor

[← 返回仓库根](../../README.md)

vnStat 流量监控 + Telegram 推送 + 超阈值熔断关机。以 systemd timer 周期运行，
**原地更新同一条 Telegram 消息**（不刷屏），支持流量偏移校准与无限流量模式。

| | |
|---|---|
| 域 | `monitor/` |
| 版本 | `1.1.2` |
| 结构 | 单文件 |
| 依赖 | vnstat, jq, curl, gawk, iproute2（缺依赖脚本自动安装） |
| 配置 | `/etc/vnstat-monitor.env`（600） |
| 状态 | `/var/lib/vnstat-monitor/state.env` |

## 安装

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install vnstat-monitor
```

安装器只放脚本 + 生成配置模板，**不会自动执行工具命令**。接着：

```bash
sudo nano /etc/vnstat-monitor.env    # 填 VPS_NAME / TG_BOT_TOKEN / TG_CHAT_ID
sudo vnstat-monitor                  # 手动跑一次验证（应收到 Telegram 卡片）
sudo vnstat-monitor setup            # 交互式确认全部配置 + 安装 systemd timer
```

## 用法

```bash
vnstat-monitor                       立即检查一次（systemd timer / 手动）
sudo vnstat-monitor setup            交互式设置全部配置项 + 安装 systemd timer
sudo vnstat-monitor install-timer [分钟]   安装/更新 timer（默认用配置 INTERVAL_MINUTES）
sudo vnstat-monitor set-interval <分钟>    修改触发频率并重载 timer
sudo vnstat-monitor timer-status      查看 timer 状态
sudo vnstat-monitor uninstall-timer   移除 timer 与 service（保留配置）
vnstat-monitor -v, --version          显示版本号
vnstat-monitor -h, --help             显示本帮助
```

## 配置项（`/etc/vnstat-monitor.env`）

| 键 | 说明 |
|---|---|
| `VPS_NAME` | 自定义 VPS 名称（Telegram 卡片与告警显示） |
| `INTERFACE` | 监控网卡，`auto` = 自动探测主路由网卡（推荐） |
| `CALC_MODE` | 流量计算模式：`both`（双向相加）/ `out`（仅出站）/ `in`（仅入站）/ `max`（取较大值） |
| `RESET_DAY` | 流量重置日（1-28）；脚本会自动接管并调整 vnstat 底层统计周期 |
| `TOTAL_GB` | 流量总量（GB）。**`0` = 无限流量**，不再显示进度条、不触发关机 |
| `OFFSET_GB` | 手动校准偏移（GB）；与云厂商账单有偏差时修正，可负值，默认 `0` |
| `SHUTDOWN_PERCENT` | 自动关机阈值百分比（0-100）；`TOTAL_GB=0` 时失效 |
| `TG_BOT_TOKEN` / `TG_CHAT_ID` | Telegram Bot（联系 @BotFather 创建）；**必填** |
| `INTERVAL_MINUTES` | 定时触发频率（分钟），默认 `15`；改后 `sudo vnstat-monitor set-interval <分钟>` |
| `STATE_FILE` | 状态保存路径，无需修改 |

## 调度（systemd timer）

不使用 crontab。`setup` / `install-timer` 生成 `.service`（oneshot）+ `.timer`
（`OnUnitActiveSec`，`Persistent=true` 防漂移）；触发频率持久化在配置的
`INTERVAL_MINUTES`，`set-interval` 改频率即重写 timer + `daemon-reload`。

> 旧版本用 crontab（`*/15 * * * * /usr/local/bin/vnstat-monitor`）的机器：
> 工具会自动迁移（备份原 crontab 到 `/etc/vnstat-monitor.crontab.bak` 后移除条目）；
> `uninstall-timer` 之外仍建议检查一次 `crontab -l` 有无残留行。

## 已知坑

- **vnstat `MonthRotate` 默认是分号注释形式**（`;MonthRotate 1`）：早期版本用
  `awk '/^MonthRotate/'` 读不到值，会重复追加配置行，导致首次跨月月份判定异常
  （卡片显示 0.00 GB 但实际有流量）。1.1.0 起检测正则兼容 `^;*MonthRotate`。
- **计费周期键必须用系统时钟**，不能取自 vnstat 的 month 数组 `last`——后者依赖被监控数据本身，
  数据错位会导致误判跨周期并**发出第二张卡片**。1.1.0 起改用 `date`。
- 卡片原地更新依赖状态文件里的 `message_id`；状态文件写入是原子操作（tmp + mv），
  并发/中断不会留下半写文件。
