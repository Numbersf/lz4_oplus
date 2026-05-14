#!/bin/bash
# ================================================================
# apply_lz4_oplus.sh
# 适用于OKI（OPlus 内核）LZ4 升级到上游 1.10.0 + ARMv8 NEON 加速脚本
# 用法：在 kernel_platform/common/ 目录下执行
#   bash /path/to/apply_lz4_oplus.sh
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHED=0
SKIPPED=0
FAILED=0

info()  { echo "[INFO] $*"; }
pass()    { echo "[PASS] $*"; ((PATCHED++)) || true; }
skip()  { echo "[SKIP] $*"; ((SKIPPED++)) || true; }
fail()  { echo "::error:: [FAIL] $*"; ((FAILED++)) || true; }

already_has() { grep -q "$1" "$2" 2>/dev/null; }

echo "=== apply_lz4_oplus: 开始 LZ4 升级 ==="

# 替换 lib/lz4/ 目录：删除旧内核分割版本，写入上游统一版本
echo ""
echo "[1/5] 替换 lib/lz4/"

# 删除旧文件
for OLD in lib/lz4/lz4_compress.c lib/lz4/lz4_decompress.c \
           lib/lz4/lz4defs.h lib/lz4/lz4hc_compress.c; do
  if [ -f "$OLD" ]; then
    rm -f "$OLD"
    info "删除旧文件: $OLD"
  fi
done

# 迁移 f2fs/lz4armv8 到 lib/lz4/lz4armv8
if [ -d "fs/f2fs/lz4armv8" ]; then
  rm -rf "fs/f2fs/lz4armv8"
  info "删除旧目录: fs/f2fs/lz4armv8/"
fi

# 写入新文件
mkdir -p lib/lz4/lz4armv8

for F in lib/lz4/lz4.c \
         lib/lz4/lz4.h \
         lib/lz4/lz4hc.c \
         lib/lz4/lz4hc.h \
         lib/lz4/Makefile \
         lib/lz4/lz4armv8/lz4accel.c \
         lib/lz4/lz4armv8/lz4accel.h \
         lib/lz4/lz4armv8/lz4armv8.S; do
  cp -f "${SCRIPT_DIR}/${F}" "${F}"
  info "写入: $F"
done
pass "lib/lz4/ 替换完成"

# 替换 include/linux/lz4.h（改为薄包装头，指向 lib/lz4/）
echo ""
echo "[2/5] 替换 include/linux/lz4.h"

if already_has 'lib/lz4/lz4.h' include/linux/lz4.h; then
  skip "include/linux/lz4.h 已是新格式"
else
  cp -f "${SCRIPT_DIR}/include/linux/lz4.h" include/linux/lz4.h
  pass "include/linux/lz4.h 替换完成"
fi

# 修改 crypto/lz4.c 和 crypto/lz4hc.c：添加 ARM64 NEON 分支
echo ""
echo "[3/5] 修改 crypto/lz4.c / lz4hc.c"

for FILE in crypto/lz4.c crypto/lz4hc.c; do
  if [ ! -f "$FILE" ]; then skip "$FILE 不存在"; continue; fi
  if already_has 'LZ4_arm64_decompress_safe' "$FILE"; then skip "$FILE 已修补"; continue; fi

  perl -i -pe '
    if (/\tint out_len = LZ4_decompress_safe\(src, dst, slen, \*dlen\);/) {
      $_ = "\tint out_len;\n\n"
         . "#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n"
         . "\tout_len = LZ4_arm64_decompress_safe(src, dst, slen, *dlen, false);\n"
         . "#else\n"
         . "\tout_len = LZ4_decompress_safe(src, dst, slen, *dlen);\n"
         . "#endif\n";
    }
  ' "$FILE"

  already_has 'LZ4_arm64_decompress_safe' "$FILE" \
    && pass "$FILE 添加 NEON 分支成功" \
    || fail "$FILE 添加 NEON 分支失败"
done

# 修改 fs/f2fs/Makefile 和 fs/f2fs/compress.c
# Makefile：删除 lz4armv8 编译行
# compress.c：删除 #include "lz4armv8/lz4accel.h"
echo ""
echo "[4/5] 修改 fs/f2fs/"

