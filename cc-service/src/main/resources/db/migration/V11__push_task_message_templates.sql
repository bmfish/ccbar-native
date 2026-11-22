-- 随机文案池：静态文案直接作为推送内容；体重/Token 用 [场景] 分组 + 占位符。

update push_task set messages = $msg$起来活动一下，喝口水，看看远处。
站起来伸个懒腰，走两步。
让眼睛休息一下，看看窗外。
别久坐了，起来接杯水吧。
坐久了腰会抗议，起来走两分钟。
肩膀是不是有点僵？转一转，站起来走走。
去接杯水，顺便活动一下腿脚。
盯着屏幕太久了，看看六米外的东西。
站起来做几个深呼吸，放松一下。
久坐伤腰，起来溜达一圈吧。
现在站起来，扭扭脖子，耸耸肩。
去趟洗手间，顺便走几步。
倒杯水，回来时绕个小圈。
让眼睛和腰都休息一下，起身走走。
坐姿换一换，站起来拉伸一下。
已经坐挺久了，起来接杯水吧。
别让椅子粘住你，起来活动两分钟。
站起来，扩扩胸，深呼吸三次。
看看窗外，让眼睛离开屏幕一会儿。
走动一下，血液循环会更好。
腰背放松一下，站起来伸个懒腰。
起来走两步，顺便想想接下来做什么。
喝口水，活动下肩颈，再继续。
久坐一小时，起来活动三分钟。
站起来踮踮脚，活动一下小腿。
去阳台透透气，看看远处。
转转眼珠，站起来走一圈。
坐直一点，然后起来活动活动。
给身体两分钟，站起来走走吧。
别一直坐着，起来接杯水、伸个懒腰。$msg$ where task_type = 'TEXT';

update push_task set messages = $msg$[已称] 今日体重 {weight} kg，较上次 {delta}。
[已称] 上秤结果：{weight} kg，比上次{deltaPhrase}。
[已称] 今天 {weight} kg，变化 {delta}，继续保持。
[已称] 体重播报：{weight} kg（{delta}）。
[已称] 今日体重 {weight} kg，比上次{deltaPhrase}。
[已称] 称完啦：{weight} kg，较上次 {delta}。
[已称] 今天 {weight} kg，上次是 {lastWeight} kg。
[已称] 上秤了：{weight} kg，较上次 {delta}，继续加油。
[已称] 体重已记录：{weight} kg，变化 {delta}。
[已称-无对比] 今日体重 {weight} kg。
[已称-无对比] 上秤结果：{weight} kg。
[已称-无对比] 今天体重 {weight} kg，先记录一下。
[已称-无对比] 体重已记录：{weight} kg。
[未称] 今天还没称体重，上次是 {lastDate} 的 {lastWeight} kg，记得上秤记录一下。
[未称] 还没上秤哦，最近一次是 {lastDate} 的 {lastWeight} kg。
[未称] 今天体重还没记录，上次 {lastDate} 是 {lastWeight} kg，去称一下吧。
[未称] 别忘了称体重，上次记录是 {lastDate} 的 {lastWeight} kg。
[未称] 秤在等你，上次 {lastDate} 是 {lastWeight} kg。
[未称] 今天还没上秤，上次 {lastDate} {lastWeight} kg，抽空称一下吧。
[未称] 体重还没记录，上次是 {lastDate} 的 {lastWeight} kg。
[无数据] 还没有体重记录，先上秤称一次吧。
[无数据] 体重数据还是空的，今天开始记录一下吧。
[无数据] 第一次上秤后，这里就会有体重播报了。$msg$ where task_type = 'WEIGHT';

update push_task set messages = $msg$[有Token] 今日 Token {tokens}（{breakdown}），积分 {credits}。
[有Token] 今天用了 {tokens} Token，积分 {credits}。
[有Token] 今日用量：{tokens} Token，{credits} 积分。
[有Token] Token 消耗 {tokens}，积分 {credits}，继续保持。
[有Token] 今天已经消耗 {tokens} Token（{breakdown}），积分 {credits}。
[有Token] 今日 Token 小结：{tokens}，积分 {credits}。
[有Token] 今日输入 {input}、输出 {output}，共 {tokens} Token，积分 {credits}。
[有Token] 今天 Token 用了 {tokens}，积分 {credits}，注意休息。
[仅积分] 今日积分 {credits}，今天没有 Token 消耗。
[仅积分] 今天还没用 Token，积分消耗 {credits}。
[仅积分] 今日积分 {credits}，Token 用量为 0。
[仅积分] 今天没有 Token 消耗，积分 {credits}。
[仅积分] 今日只用积分 {credits}，还没有 Token 记录。
[仅积分] 积分消耗 {credits}，今天暂无 Token 用量。
[无消耗] 今天没有 Token 消耗，积分 0。
[无消耗] 今日暂无消耗，休息得不错。$msg$ where task_type = 'TOKEN_USAGE';
