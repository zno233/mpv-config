# mpv-config

个人 mpv 播放器配置，主要运行在 Linux(wayland) 平台下。

## 目录结构

```
.
├── mpv.conf                # 主配置文件（视频、音频、字幕、截图等核心设置）
├── profiles.conf           # 条件配置组（平台适配、播放控制、画质优化）
├── input_uosc.conf         # 快捷键绑定（uosc 菜单集成）
├── fonts.conf              # 字体配置
├── fonts/                  # 自定义字体目录
├── scripts/                # Lua 脚本
├── script-opts/            # 脚本配置文件
└── shaders/                # GLSL 着色器

```

## 快捷键

详见 `input_uosc.conf`，主要依赖 uosc 提供的交互。

## 使用

```bash
# 克隆到 ~/.config/mpv
git clone https://github.com/zno233/mpv-config.git ~/.config/mpv
````

## 参考

- [hooke007/mpv_PlayKit (MPV_lazy)](https://github.com/hooke007/mpv_PlayKit) — 主要配置来源
- [dyphire/mpv-config](https://github.com/dyphire/mpv-config) — 社区配置参考