# 4a. f2fs/Makefile — 删除整个 ifeq(CONFIG_F2FS_FS_COMPRESSION_FIXED_OUTPUT) 块
F2FS_MK="fs/f2fs/Makefile"
if [ -f "$F2FS_MK" ]; then
  if grep -q 'lz4armv8' "$F2FS_MK"; then
    # 兼容两种格式
    perl -i -0777 -pe '
      # 删除 ifeq...endif 块（含 lz4armv8）
      s/\nifeq \(\$\(CONFIG_F2FS_FS_COMPRESSION_FIXED_OUTPUT\),y\)\nf2fs-\$\(CONFIG_ARM64\) \+= \$\(addprefix lz4armv8\/,.*?\)\nendif//gs;
      # 也删除单行形式（如果有）
      s/\nf2fs-\$\(CONFIG_ARM64\) \+= \$\(addprefix lz4armv8\/,.*\)//g;
    ' "$F2FS_MK"
    grep -q 'lz4armv8' "$F2FS_MK" \
      && fail "$F2FS_MK 删除 lz4armv8 失败" \
      || pass "$F2FS_MK 删除 lz4armv8 成功"
  else
    skip "$F2FS_MK 无 lz4armv8 行（已删除或不存在）"
  fi
fi

# 4b. f2fs/compress.c — 删除 #include "lz4armv8/lz4accel.h"
COMPRESS_C="fs/f2fs/compress.c"
if [ -f "$COMPRESS_C" ]; then
  if grep -q 'lz4armv8/lz4accel.h' "$COMPRESS_C"; then
    sed -i '/#include "lz4armv8\/lz4accel\.h"/d' "$COMPRESS_C"
    grep -q 'lz4armv8/lz4accel.h' "$COMPRESS_C" \
      && fail "$COMPRESS_C 删除 include 失败" \
      || pass "$COMPRESS_C 删除 lz4armv8 include 成功"
  else
    skip "$COMPRESS_C 无 lz4armv8/lz4accel.h（已删除或不存在）"
  fi
fi

# 修改 fs/incfs/data_mgmt.c
# LZ4 解压调用添加 ARM64 NEON 分支
# schedule_delayed_work → queue_delayed_work(system_power_efficient_wq, ...)
echo ""
echo "[5/5] 修改 fs/incfs/data_mgmt.c"

INCFS="fs/incfs/data_mgmt.c"
if [ ! -f "$INCFS" ]; then
  skip "$INCFS 不存在（此内核版本无 incfs）"
else
  # 5a. LZ4 NEON 分支
  if already_has 'LZ4_arm64_decompress_safe' "$INCFS"; then
    skip "$INCFS LZ4 NEON 已修补"
  else
    perl -i -0777 -pe '
      s{(\t+)result = LZ4_decompress_safe\(src\.data, dst\.data, src\.len,\s*\n\s*dst\.len\);}
       {#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}result = LZ4_arm64_decompress_safe(src.data, dst.data, src.len, dst.len, false);\n#else\n${1}result = LZ4_decompress_safe(src.data, dst.data, src.len, dst.len);\n#endif}
    ' "$INCFS"
    already_has 'LZ4_arm64_decompress_safe' "$INCFS" \
      && pass "$INCFS LZ4 NEON 分支添加成功" \
      || fail "$INCFS LZ4 NEON 分支添加失败"
  fi

  # 5b. schedule_delayed_work → queue_delayed_work(power efficient wq)
  if already_has 'system_power_efficient_wq' "$INCFS"; then
    skip "$INCFS queue_delayed_work 已修补"
  else
    sed -i 's/schedule_delayed_work(\&log->ml_wakeup_work,/queue_delayed_work(system_power_efficient_wq, \&log->ml_wakeup_work,/' "$INCFS"
    already_has 'system_power_efficient_wq' "$INCFS" \
      && pass "$INCFS queue_delayed_work 替换成功" \
      || fail "$INCFS queue_delayed_work 替换失败"
  fi
fi

echo ""
echo "=== apply_lz4_oplus 完成: ${PATCHED} 成功, ${SKIPPED} 跳过, ${FAILED} 失败 ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi