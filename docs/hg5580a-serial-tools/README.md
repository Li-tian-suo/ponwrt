# HG5580A 串口调试脚本

HG5580A 通过 U-Boot 用 TFTP 启动 initramfs 做调试，不写 flash。
这套脚本在 Windows PowerShell 5.1 下实测可用。

## 前置条件

1. **串口**：CH340，115200 8N1。本机枚举为 `COM4`。
   注意断电会让 CH340 一起掉线，COM4 会消失几秒再回来。

2. **网络**：PC 网卡设静态 IP `192.168.1.126/24`，直连光猫 LAN1。
   U-Boot 侧 `ipaddr=192.168.1.1`、`serverip=192.168.1.126` 已是默认值。

3. **TFTP 服务**：把镜像放到一个目录，然后在 WSL 里起服务：

   ```bash
   python3 tools/tftpd.py --root <镜像目录> --port 69
   ```

   镜像目录里把 initramfs 复制成短名字，方便手敲：

   ```powershell
   Copy-Item ponwrt-airoha-an7583-fiberhome_hg5580a-initramfs-uImage.itb initramfs.itb
   ```

## 脚本说明

| 脚本 | 用途 |
| --- | --- |
| `wait-com.ps1` | 等 COM 口出现（断电后串口会消失） |
| `serial-read.ps1` | 只读串口，看当前状态 |
| `serial-cmd.ps1` | 发一条命令并抓回显 |
| `serial-batch.ps1` | 连续发多条命令，结果存文件 |
| `bringup4.ps1` | **主脚本**：抢 U-Boot → 登录 → tftpboot → bootm |
| `bringup-wait.ps1` | 先等 COM 口再调用 `bringup4.ps1` |
| `test-login-logic.ps1` | 登录状态机的离线回归测试，改动逻辑后先跑这个 |

## 用法

```powershell
# 完整启动流程（最常用）
$sb = [scriptblock]::Create((Get-Content .\bringup4.ps1 -Raw))
& $sb -Port COM4 -User <uboot用户名> -Pass <uboot密码> `
     -Kernel initramfs.itb -LoadAddr 0x88000000 `
     -BreakSeconds 420 -BootCaptureMs 180000
```

```powershell
# 设备已经起来后，跑一组诊断命令
$sb = [scriptblock]::Create((Get-Content .\serial-batch.ps1 -Raw))
& $sb -Port COM4 -SettleMs 2500 -OutFile .\dev-state.txt -Commands @(
  'uname -a',
  'cat /proc/mtd',
  'ip -br link',
  'dmesg | grep -i "pon\|bosa" | tail -20'
)
```

## 两个必须知道的坑

### 1. FIT 不能加载到 0x82000000

```
解压后内核 Image = 35,586,056 B (33.94 MiB)，基址 0x80200000
→ 结束于 0x823f0008，越过 0x82000000
→ FIT 被内核解压覆盖
   ERROR: new format image overwritten - must RESET the board
```

必须用 `0x88000000`（离内核基址 126 MiB，足够安全）。

### 2. 登录期间不能继续发 Ctrl-C

vendor U-Boot 的 `Ctrl-C` 会清空当前输入行。如果在登录时还在发打断键：

```
UserName: *          ← 8 个字符只回显了 1 个
Password: *
```

用户名被打断，密码最后进了用户名字段。

**规则**：一旦看到 `UserName:` 或 `Password:`，立刻停止发送任何打断键。
`bringup4.ps1` 已按这个规则实现，`test-login-logic.ps1` 对它做回归测试。

```powershell
# 改动 bringup4.ps1 的判定逻辑后，先跑这个
$sb = [scriptblock]::Create((Get-Content .\test-login-logic.ps1 -Raw))
& $sb
# 期望输出：=== overall: ALL PASS ===
```

## 相关文档

- `docs/hg5580a-debug-progress.md` —— 上机实测结果、MAC 问题分析、PON 阻塞点
