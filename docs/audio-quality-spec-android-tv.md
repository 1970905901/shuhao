# 音质体系完整实现方案(给 Android TV 实现用)

本方案来自 iOS 版(lx-music v4 用户脚本协议播放器)已验证落地的实现,包含:扩展音质档位、JS 预加载脚本变更、选档/降级逻辑、真实音质探测与显示、角标按实测校正、设置最高音质、下载音质选择。请按以下规格在 Android TV 端实现一遍。

---

## 1. 音质档位体系

完整 8 档,字符串值即 lx 协议里 `musicUrl` 请求的 `type` 字段,必须逐字一致:

| 枚举 | 协议字符串 | 显示名 | 实际容器 |
|---|---|---|---|
| K128 | `128k` | 标准 128k | MP3 |
| K320 | `320k` | 高品 320k | MP3 |
| FLAC | `flac` | 无损 FLAC | FLAC 16bit/44.1 |
| FLAC24 | `flac24bit` | Hi-Res 24bit | FLAC 24bit |
| HIRES | `hires` | Hi-Res 高解析 | FLAC 24bit |
| ATMOS | `atmos` | 臻品全景声 | FLAC |
| ATMOS_PLUS | `atmos_plus` | 臻品全景声 2.0 | FLAC 16bit/44.1 双声道渲染 |
| MASTER | `master` | 臻品母带 | FLAC 24bit / 88.2–192kHz |

排序(高→低,降级级联和"选最高"都用这一个顺序,单一事实来源):

```
master > atmos_plus > atmos > hires > flac24bit > flac > 320k > 128k
```

**扩展档位(isExtendedTier)概念**:`hires / atmos / atmos_plus / master` 这四档。官方搜索接口的曲目元数据几乎从不报这些档位,所以可用性判断**不能要求曲目元数据里有**,只看脚本声明(见第 3 节)。猜错了也没关系,会走降级级联。

角标(Badge)映射:

```
master            → "Master"
atmos_plus, atmos → "Atmos"
hires, flac24bit  → "Hi-Res"
flac              → "SQ"
320k              → "HQ"
128k              → "STD"
```

---

## 2. JS 预加载脚本(preload)的变更

lx 协议的 preload 里有一个 `supportQualitys` 白名单,用来在脚本 init 时过滤脚本自己声明的能力。**旧版白名单只到 `flac24bit`,导致脚本声明的 hires/atmos/master 在 init 阶段就被过滤掉,app 永远选不到这些档位。** 必须扩展为:

```js
const supportQualitys = {
  kw: ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'atmos_plus', 'master'],
  kg: ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'atmos_plus', 'master'],
  tx: ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'atmos_plus', 'master'],
  wy: ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'atmos_plus', 'master'],
  mg: ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'atmos_plus', 'master'],
  local: [],
}
```

脚本最终生效的能力 = 脚本 init 时声明的 qualities ∩ 这个白名单。新版 lx-music-mobile 也是这么放开的。

musicUrl 请求载荷不变:`{ type: <协议字符串>, musicInfo: <旧版字段格式的曲目信息> }`,返回值仍然**只有 URL 字符串** —— 协议盲点:后端响应里其实带真实音质字段(如 `quality: "flac"`),但脚本层把它丢了,宿主无从得知是否被静默降级。这正是第 5、6 节存在的原因。

---

## 3. 选档逻辑(pickPlayQuality + 降级级联)

输入:用户首选档位 preferred(来自设置)、曲目元数据档位集合 trackQualities、脚本声明档位集合 scriptQualities。

**选档**:从 preferred 开始沿排序往下找,第一个满足以下条件的档位即生效档:

```
(trackQualities.contains(q) || q.isExtendedTier) && scriptQualities.contains(q)
```

即普通档位要求"元数据有 + 脚本声明",扩展档位只要求"脚本声明"(旁路元数据)。

**降级级联**:从生效档开始,把排序里它以下所有满足同一条件的档位组成列表,逐个请求脚本直到拿到 URL。`128k` 是全局保底 —— 即使脚本没声明也要尝试。每降一档给用户一个软提示("XX 远程不支持,已降级到 YY")。

**播放器格式拒绝二次降级**:拿到 URL 后播放器(ExoPlayer)可能报不支持的格式(例如酷我 hires 实际返回加密 `.mgg` 文件)。此时按当前档位再往下重新解析一次,更新"实际播放档位"。

宿主必须记录 **currentQuality = 实际成功解析出 URL 的那一档**(级联后的结果),不是用户首选档。

---

## 4. 设置:最高音质选择

- 选项列出全部 8 档(显示名见第 1 节表格),存为用户首选 preferred。
- 每档配图标;iOS 端全景声两档用的是空间音频人头图标(注意 iOS 上 `spatial.audio` 不是合法符号,踩过坑),Android 自选等价 Material 图标即可。
- preferred 只是上限意图,实际播放档由第 3 节逻辑决定。

---

## 5. 真实音质探测(文件头实测,核心新功能)

**动机**:音源后端会静默降级。实测案例:酷我请求 hires,一首返回加密 `.mgg`,另一首后端 JSON 里自己写着 `quality:"flac"` 但脚本只回传 URL,实际文件是 FLAC 16bit/44.1kHz;app 还以为 hires 成功。所以**不信任声称档位,自己解析文件头**。

### 5.1 取字节

- 远端 URL:HTTP `Range: bytes=0-65535` 请求取前 64KB;**手动截断** —— 有的 CDN 不认 Range 返回整个文件,读满 count 字节就停。超时 10s。UA 用移动端 UA。
- 本地文件:直接 seek+read。
- 任何失败返回 null,**永不抛错**,UI 不显示就是了。

### 5.2 识别与解析

按文件头 magic 分派:

