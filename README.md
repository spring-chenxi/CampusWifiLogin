# Windows 校园网自动登录

登录 Windows 后，脚本会尝试连接你在 Windows 中保存的目标 Wi‑Fi。电脑已连其他 Wi‑Fi 时会停止。目标网络需要网页认证时，脚本会获取当次跳转地址，提交账号密码，再检查能否上网。

| 运营商 | 当前状态 |
| --- | --- |
| 江苏移动 | 已实现 `wlan.jsyd139.com` 入口。模拟测试已覆盖认证表单，南航天目湖现场待验证。 |
| 中国联通 | 等待真实认证页。 |
| 中国电信 | 等待真实认证页。 |

## 先手动试一次

1. 把 `CampusWifiLogin.ps1` 放在固定文件夹。Windows 里先连接一次校园 Wi‑Fi，让电脑保存该网络。
2. 在该文件夹打开 PowerShell。确认信任脚本后，运行以下命令。把 `你的WiFi名称` 改成 Windows 列表里的实际名称。`Check` 仅检查当前连接和认证页，适合在已连 Wi‑Fi、尚未认证时运行。

```powershell
Unblock-File -LiteralPath .\CampusWifiLogin.ps1
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\CampusWifiLogin.ps1 -Mode Check -Ssid '你的WiFi名称'
```

3. 如果显示识别到江苏移动认证表单，就运行 `Setup`，在本机窗口录入手机号和校园宽带密码。随后用 `Run` 测试，看到 `Login succeeded` 表示脚本提交后检测到了互联网连接。

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\CampusWifiLogin.ps1 -Mode Setup
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\CampusWifiLogin.ps1 -Mode Run
```

如果 `Check` 显示已联网，等到下次 Wi‑Fi 需要登录时再验证表单。若显示没有重定向，可以先从 Windows 的 Wi‑Fi 登录提示打开认证页，记录页面的域名和打码截图。脚本会使用本次探测获取的认证地址。

## 启用或关闭开机运行

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\CampusWifiLogin.ps1 -Mode Install
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\CampusWifiLogin.ps1 -Mode Uninstall
```

`Install` 注册当前用户的计划任务，下次进入 Windows 时触发。卸载计划任务后，本机录入的数据仍保留。移动脚本到其他文件夹后，可重新运行 `Install` 更新路径。

## 凭据和诊断

配置和最后一次运行状态写在 `$env:LOCALAPPDATA\CampusWifiLogin`。密码由 Windows 加密后保存在本机。手机号在本机配置中可读，发布 GitHub 时只提交脚本和这份说明。

江苏移动当前适配的是 `wlan.jsyd139.com`。如果认证站点使用 HTTP，密码在网络上传输时没有 TLS 加密。脚本会检查认证域名，并且不会跟随登录请求返回的跳转。

## 扩展运营商

在 `Get-PortalLogin` 中按认证域名加入对应的页面处理，解析当次表单和提交地址。Wi‑Fi 连接、开机触发、本机凭据和联网检查可以复用。

认证页结构参考 [江苏移动校园网登录记录](https://github.com/Lbl-Zms/cmcc-autoconnect/blob/main/README.md) 与 [南航天目湖实测项目](https://github.com/atro1e/CMCCConnect)。
