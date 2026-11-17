# 两处 TF-A 补丁：让未签名 FIP 能启动
#
# 用法：
#   sh patch-tfa-unsigned.sh <tf-a 源码树根目录>
#
# 补丁内容见 docs/hg5580a-uboot-disable-auth.md。
# 幂等：重复执行不会叠加。
set -u

TFA="${1:-}"
if [ -z "$TFA" ] || [ ! -d "$TFA" ]; then
	echo "usage: $0 <tf-a-tree>" >&2
	exit 2
fi
TFA=$(readlink -f -- "$TFA")

echo "tf-a tree: $TFA"

# ---------------------------------------------------------------------------
# 补丁一：bl2_main.c —— 在 auth_mod_init() 之后关闭验签
# ---------------------------------------------------------------------------
BL2MAIN="$TFA/bl2/bl2_main.c"
echo
echo "=== 1. $BL2MAIN ==="

if grep -q 'TCSUPPORT_DISABLE_AUTH' "$BL2MAIN"; then
	echo "  already patched"
else
	python3 - "$BL2MAIN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """#if !defined(IMAGE_BL21) && !defined(IMAGE_BL22)
	crypto_mod_init();

	/* Initialize authentication module */
	auth_mod_init();
#endif
"""
new = """#if !defined(IMAGE_BL21) && !defined(IMAGE_BL22)
	crypto_mod_init();

	/* Initialize authentication module */
	auth_mod_init();

#if defined(TCSUPPORT_DISABLE_AUTH)
	/*
	 * The FIP on this platform is built without certificates, so the chain
	 * of trust cannot be verified.  dyn_disable_auth() makes
	 * load_auth_image_internal() fall through to load_image() and skip
	 * verification entirely.
	 *
	 * Upstream only reaches this through the fconf TBBR getter, which the
	 * ecnt platform never populates, so the flag would otherwise stay 0
	 * and BL2 would abort with "Authentication failed".
	 */
	dyn_disable_auth();
#endif
#endif
"""
if old not in s:
    print("  ERROR: anchor not found in bl2_main.c", file=sys.stderr)
    sys.exit(1)
open(p, 'w').write(s.replace(old, new, 1))
print("  patched")
PY
	[ $? -eq 0 ] || exit 1
fi

# ---------------------------------------------------------------------------
# 补丁二：Makefile —— 把 TCSUPPORT_DISABLE_AUTH 注册成 -D
#
# TCSUPPORT_* 变量不会自动变成 -D；不注册的话补丁一的 #if 恒假，代码被删掉。
# ---------------------------------------------------------------------------
MK="$TFA/Makefile"
echo
echo "=== 2. $MK ==="

if grep -q 'TCSUPPORT_DISABLE_AUTH' "$MK"; then
	echo "  already patched"
else
	python3 - "$MK" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = """ifneq ($(strip $(TCSUPPORT_CPU_AN7583)),)
$(eval $(call add_define,TCSUPPORT_CPU_AN7583))
$(eval $(call add_define,TCSUPPORT_CPU_EN7523))
$(eval $(call add_define,TCSUPPORT_CPU_EN7512))
$(eval $(call add_define,TCSUPPORT_CPU_ARMV8))
$(eval $(call add_define,TCSUPPORT_UBOOT_64BIT))
endif
"""
if anchor not in s:
    print("  ERROR: anchor not found in Makefile", file=sys.stderr)
    sys.exit(1)
addition = anchor + """
# Build a BL2 that skips chain-of-trust verification, so an FIP without
# certificates can be booted.  See bl2/bl2_main.c for the call site.
ifneq ($(strip $(TCSUPPORT_DISABLE_AUTH)),)
$(eval $(call add_define,TCSUPPORT_DISABLE_AUTH))
endif
"""
open(p, 'w').write(s.replace(anchor, addition, 1))
print("  patched")
PY
	[ $? -eq 0 ] || exit 1
fi

echo
echo "=== 3. 验证 ==="
grep -n 'dyn_disable_auth' "$BL2MAIN" | sed 's/^/  bl2_main: /'
grep -n 'TCSUPPORT_DISABLE_AUTH' "$MK" | sed 's/^/  Makefile: /'
echo
echo "编译时记得传 TCSUPPORT_DISABLE_AUTH=1"
