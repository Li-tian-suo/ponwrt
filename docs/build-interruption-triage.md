# OpenWrt 鏋勫缓涓柇鐨勬帓鏌ョ瑪璁?
> 涓€娆′粠闆堕噸寤轰腑閬囧埌鐨勫洓涓€岀湅璧锋潵澶辫触浣嗗師鍥犲悇涓嶇浉鍚屻€嶇殑鏃跺埢

---

## 1. 涓ゅ彴鏋勫缓鏍戞贩娣?
### 鐥囩姸

鎺掓煡鍗′綇鐨勫寘鏃剁湅鍒帮細

```
pid 30    make package/feeds/pon_userspace/airoha-pon-daemons/compile
pid 2240  cargo install -v --profile release --root .../airoha-pon-daemons-0.3.0/ipkg-install
pid 15    bash /mnt/h/Deepseek/WSL/retry_pondaemons.sh
```

鐪嬭捣鏉ユ槸銆屾垜鐨勬瀯寤哄崱鍦?PON 瀹堟姢杩涚▼銆嶃€?
### 瀹為檯

```sh
$ readlink -f /proc/30/cwd
/home/build/hg5380a          鈫?鍙︿竴涓瀯寤烘爲锛?2 GB锛?
$ du -sh /root/build/hg5580a
2.9G                          鈫?鎴戝疄闄呭湪鐢ㄧ殑
```

**涓や釜鐙珛鐨勬瀯寤烘爲鍚屾椂瀛樺湪**锛岄偅浜涜繘绋嬪叏灞炰簬鍙︿竴涓€傛垜鐨勬瀯寤烘牴鏈病鍦ㄨ窇銆?
### 鏁欒

鍒ゆ柇銆屾瀯寤烘槸鍚﹀湪璺戙€嶆椂锛?*蹇呴』鎸?cwd 杩囨护杩涚▼**锛屼笉鑳藉彧鐪?`pgrep -x make`锛?
```bash
for p in $(pgrep -x make); do
	cwd=$(readlink -f "/proc/$p/cwd" 2>/dev/null)
	case "$cwd" in
		/root/build/hg5580a*) echo "mine: pid $p" ;;
		*) echo "other: pid $p -> $cwd" ;;
	esac
done
```

---

## 2. `Select-Object -Last N` 鏉€姝绘瀯寤?
### 鐥囩姸

浠?PowerShell 鍚姩鏋勫缓锛?
```powershell
wsl -d Ubuntu -- bash rebuild.sh 2>&1 | Select-Object -Last 25
```

鏋勫缓璺戜簡鍑犲垎閽熷悗杩涚▼娑堝け锛屾棩蹇楁湯灏炬槸姝ｅ父缂栬瘧琛岋紝娌℃湁閿欒銆?
### 鍘熷洜

`Select-Object -Last N` 蹇呴』**缂撳啿鍏ㄩ儴杈撳叆**鎵嶈兘鐭ラ亾銆屾渶鍚?N 琛屻€嶆槸浠€涔堬紝
鎵€浠ュ畠浼氫竴鐩存寔鏈夌閬撲笉鏉炬墜銆傚綋鎷ユ湁璇ョ閬撶殑 PowerShell 浣滀笟琚竻鐞嗘椂锛?绠￠亾鍏抽棴锛學SL 渚х殑 shell 鏀跺埌 `SIGHUP`锛岀紪璇戝仠姝€?
`setsid nohup` 鍦ㄧ閬撻噷涔熸病鐢?鈥斺€?杩涚▼缁勮劚绂讳簡缁堢锛屼絾**浠嶇劧鎸傚湪绠￠亾涓?*銆?
### 淇硶

褰诲簳鏂紑绠￠亾锛屾妸杈撳嚭閲嶅畾鍚戝埌鏂囦欢锛?
```bash
setsid nohup /path/to/build.sh >> /tmp/build.log 2>&1 < /dev/null &
```

鐒跺悗閫氳繃璇绘枃浠剁湅杩涘害锛岃€屼笉鏄寔鏈?stdout銆?
---

## 3. 鏃ュ織閲岀殑 NUL 瀛楄妭璁?grep 澶辨晥

### 鐥囩姸

```sh
$ grep -E 'Error' /tmp/build.log
grep: /tmp/build.log: binary file matches
```

```sh
$ tail -8 /tmp/build.log
锛堣緭鍑哄叏鏄┖鐧斤級
```

### 鍘熷洜

`apk`銆乣ninja`銆乣go` 杩欑被宸ュ叿浼氬線 stdout 鍐?*浜岃繘鍒舵帶鍒跺簭鍒?*锛堣繘搴︽潯銆?缁堢杞箟銆佺敋鑷冲師濮嬫暟鎹級銆傛棩蹇楄鍒ゅ畾涓?binary锛宍grep` 榛樿涓嶆墦鍗板唴瀹癸紝
`tail` 鎵撳嵃鍑烘潵鐨勩€岃銆嶇湅鐫€鏄┖鐨勩€?
### 淇硶

鐢?`strings` 鍏堣繃婊ゅ嚭鍙墦鍗板唴瀹癸細

```bash
strings /tmp/build.log | grep -v '^[[:space:]]*$' | tail -40
```

鎴栬€呭己鍒?`grep -a`锛?
```bash
grep -a -E 'Error [0-9]+' /tmp/build.log
```

**鎺掓煡浠讳綍 OpenWrt 鏋勫缓鏃ュ織閮藉簲璇ラ粯璁ゅ姞 `-a` 鎴栬蛋 `strings`銆?*

---

## 4. stale ninja lock 闃诲 apk

### 鐥囩姸

`hostpkg` 闃舵鏈€鍚庝竴涓椿鍔ㄧ洰褰曟槸锛?
```
build_dir/hostpkg/apk-3.0.5/openwrt-build/
  .ninja_lock   0 瀛楄妭
  .ninja_log    0 瀛楄妭
  .ninja_deps   0 瀛楄妭
```

涔嬪悗娌℃湁浠讳綍鏂版枃浠讹紝鏃犺繘绋嬫畫鐣欙紝鏃?OOM锛?9 GiB 鍐呭瓨绌洪棽 15 GiB锛夈€?
### 鍘熷洜

`apk`锛圓lpine 鐨勫寘绠＄悊鍣紝OpenWrt 鏂扮増鏈敤瀹冩浛浠?opkg锛夌敤 CMake + ninja 鏋勫缓銆?涓婁竴娆℃瀯寤鸿涓柇鏃剁暀涓嬩簡 `.ninja_lock`锛岄噸璺戞椂 ninja 璁や负鍙︿竴涓疄渚嬫鍦ㄨ繍琛岋紝
浜庢槸绛夊緟鎴栫洿鎺ユ斁寮冦€?
### 淇硶

閲嶈窇鍓嶆竻鎺夐攣锛?
```bash
rm -f build_dir/hostpkg/apk-*/openwrt-build/.ninja_lock
```

娓呯悊鍚庡悓涓€闃舵绔嬪嵆瀹屾垚锛?
```
13:41:48  apk-3.0.5      鈫?涔嬪墠鍗′綇
13:52:14  go-1.24.13
13:52:15  luci-base
```

---

## 5. 瀹屾暣鐨勭幆澧冧慨澶嶆竻鍗?
鍦?WSL 涓婁粠闆舵瀯寤?OpenWrt锛屼竴鍏辫澶勭悊杩欏嚑浠朵簨锛?
| # | 闂 | 淇硶 |
| --- | --- | --- |
| 1 | 甯︾┖鏍肩殑 Windows 璺緞鐮村潖 make 鐨?PATH 澶勭悊 | 鍙紶 POSIX PATH锛歚export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` |
| 2 | `configure: you should not run configure as root` | `export FORCE_UNSAFE_CONFIGURE=1` |
| 3 | 鍩虹宸ュ叿琚鎶ョ己澶?| 瑁?`unzip bzip2 wget coreutils perl file` |
| 4 | 浜ゅ弶缂栬瘧鍣ㄧ己澶?| `apt-get install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu` |
| 5 | 绠￠亾 SIGHUP 鏉€姝绘瀯寤?| `setsid nohup ... >> log 2>&1 < /dev/null &` |
| 6 | 鏃ュ織 binary 鍖?| `grep -a` 鎴?`strings` |
| 7 | ninja lock 娈嬬暀 | `rm -f build_dir/hostpkg/apk-*/openwrt-build/.ninja_lock` |

### 涓€鏉″彲澶嶇敤鐨勫惎鍔ㄨ剼鏈?
```bash
#!/bin/bash
set -u
B=/path/to/openwrt
LOG=/tmp/build.log
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
export FORCE_UNSAFE_CONFIGURE=1
unset CDPATH
cd "$B" || exit 1

# 娓呮帀鍙兘娈嬬暀鐨勯攣
rm -f build_dir/hostpkg/apk-*/openwrt-build/.ninja_lock
rm -f staging_dir/host/.prereq-build

setsid nohup make -j"$(nproc)" V=s >> "$LOG" 2>&1 < /dev/null &
echo "started pid $!"
```

鐪嬭繘搴︼細

```bash
strings /tmp/build.log | grep -v '^[[:space:]]*$' | tail -20
```

---

