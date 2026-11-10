# WSL 涓婄紪璇?OpenWrt 鐨勮矾寰勯櫡闃?
> 涓や釜浼氳鏋勫缓鐪嬭捣鏉ャ€屽畬鍏ㄥ潖鎺夈€嶇殑鐜闂锛屼互鍙婂畠浠殑鐪熷疄鍘熷洜

---

## 1. 鐥囩姸涓€锛歱rereq 妫€鏌ヨ鎵€鏈夊伐鍏烽兘缂哄け

```
Checking 'gcc'... ok.
Checking 'g++'... failed.
Checking 'python3'... ok.
Checking 'file'... failed.
Checking 'egrep'... failed.
Checking 'getopt'... failed.
Checking 'realpath'... failed.
Checking 'stat'... failed.
Checking 'gzip'... failed.
Checking 'unzip'... failed.
Checking 'bzip2'... failed.
Checking 'wget'... failed.
Checking 'install'... failed.
Checking 'perl'... failed.

Build dependency: Please install GNU 'tar'
Build dependency: Please install GNU 'find'
Build dependency: Please install GNU 'bash'
Build dependency: Please install 'xargs' that supports '-r/--no-run-if-empty'
Build dependency: Please install GNU 'patch'
...

Prerequisite check failed. Use FORCE=1 to override.
```

**鐭涚浘鐐?*锛歚gcc`銆乣python3`銆乣which` 鑳芥壘鍒帮紝`g++`銆乣tar`銆乣find`銆乣bash`銆?`grep`銆乣gzip` 鎵句笉鍒?鈥斺€?浣嗗畠浠兘鍦?`/usr/bin`锛屼氦浜掑紡 shell 閲屽叏閮借兘瑙ｆ瀽銆?
### 鐪熷疄鍘熷洜锛氬甫绌烘牸鐨?Windows 璺緞

WSL 榛樿鎶?Windows 鐨?PATH 杩藉姞杩?Linux 鐨?PATH锛?
```
$ echo $PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/usr/lib/wsl/lib:/mnt/c/Program Files/Microsoft MPI/Bin/:/mnt/c/Windows/system32:...
                                                                                            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ 鏈夌┖鏍?```

`include/toplevel.mk` 杩欐牱澶勭悊瀹冿細

```makefile
path:=$(subst :,$(space),$(PATH))
export ORIG_PATH:=$(if $(ORIG_PATH),$(ORIG_PATH),$(PATH))
export PATH:=$(path)
```

绗竴姝ユ妸 PATH 鎸?`:` 鎹㈡垚绌烘牸锛屽彉鎴?make 鐨?*璇嶅垪琛?*銆備絾 make 鐨勮瘝鍒楄〃鏈韩鏄?**鎸夌┖鐧藉垎闅?*鐨勶紝鎵€浠ワ細

```
/mnt/c/Program Files/Microsoft MPI/Bin/
```

琚媶鎴愪袱涓瘝锛?
```
/mnt/c/Program
Files/Microsoft
MPI/Bin/
```

涔嬪悗閲嶆柊 join 鎴?PATH 鏃讹紝鏁翠釜璺緞涓插凡缁忛敊浣嶅苟琚埅鏂紝`/usr/bin` 绛夌郴缁熺洰褰?涓嶅啀浣嶄簬姝ｇ‘浣嶇疆鎴栬鍚炴帀銆?
**涓轰粈涔?`gcc` 鍜?`python3` 鍙嶈€岃兘鎵惧埌**锛氬畠浠彲鑳介€氳繃 `/usr/local/bin`锛堝湪閿欒
鍙戠敓鍓嶇殑浣嶇疆锛夋垨 ccache 绗﹀彿閾炬帴鍛戒腑锛岀函灞炶繍姘斻€?
### 淇硶

鏋勫缓鏃跺彧浼?POSIX 璺緞锛?
```bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
make -j$(nproc)
```

OpenWrt 鏋勫缓涓嶉渶瑕?Windows 渚х殑浠讳綍鍙墽琛屾枃浠躲€?*鎺ㄨ崘鍋氭硶**鏄湪 `/etc/wsl.conf`
閲屾案涔呭叧鎺変簰鎿嶄綔锛?
```ini
[interop]
appendWindowsPath = false
```

鐒跺悗 `wsl --shutdown` 閲嶅紑銆?
---

## 2. 鐥囩姸浜岋細`staging_dir` 鍗婃畫瀵艰嚧 prereq 鍙嶅澶辫触

娓呮帀 `staging_dir` 涔嬪悗锛宍make` 浼氬湪绗竴姝ュ氨澶辫触锛岃€屼笖**鍒犳帀 `.prereq-build`
鏍囪涔熸病鏈夌敤**锛屽洜涓哄け璐ュ師鍥犱笉鏄紦瀛橈細

```
staging_dir/host/          鍙湁 bin/锛岃€屼笖鏄┖鐨?build_dir/                 瀹屽叏涓虹┖
```

`Makefile:20` 浼氭棤鏉′欢鎶?`<TOPDIR>/staging_dir/host/bin` 鍔犲埌 PATH 鏈€鍓嶉潰锛?
```makefile
export PATH:=$(if $(STAGING_DIR),$(abspath $(STAGING_DIR)/../host/bin),$(TOPDIR)/staging_dir/host/bin):$(PATH)
```

鐩綍瀛樺湪浣嗘槸绌虹殑锛屼笉褰卞搷瑙ｆ瀽锛堟壘涓嶅埌灏辩户缁線鍚庢壘锛夛紝鎵€浠ヨ繖涓嶆槸鏍瑰洜 鈥斺€?**鏍瑰洜濮嬬粓鏄笂闈㈢ 1 鏉＄殑 PATH 鎷嗗垎闂**銆備絾鍗婃畫鐨?`staging_dir` 浼氳
澧為噺缂栬瘧姘歌繙鏃犳硶鎭㈠锛屽繀椤昏繛甯︽竻鎺夛細

