# 拍一拍 & 表情包配置文档

> 适用于 Claude Code Companion 微信主题的后端服务（apns-server）。
> 本文档涵盖「表情包」与「拍一拍」两套功能的服务端配置、数据管理与接口说明。
> 文档中所有 `<尖括号>` 内容为占位符，请替换为你自己的实际值；请勿把密钥提交到公开仓库。

---

## 一、前置说明

- **后端服务**：apns-server，HTTP 服务，默认监听 `0.0.0.0:8795`。
- **鉴权**：所有写操作的请求需带请求头 `X-Auth-Token: <你的 shared_secret>`，该值与服务端 `config.toml` 里的 `shared_secret` 一致。读接口（如表情包列表）无需鉴权。
- **数据落地**：使用本地 JSON 文件加图片目录，无需数据库。下文统一用 `<数据目录>` 指代服务端的数据落地目录，用 `<附件目录>` 指代图片存放目录。
- **标签机制**：微信主题里，AI 通过在回复正文里嵌入特定标签来触发表情包、拍一拍等动作。后台的总线钩子（bus hook）会把标签从展示文本里抽出并剥离，再分发到对应接口，标签原文不会泄漏给用户。

| 标签 | 作用 | 分发到 |
|---|---|---|
| `[sticker:<id>]` | 发送一个表情包 | 聊天接口带 `sticker_id` |
| `[拍拍:<后缀>]` | 反向拍一拍并推送 | `POST /status/patpat` |

---

## 二、表情包配置

### 2.1 工作原理

微信主题里，AI 与用户都能发表情包。表情包是通用素材，由服务端集中管理；客户端按 `sticker_id` 从服务端拉取对应图片并渲染成图片气泡。客户端本身不内置任何表情包资源。

### 2.2 数据结构

- **配置文件**：`<数据目录>/stickers.json`
- **图片文件**：`<附件目录>/`（通过 `/attachments/` 路由对外提供）

`stickers.json` 结构示例：

```json
{
  "stickers": [
    {
      "id": "emoji_happy",
      "filename": "sticker_emoji_happy.png",
      "desc": "开心",
      "url": "/attachments/sticker_emoji_happy.png"
    }
  ]
}
```

字段说明：

| 字段 | 含义 |
|---|---|
| `id` | 表情包唯一标识，只允许字母、数字、下划线 |
| `filename` | 图片在附件目录里的文件名 |
| `desc` | 语义描述，AI 靠它判断何时选用这张表情 |
| `url` | 客户端拼接服务端地址后拉取的相对路径 |

### 2.3 批量预置表情包

把一组素材图片放进一个目录，按「源文件名 → id → 语义」映射批量导入。可参考下面的脚本骨架（替换 `<素材目录>` 与映射表即可）：

```python
import shutil
from pathlib import Path
from wechat_v27 import StickerStore

SRC_DIR = Path("<素材目录>")
ATT_DIR = Path("<附件目录>")
STICKERS_JSON = Path("<数据目录>/stickers.json")

# (源文件名, id, 语义描述)
MAPPING = [
    ("happy.png",    "emoji_happy",    "开心"),
    ("thumbsup.png", "emoji_thumbsup", "点赞"),
    ("question.png", "emoji_question", "疑问"),
    # ……按需补充
]

def main():
    ATT_DIR.mkdir(parents=True, exist_ok=True)
    store = StickerStore(STICKERS_JSON)
    for src_name, sid, desc in MAPPING:
        src = SRC_DIR / src_name
        if not src.exists():
            print(f"  跳过，源文件不存在：{src_name}")
            continue
        stored = f"sticker_{sid}.jpg"
        shutil.copy2(src, ATT_DIR / stored)
        store.upsert(sticker_id=sid, filename=stored, desc=desc,
                     url=f"/attachments/{stored}")
        print(f"  导入 {sid} -> {stored}（{desc}）")

if __name__ == "__main__":
    main()
```

脚本幂等：重复运行只覆盖同名表情，不会重复追加。

### 2.4 接口

#### 列表（读，无需鉴权）

```
GET /stickers/list
→ { "ok": true, "stickers": [ {id, filename, desc, url}, ... ] }
```

#### 上传（写，需鉴权）

原始图片字节作为请求体，参数走查询串：

