# r2 增量

按鹰眼71213fb3及GA e50722ae修订；r1源码ZIP 564e114f保持不变。

- 新增JSONResponseParser，手动/自动扫描共享：兼容纯JSON、json或无标签围栏；不接受正文夹杂或损坏JSON。
- worker状态新增兼容旧格式的lastRun（时间、新增数、失败标记、固定原因码）。设置开关下方显示结果，完成/失败时通知刷新、应用激活时鲜读。只读状态API不触发扫描；状态损坏仍拒绝覆盖。prepared对账成功显示recovered确认数，避免实际已提交却长期显示失败。
- 普通润色回退后，等粘贴回调确认dispatch才提示“原文已贴；点此再贴一份润色版”；未dispatch则普通失败提示。翻译重试缺LLM改为配置提示，不重复生成重试通知。
- DictionaryService.lastError读写均使用原NSRecursiveLock；损坏文件路径并发200次操作通过ThreadSanitizer，无诊断。
- provider为none或未配齐URL/model时不扫描，也不登记当日机会；既有已核候选仍可落库。hasConfiguredProvider只看配置元数据，不读Keychain。
- attemptedDays保留最新观察日期锚点往前30个本地日历日期；已对账audit只保留该窗口且最多200条。未对账prepared保留并先恢复，避免删事故凭据；状态不能完成对账时不会追加新写入。近期时钟回拨不删除已claim的较晚日期，超出保留窗口的回拨不承诺永久防重复。

新增回归覆盖围栏解析、lastRun成功/失败及隐私、旧状态兼容、none不占claim、provider恢复后同日可扫、30日/200条裁剪、保留未决prepared、对账恢复回显及损坏只读状态。恢复侧为26+5+5检查，另200次并发操作；词库106断言。各轮测试使用临时路径/桩，不碰真实用户数据或模型。