## 6. 鍒ゆ柇鏋勫缓銆岀湡鐨勫け璐ヤ簡銆嶈繕鏄€屽彧鏄仠浜嗐€?
```
鏃ュ織鏈?Error 涓旀病鏈?(ignored)  鈫?鐪熷け璐?鏃ュ織鏈?Error 浣嗘爣 (ignored)    鈫?OpenWrt 鑷繁鍚炴帀鐨勶紝涓嶆槸澶辫触
鏃ュ織鏃犻敊璇絾涓嶅啀澧為暱           鈫?杩涚▼琚潃浜?/ 鍗″湪閿佷笂 / 鍗″湪缃戠粶
杩涚▼瀛樺湪浣?cwd 涓嶆槸鎴戠殑鏍?     鈫?鍒汉鐨勬瀯寤猴紝涓庢垜鏃犲叧
```

杩欎笁涓俊鍙风粍鍚堣捣鏉ヨ兘瑕嗙洊缁濆ぇ澶氭暟璇垽銆?
---

## 7. 症状五：中断留下的「残缺中间状态」比错误本身更难查

### 现象

WSL 实例被重启后继续构建，日志里出现三个彼此无关的错误：

```
① ncurses:
   make[4]: *** No rule to make target 'libs'.  Stop.
   ERROR: package/libs/ncurses [host] failed to build.

② apk:
   ninja: Entering directory '.../apk-3.0.5/openwrt-build'
   ninja: error: unknown target 'install'
   ERROR: package/system/apk [host] failed to build.

③ golang-bootstrap:
   install: cannot stat '.../go-1.24.13/bin/*': No such file or directory
   ERROR: package/feeds/packages/golang-bootstrap [host] failed to build.
```

三个包、三种错误，看起来毫无关联。

### 共同点：都是「半个项目」

| 包 | 错误 | 实际状态 |
| --- | --- | --- |
| ncurses | `make libs` 不存在 | `configure` 被打断，生成的 Makefile 不完整 |
| apk | ninja 没有 `install` 规则 | `openwrt-build/build.ninja` 是残缺的自举产物 |
| golang | `bin/*` 不存在 | 只有源码树，编译产物丢失 |

**中断不会回滚。** OpenWrt 的 `.built`、`.configured` 标记只在**成功**时写入，
所以半成品目录既没有标记（会重跑），又带着坏掉的中间文件（重跑也会失败）。

### 为什么加重试没用

重跑时 `make` 看到 `.prepared` 存在就跳过解压，直接进 `compile`；
但 `compile` 依赖的 Makefile / build.ninja / bin 都是坏的，于是同样失败。

**这类错误稳定复现，看起来像「代码 bug」，实际是缓存污染。**

### 修法：删掉构建目录，不用打补丁

```bash
rm -rf build_dir/hostpkg/ncurses-*/
rm -rf build_dir/hostpkg/apk-*/
rm -rf build_dir/hostpkg/go-*/
rm -f  staging_dir/host/stamp/.apk_installed
rm -f  staging_dir/hostpkg/stamp/.golang-bootstrap_installed
rm -f  staging_dir/hostpkg/stamp/.ncurses*
rm -f  build_dir/*/*/.ninja_lock
```

**不要删 `dl/`** —— 源码压缩包是完整的，删了要重新下载：

```
dl/ncurses-6.6.20260801.tar.zst    2,247,939 B
dl/apk-3.0.5.tar.zst                 315,251 B
dl/go1.24.13.src.tar.gz           30,802,752 B
```

### 清理后的效果

三个包立即重新编译，Go 正常进入自举：

```
pid 87106  /package/libs/ncurses
pid 87122  /feeds/packages/lang/golang/golang-bootstrap
日志：cmd/go/internal/lockedfile, go/build/constraint, internal/goversion ...
```

### 判断「是代码问题还是缓存污染」

```
同一个错误在「删掉 build_dir/<pkg> 后重跑」时消失  → 缓存污染
仍然出现                                        → 真实代码/配置问题
```

先删一次再判断，比读一百行日志快。

---

## 8. 长编译最怕中断：Rust 的例子

Rust 工具链是这次构建里最贵的一步：

```
time: package/feeds/packages/rust/host-compile#8231.89#558.53#1516.58
touched staging_dir/hostpkg/stamp/.rust_installed
install: installing component 'rust-std-aarch64-unknown-linux-musl'
install: installing component 'llvm-tools-preview'
```

**2.3 小时、1667 个 rlib。**

这种长编译一旦被打断，前面的 rlib 可能全部作废。所以：

> **内存配额、管道脱离、PATH 这些环境修复必须在开始长编译之前做完，
> 而不是等它崩了再修 —— 因为崩溃的代价是几小时的重复工作。**

这次的顺序恰好是反的：先崩了一次（WSL 重启，丢掉部分 rust 进度），
才发现 `memory=20GB` 超出主机容量。修完才让 rust 跑完。
