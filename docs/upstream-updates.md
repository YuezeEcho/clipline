# 上游更新对照

检查日期：2026-10-10。上游 Tendedero 最新发布为 1.3.0，本次读取的 main 为 `db65d2ea84ba5120b4ed90acce2b457d4ad18c4b`。Clipline 的实现源自早期提交 `3c866d94d25ee9d1e008aecd9a78a4e9b2bf06a4`，没有宣称已集成全部最新上游功能。

| 上游版本 | 主要变化 | 与 Clipline 当前版的关系 |
| --- | --- | --- |
| [1.1.0](https://github.com/alejandrobujan/tendedero/releases/tag/v1.1.0) | 录屏挂绳、长按视频裁剪；启动、触发、多屏和内存改进；更多语言 | Clipline 支持录屏与悬停静音预览，未内置视频裁剪；文件保留策略不同 |
| [1.2.0](https://github.com/alejandrobujan/tendedero/releases/tag/v1.2.0) | 图片剪贴板上绳、Quick Look、显示触发设置、照片大小、自定义快捷键、额外监听最多三个文件夹 | Clipline 有独立文字与图片剪贴板页、暂停与退出清空；未提供上述全部选项 |
| [1.3.0](https://github.com/alejandrobujan/tendedero/releases/tag/v1.3.0) | 可保留 25/50/100 张并横向浏览、取下左右全部、更新页面入口、菜单打开时保持展示 | Clipline 固定最多最近 100 张并横向浏览；不能将滚动或录屏称为本修改版独有 |

Clipline 的其他区别包括固定个人照片、独立内置图片编辑器、可调整裁切框、菜单栏空白双击，以及系统截图与录屏目录变化后的内容重载。上游图片剪贴板会存为文件挂在截图行；Clipline 剪贴板历史只存在内存，退出清空。

本次上传保留最新上游提交作为历史父节点，再提交 Clipline 源码快照。这个关系用于保留来源，不代表所有上游新功能已合入 Clipline。
