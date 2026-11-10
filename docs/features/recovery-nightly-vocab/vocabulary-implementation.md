# 每晚自动词库更新：实现与复核入口

## 接口与集成

`@MainActor DictionaryAutoUpdateService.makeDefault(isIdle:)` 返回一个由 App 持有的实例。启动、`NSWorkspace.didWakeNotification` 和空闲检查定时器调用 `await service.tick()`。`isIdle` 必须覆盖普通听写、BlackBox 重处理等前台流水线。worker 自身阻止重入；LLM 返回后再次检查开关、空闲和日期，忙时保留已验证候选，后续空闲 tick 不再请求模型，只尝试落库。

`ConfigService.dictionaryAutoUpdateEnabled` 默认 true，设置界面“每晚自动更新词库”经现有 ConfigService.write 写入；未知 config 字段保留。默认扫描调用原 `LLMService.completeWithNamedProvider`，服务商取当前配置 `llmProvider`；未新增凭据读取、外部脚本或 cron。测试只用可注入 scanner/目录/日期/日历/历史/别名/配置/空闲闭包，桩禁止访问真实 history、LLM、Keychain。

## 时间、增量和次数

- 本地 03:00 以后首个空闲 tick 执行；启动或唤醒也走相同判断。03:00 前不补前一天；当天 03:00 后补当天。
- 调模型前原子持久化本地日期 claim，失败或崩溃也不在同一天再次付费。以当前 now 为基准保留当天及过去 29 个本地日历日期的 claim；比 now 晚的日期全部保留，不让一次错误的未来时钟裁掉今天的 claim。r2 retentionAnchor 字段仅兼容读取，不再作为窗口依据。不使用日期字符串字典序。
- 只扫描游标后的新增非翻译历史；游标含完整浮点时间和同时间戳已扫记录 SHA-256，批次最多 150 条。超过 150 条的剩余新增历史后夜继续，不推进越过它们。
- 成功解析响应才推进扫描游标；请求/JSON 失败保留游标，下一天可重试该批。无新增历史时不请求 LLM，仍可处理旧候选。
- “一天最多一次”指一次扫描尝试；同日后续空闲 tick 允许完成该次响应已留存的写入。每天累计写入最多 10 条，剩余候选后夜接续。

## 确定性安全边界

- 提案必须给真实输入 recordIDs；独立查每条记录包含完整 wrong（英文词界，中文可邻接）。去重后至少两个不同记录 ID 才能自动接受。不采用模型声称的次数；同一个 recordID 列多次也只计一次。
- 同 wrong 的不同 suggested 冲突一律不写；字典已有 wrong 或 suggested 不写；与别名源/目标相同或短语重叠不写。已知别名规则损坏拒绝自动扫描/写入；缺文件是空别名；无关未知行保持原文件不变并忽略。
- regex 别名只在最多 40 字符候选上进行有界匹配，沿用 AliasService 的 ICU .reportProgress / stop 取消方式、10ms 截止和 4096-byte pattern 上限；命中、无效或超时都拒绝该候选，正常结束且不匹配才放行。没有更改用户现有 regex。
- wrong/suggested 必须 2–40 个字符、最多 5 个空白分词、含字母或汉字、无控制字符。wrong 经过内置常用中英文词拒绝表；所有全小写单个英文词也拒绝。此表是保守过滤，不宣称覆盖所有语言的常用词。模型仍必须遵守 proper noun / 技术专名规则。
- 历史只保存最终转写，没有可核对的“原始 ASR → 人工订正”对照；机器证据能证明 wrong 重复出现，不能单独证明 suggested 的语义必然正确。初期建议复核实际自动新增日志。

## 文件、安全写入和日志

`dictionary.json` 沿用数组格式；新增前鲜读，未知数组项保留。所有字典改动（自动及原手动入口）都经 JSONBackupStore 备份，最多五份；错误 JSON/错误顶层类型拒写；备份前后校验原字节，检测手工编辑漂移；最终用原子 rename。