```bash
rm -rf staging_dir build_dir tmp
rm -f .config.old
# .config 瑕佷繚鐣欙紝瀹冭褰曚簡璁惧涓庡寘閫夋嫨
```

---

## 3. 鐥囩姸涓夛細`new_backup` 缁撳熬鐨?vhdx 寮傚父 / `Wsl/Service/CreateInstance/E_FAIL`

鍏堟煡纾佺洏锛?*涓嶈鍏堟€€鐤?WSL 鏈綋**锛?
```powershell
Get-Volume -DriveLetter H
```

濡傛灉 `SizeRemaining` 鎺ヨ繎 0锛學SL 璧蜂笉鏉ユ槸鍥犱负鍐欎笉浜?`ext4.vhdx`銆傛竻鐞嗙┖闂村嵆鍙€?
濡傛灉绌洪棿姝ｅ父浣嗕粛鐒?`E_FAIL`锛?
```powershell
wsl --shutdown
Get-Service WSLService,LxssManager,vmcompute,HvHost
Start-Service WSLService
```

`LxssManager` 鏄?Stopped 灞炴甯革紙鎸夐渶鍚姩锛夈€俙WSLService` 蹇呴』鏄?Running銆?
---

## 4. 宸ュ叿閾句涪澶卞悗鐨勮ˉ鏁?
OpenWrt 鐨?`staging_dir/toolchain-*` 鍦ㄦ爲琚竻鐞嗗悗浼氭秷澶便€備袱鏉¤矾锛?
**A. 閲嶈窇 make**锛堟帹鑽愶級鈥斺€斿伐鍏烽摼浼氱敱 `toolchain/` 鐩爣鑷姩閲嶅缓锛?鈥? 灏忔椂銆?
**B. 鐢ㄥ彂琛岀増浜ゅ弶缂栬瘧鍣?*锛堝彧鎯崇紪 U-Boot 鏃跺鐢級锛?
```bash
apt-get install -y gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
export CROSS_COMPILE=aarch64-linux-gnu-
```

娉ㄦ剰锛?*鎹簡 `CROSS_COMPILE` 涔嬪悗涓嶈兘澶嶇敤鏃х殑 `O=` 鏋勫缓鐩綍**锛宬config 浼氭妸
缂栬瘧鍣ㄨ矾寰勫拰鐗堟湰鍐欒繘 `include/config/auto.conf`锛屾贩鐢ㄤ細鎶ワ細

```
Kconfig:91: syntax error
Kconfig:90: invalid option
```

鐢ㄥ叏鏂扮殑 `O=` 鐩綍鍗冲彲銆?
---

## 5. 妫€鏌ユ竻鍗?
鍦?WSL 涓婂紑濮?OpenWrt 鏋勫缓涔嬪墠锛?
```bash
# 1. PATH 閲屼笉鑳芥湁绌烘牸
echo "$PATH" | tr ':' '\n' | grep -c ' '      # 蹇呴』鏄?0

# 2. 蹇呴渶宸ュ叿鍏ㄩ儴鍙В鏋?for c in g++ gcc git rsync tar find bash grep gzip unzip bzip2 \
         perl file install realpath stat getopt egrep seq patch \
         diff xargs which wget make; do
  command -v "$c" >/dev/null || echo "MISSING: $c"
done

# 3. 纾佺洏绌洪棿
df -h /        # 寤鸿 > 40 GB

# 4. 澶у皬鍐欐晱鎰熸枃浠剁郴缁?touch /tmp/t.fs && [ ! -f /tmp/t.FS ] && echo 'case-sensitive OK'

# 5. umask
umask          # 闇€瑕?0022
```
---

## 6. 症状四：长时间构建中 WSL 整个实例重启

### 现象

`rustc` 编译到一半，全部进程消失：

```
pid 2594 gone
make / cargo / rustc / cc1plus   全部 0 个
日志停在 "Compiling rustc_pattern_analysis ..."
内存检查：17 GiB 空闲（不是 OOM）
```

关键证据：

```sh
$ uptime
 14:02:29 up 1 min, 0 user, load average: 0.54

$ ps -p 1 -o pid,comm,etime
 PID COMMAND        ELAPSED
   1 init(Ubuntu)     01:17      ← PID 1 只运行了 77 秒
```

**WSL 实例被重启过。** 不是编译错误，是整个虚拟机被回收。

### 原因：内存配额超出主机容量

```ini
# ~/.wslconfig
[wsl2]
memory=20GB       ← 给 WSL 20 GB
processors=12
swap=8GB
```

```
主机总内存:  23.9 GB
Windows 自身: ~10 GB
```

给 WSL 20 GB，等于把主机内存全部让出去还不够。当 rustc 达到内存峰值，
Windows 触发 WSL VM 回收，直接重启实例 —— 编译成果全部丢失。

### 修法

```ini
[wsl2]
memory=12GB      ; 给宿主留 12 GB
processors=12
swap=16GB        ; swap 加大，用磁盘吸收峰值
guiApplications=false
```

然后 `wsl --shutdown` 使其生效。

验证：

```sh
$ free -h
               total        used        free
Mem:            11Gi       342Mi        11Gi
```

### 教训

用 WSL 做大型编译（内核、rustc、gcc）时，**`memory=` 不要超过主机内存的 50%**。
超出后不会有任何错误提示，只会表现为「构建莫名其妙消失」。

诊断的方法就是看 `uptime` —— 如果构建跑了几十分钟而 `uptime` 只有几分钟，
说明实例重启过。
