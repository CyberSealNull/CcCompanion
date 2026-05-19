# ccc 加 heartbeat 自助推送 操作手册

> 在你自己 Mac 上加两个文件 一小时一次让 Claude 判断要不要主动找你 自动推送到 ccc iPhone app. 完全独立 不依赖任何外部 server.

## 前提

- ccc apns-server 已经在你 Mac 上跑通 (装 ccc 时 install.sh 起的) 监听 `http://127.0.0.1:8795`
- ccc iPhone app 已经 onboarding 完成 装好你 Mac 的 server URL chat 通了
- 装了 Python 3 跟 anthropic SDK (`pip3 install anthropic`)
- 有 Anthropic API key (Claude 用)

## 文件 1 `~/scripts/heartbeat.py`

```python
#!/usr/bin/env python3
"""每小时跑一次 让 Claude 判断要不要主动找用户."""
import json
import urllib.request
import anthropic

client = anthropic.Anthropic()  # 自动读 ANTHROPIC_API_KEY env

# 让 Claude 判断
prompt = """现在是 周一晚上. 距上次用户消息 1 小时.
判断要不要主动发问候. 回答两种之一:
- SPOKE: 问候文本
- SILENT: 不发的理由
"""

resp = client.messages.create(
    model="claude-opus-4-7",
    max_tokens=300,
    messages=[{"role": "user", "content": prompt}],
)
out = resp.content[0].text.strip()
print(f"chain 判: {out}")

# 决定 SPOKE 就推送
if out.startswith("SPOKE:"):
    text = out[len("SPOKE:"):].strip()
    req = urllib.request.Request(
        "http://127.0.0.1:8795/chat/append",
        data=json.dumps({
            "role": "assistant",
            "text": text,
            "source": "heartbeat",
        }).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as r:
        print(f"推送结果: {r.status}")
```

放到 `~/scripts/heartbeat.py` 然后 `chmod +x ~/scripts/heartbeat.py`.

## 文件 2 `~/Library/LaunchAgents/com.heartbeat.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.heartbeat</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Users/你的用户名/scripts/heartbeat.py</string>
    </array>

    <key>StartInterval</key>
    <integer>3600</integer>

    <key>RunAtLoad</key>
    <false/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>ANTHROPIC_API_KEY</key>
        <string>sk-ant-你自己的-key</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>StandardOutPath</key>
    <string>/tmp/heartbeat.out.log</string>

    <key>StandardErrorPath</key>
    <string>/tmp/heartbeat.err.log</string>
</dict>
</plist>
```

记得把 `/Users/你的用户名/` 改成实际路径 跟 `sk-ant-你自己的-key` 改成你的 API key.

## 加载

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.heartbeat.plist
launchctl list | grep heartbeat
```

看到 `- 0 com.heartbeat` 就是加载成功. 下一小时整点会跑.

## 卸载

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.heartbeat.plist
```

## 测试

```bash
ANTHROPIC_API_KEY=sk-ant-你的 python3 ~/scripts/heartbeat.py
```

手动跑一次 看输出. SPOKE 路径会真推到 iPhone.

## 进阶

- prompt 可以改成读你最近 chat 历史 (server 有 `GET /chat/history` endpoint) 加进 context
- 改 StartInterval 调频率
- 加 quiet hours (heartbeat.py 里判当前小时 在 23:00 - 07:00 直接 exit)
- 加 dedupe (上次 SPOKE 1.5 小时内不再 SPOKE)

整个流程在你自己 Mac 上 数据不离开本地. ccc apns-server 是你的 device token 是你的 cert 是你的 push 也是你的.