`~/.vox/dictionary-auto-update.json` 为 worker 状态及自动修改日志，权限 0600。只含日期 claim、扫描游标/哈希、wrong/suggested、去重记录哈希、明确 occurrences、审计时间和状态；不含听写正文、模型原响应、上下文摘录或凭据。

先保存 `prepared` 审计，再原子写字典，再保存 `committed` 审计。中途崩溃，下个 tick 鲜读字典核对：目标全部存在则确认提交，全部不存在则记 not_applied 并保留候选，部分存在拒绝自动续写。由此不把内存中的一次成功当落盘完成。

## 复核命令与证据

```
bash scripts/task327-vocab/run.sh
```

r3 当前结果：114 个断言通过。覆盖时间/空闲/开关门槛，真实重复证据、虚构/重复 ID 拒绝，常用词/长度/既有词/别名冲突，每日 10 条与跨夜余项、同时间戳 150+5 条增量、失败日不再付费、时钟回拨、LLM 返回时前台优先与开关变化、损坏文件、备份保留数、prepared 崩溃恢复、并发 tick、配置未知字段及无凭据调用，以及无关/匹配/无效/病态 regex 的有界放行与拒绝。

测试二进制使用 swiftc 真实编译并链接 worker、DictionaryService、ConfigService、JSONBackupStore；`CryptoKit` 是 Apple Swift 系统模块，当前编译不需要额外 `-framework`（模块自动链接），没有新外部依赖。主流程负责全量 App 编译及独立鹰眼审阅。本说明不代表装机或真实每晚运行验收。


## r2 增量（独立复核入口）

- `Vox/Utilities/JSONResponseParser.swift` 为手动与自动扫描共用的围栏解析器；接受纯 JSON、单层无标签或 json 代码围栏，保留正常 JSON/schema 验证。损坏 JSON、缺少结尾围栏、未知标签、外围说明文本仍失败，不解析猜测片段。
- 构造注入 `canScan: () -> Bool = { true }`。默认工厂只读 ConfigService 已有非秘密快照，provider 缺失、none 或缺 URL/model 时不扫描、不占当日 claim；仍可接受已有验证候选。未配置不是一次运行，不能伪造 lastRun 时间；配置后同一天仍可正常首次扫描。
- `lastRun` 为可选字段（r1 JSON 兼容）：timestamp、added、failed、reasonCode。失败只有枚举 code；不会保存 localizedDescription、请求内容或模型原响应。定时器重复 skip 不覆盖上次失败；设置页通过只读 `readLastRun(directory:)` 读取，刷新不触发扫描，坏 state 原样保留。
- 设置开关下显示上次时间、新增数、结果和具体原因；缺 provider 的当前提示单列，保留上次实际执行时间。状态完成通知和 App 激活均使用 selector observer 刷新，没有新增 Sendable capture。
- `attemptedDays` 保留以 now 为基准的最近 30 个本地日期，并额外保留所有未来日期。已对账的非未来 audit 在该窗口内最多 200 条，未来 audit 全部保留（GA4dddb6ce 新口径）；不是按最大历史日期裁剪。每次保存都执行同样规则。旧未决 prepared 先对账；无法对账时不删 prepared、不新建事务；未决 prepared 不受裁剪限制。
- prepared 已写入字典但上次状态保存失败时，重启确认实际字典后将 lastRun 记为 recovered、failed=false；added 是本次恢复确认的原新增数，设置页明确“已核实上次写入（未重复写入）”，没有再次改字典或调模型。

r2 新测试覆盖：共享解析器四种正常/五种损坏响应；none/missing/无效 provider；none 不消耗 claim、配置后同日扫描；无模型仍可落已验证候选；固定失败码/不存正文及 raw 错误；纯状态读取无副作用；坏 state 不覆盖；r1 字段兼容；65 日期→30、251 条 audit→200、近期回拨保留已 claim 较晚日期；老 prepared 未对账保留和阻断，以及成功恢复对账状态回显。

## r3 时钟回归

原样复跑鹰眼复现，r2拨回当天5次扫描；r3将其转成断言，仅1次。另核往回拨再恢复已用日期、当前与未来claim同时落盘、未来audit及旧future anchor兼容。所有请求均为计数桩。