**FLAC**(前 4 字节 = `fLaC`):STREAMINFO 永远是第一个 metadata block(规范保证)。校验偏移 4 处字节 `& 0x7F == 0`(block type 0)。从偏移 `8+10` 起取 8 字节按大端拼成 64 位整数 `packed`:

```
sampleRate    = packed >> 44          (20 位, Hz)
channels      = ((packed >> 41) & 7) + 1
bitsPerSample = ((packed >> 36) & 0x1F) + 1
```

**MP3 带 ID3v2**(前 3 字节 = `ID3`):标签长度 = 4 字节 syncsafe(偏移 6–9,每字节 7 位):`size = (b6<<21)|(b7<<14)|(b8<<7)|b9`,帧数据从 `10+size` 开始。标签里常嵌封面可能超过 64KB 缓冲 —— 超出时对 `10+size` 位置**再发一次 Range 请求**取 8KB。

**裸 MP3 / 其他**:在缓冲里扫帧同步字。扫描窗口 ≤8192 字节,找 `0xFF` 且下一字节 `& 0xE0 == 0xE0`:

```
versionBits = (b1 >> 3) & 0x3   // 0=MPEG2.5, 2=MPEG2, 3=MPEG1; 1 非法跳过
layerBits   = (b1 >> 1) & 0x3   // 必须 == 1 (Layer3)
bitrateIdx  = b2 >> 4           // 0 和 15 非法跳过
rateIdx     = (b2 >> 2) & 0x3   // 3 非法跳过

MPEG1 Layer3 码率表: [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320] kbps
MPEG2/2.5 表:       [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160] kbps
MPEG1 采样率: [44100,48000,32000]; MPEG2: [22050,24000,16000]; MPEG2.5: [11025,12000,8000]
```

未知容器(m4a、加密 .mgg 等)自然解析失败返回 null —— 这是预期行为。

### 5.3 结果模型与显示

```
AudioSpec { codec: "FLAC"|"MP3", sampleRate: Hz, bitsPerSample: Int?(FLAC), bitrateKbps: Int?(MP3) }
显示文本: "FLAC 24bit/192kHz" / "FLAC 16bit/44.1kHz" / "MP3 320kbps"
(kHz 整数不带小数,非整数保留 1 位)
```

### 5.4 接入播放流程

- 每次开始播放新 URL:先把 currentAudioSpec 置 null,然后**异步**探测(不阻塞播放)。
- 探测回来时校验"当前播放 URL 是否还是发起探测时那个",不是就丢弃(防快速切歌串台)。
- UI 在播放器页把实测文本显示在角标旁,探测中/失败不显示,出现时淡入。

---

## 6. 角标按实测自动校正(displayQuality)

角标不直接显示 currentQuality,而是用实测规格把声称档位**只往下钳,不往上提**:

```
displayQuality(claimed = currentQuality, spec = currentAudioSpec):
  claimed 为 null → 不显示
  spec 为 null(探测中/失败) → 按 claimed 显示
  按 spec 算上限 ceiling:
    MP3:
      bitrateKbps >= 256 → ceiling = 320k
      否则               → ceiling = 128k
    FLAC 且 bitsPerSample > 16:
      sampleRate >= 176400 → ceiling = master   (母带要求 24bit 且 ≥176.4kHz)
      否则                 → ceiling = hires    (普通 24bit 最高算 Hi-Res)
    FLAC 16bit:
      claimed 是 atmos 或 atmos_plus → 直接返回 claimed
        (全景声 2.0 就是 16/44.1 双声道渲染,规格上和 CD 无异,放行)
      否则 → ceiling = flac
  返回 rank 较低者: claimed 高于 ceiling 时返回 ceiling,否则 claimed
```

所有显示角标的位置(播放页、迷你播放条等)统一用 displayQuality。效果:酷我假 Hi-Res 实发 16/44.1 FLAC 时角标自动显示 SQ,实发 128k MP3 时显示 STD。

---

## 7. 下载音质选择

- 下载弹窗的可选档位 = **曲目元数据档位 ∪ 脚本为该平台声明的扩展档位**(和第 3 节同一旁路逻辑,否则永远下不到 atmos/master):

```
available = ranked.filter { trackQualities.contains(it) || (it.isExtendedTier && scriptQualities.contains(it)) }
```

- 默认选中 available 里最高档。
- 下载解析复用播放的整套 resolveMusicURL(脚本 → 跨平台兜底 → 直连兜底),带降级级联。
- **文件扩展名**:优先信任 URL 自带扩展名(白名单 mp3/flac/m4a/wav/ogg —— 顺便覆盖后端降级把 hires 请求实发 mp3 的情况);URL 没有可识别扩展名时按档位推断:`128k/320k → .mp3`,其余(含 flac/hires/atmos/master)→ `.flac`。注意旧实现只把 flac/flac24bit 当 FLAC,扩展档位全被错误地存成 .mp3,这是个已修复的 bug,别重蹈。

---

## 8. 已知现实情况(实测结论,实现时心里有数)

- **网易云(wy)**:master(超清母带 AI 重制)几乎全曲库可用,真 24bit/88.2–192kHz FLAC。
- **QQ(tx)**:文件名前缀可佐证档位 —— `AI` 开头 = 臻品母带(24/192),`Q0` = 臻品全景声 2.0(16/44.1 渲染),`F0` = 普通无损。
- **酷我(kw)**:脚本通常最高只声明 hires;请求 hires 后端经常静默降级 —— 返回普通 16/44.1 FLAC,或返回加密 `.mgg`(不可播放,触发格式拒绝二次降级到 128k)。第 6 节的校正就是为这种情况设计的。
- 协议层永远只回 URL,后端真实音质字段被脚本丢弃 —— 不要指望从协议拿到真相,只能文件头实测。