```
POST /stickers/upload?id=<可选,缺省自动生成>&desc=<语义>&filename=<原始文件名>
Header: X-Auth-Token: <你的 shared_secret>
Body:   raw 图片字节（上限 10MB）
→ { "ok": true, "sticker": { id, filename, desc, url } }
```

支持的图片格式：jpg、jpeg、png、gif、webp、heic、heif；非图片后缀会被强制按 png 处理。`id` 会被规范化为只含字母、数字、下划线，防止路径穿越。

#### 删除（写，需鉴权）

```
POST /stickers/delete
Header: X-Auth-Token: <你的 shared_secret>
Body:   { "sticker_id": "<id>" }
→ { "ok": true, "deleted": "<id>" }      成功
→ { "error": "sticker not found" }       该 id 不存在（HTTP 404）
→ { "error": "sticker_id required" }     缺参数（HTTP 400）
```

删除会同时移除 `stickers.json` 里的配置条目，并尽力删除附件目录里对应的图片文件。客户端在表情面板里长按某张表情即可触发删除。

### 2.5 AI 发表情包

AI 在回复正文里嵌入 `[sticker:<id>]`，总线钩子抽出后，客户端把对应表情渲染成图片气泡。约定：

- `id` 必须来自 `GET /stickers/list` 返回的实时列表，**不可编造**；编造的 id 会被当普通文字漏出或找不到图。
- 一个气泡段落里最多放一个表情标签。
- 没有要发表情的回合，正文里不应出现该标签。

---

## 三、拍一拍配置

### 3.1 工作原理

微信主题里双击对方头像即可触发拍一拍：头像出现摇晃动画、触觉反馈，并在聊天流里插入一条居中灰字系统消息。AI 也可以反向拍用户，并发送一条系统推送（锁屏可见）。

### 3.2 频率闸配置

反向拍一拍带频率闸，防止滥用。在服务端初始化处配置：

```python
self.patpat_gate = PatPatGate(
    "<数据目录>/patpat_state.json",
    daily_cap=3,
)
```

可调参数：

| 参数 | 含义 | 默认 |
|---|---|---|
| `daily_cap` | 每天反向拍一拍次数上限 | `3` |
| `silent_windows` | 静默时段列表，落在区间内的拍一拍直接拦截 | `[("07:20","08:30"), ("18:00","19:00")]` |

- 超过每日上限或落在静默时段时，拍一拍会被静默丢弃（不报错）。
- 状态落地在 `<数据目录>/patpat_state.json`（记录当天日期、计数、最近一次时间）。
- 如需调整静默时段，给 `PatPatGate` 传入自定义的 `silent_windows`，格式为 `[("HH:MM","HH:MM"), ...]`（24 小时制本地时间，左闭右开）。

### 3.3 接口

#### 查询当前频率状态（读）

```
GET /status/patpat
→ { "ok": true, "date": "...", "count": 1, "last_ts": "...", "daily_cap": 3 }
```

#### 触发反向拍一拍（写，需鉴权）

```
POST /status/patpat
Header: X-Auth-Token: <你的 shared_secret>
Body:   { "suffix": "<后缀,可空>", "nick": "<显示昵称>" }
```

服务端会先过频率闸，通过后在聊天流里追加一条带拍一拍标记的记录，客户端微信主题渲染成居中灰字「<昵称>拍了拍我<后缀>」，并发送系统推送。

### 3.4 AI 反向拍一拍

AI 在回复里嵌入 `[拍拍:<后缀>]`（后缀可空，留空即「拍了拍我」），总线钩子抽出后生成拍一拍事件加推送。例如：

- `[拍拍:的脑袋]` → 「<昵称>拍了拍我 的脑袋」
- `[拍拍]` → 「<昵称>拍了拍我」

超过频率上限或处于静默时段时静默丢弃，不会报错，请勿硬刷。

---

## 四、鉴权与安全

- 所有写接口（上传、删除、触发拍一拍）必须带请求头 `X-Auth-Token: <你的 shared_secret>`。
- `shared_secret` 配置在服务端 `config.toml`，请勿提交到公开仓库或泄漏给第三方。
- 表情包 `id` 与上传文件名均会做字符规范化，避免路径穿越；上传大小上限 10MB。
- 本文档所有路径、密钥均为占位示例，部署时替换为你自己的实际值。

---

## 五、项目仓库

完整源码、安装教程与更新说明见 GitHub：

**github.com/CyberSealNull/CcCompanion**
