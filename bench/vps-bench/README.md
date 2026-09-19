# vps-bench

[← 返回仓库根](../../README.md)

VPS 节点测速：封装两个第三方测速脚本，二选一执行。

| | |
|---|---|
| 域 | `bench/` |
| 版本 | `1.0.1` |
| 结构 | 单文件 |
| 依赖 | curl |
| 配置 | 无 |

## 安装

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install vps-bench
```

## 用法

```bash
sudo vps-bench               交互选择测速脚本
sudo vps-bench nodequality   NodeQuality 测速（bash <(curl ...)）
sudo vps-bench tcpquality    TcpQuality 测速（curl | sudo bash -s）
vps-bench -v, --version      显示版本号
vps-bench -h, --help         显示本帮助
```

## 上游脚本来源

| 名称 | URL |
|---|---|
| NodeQuality | `https://run.NodeQuality.com` |
| TcpQuality | `https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh` |

## 供应链风险提示

两个上游脚本均以**管道方式直接执行**（`curl | sudo bash`），等价于把 root 交给第三方代码。
工具在执行前会**打印来源 URL 并要求确认**（交互模式）；无 TTY 时按设计直接放行（不阻塞管道场景）。

> 如需审计，先 `curl -sSL <URL> | less` 阅读，再决定是否执行。
