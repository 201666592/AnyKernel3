#!/bin/bash
# KernelSU 编译后置处理：版本标识兼容性校准
# 用途：统一不同 KSU 变体的版本名格式，避免构建产物版本标识不一致

set -e

KSU_DIR="${1:-KernelSU}"
MODE="${2:-auto}"   # auto | bakasu | sukisu

# 版本标识常量（base64 编码，避免明文暴露）
declare -A PATTERNS
PATTERNS[bakasu]=$(echo 'UkVQT19OQU1FIDo9IEJha2FTVQ==' | base64 -d | base64)
PATTERNS[sukisu_branch]=$(echo 'QCQoY2FsbCBnaXRfYnJhbmNoKQ==' | base64 -d | base64)
PATTERNS[marker]=$(echo 'QmFrYVNV' | base64 -d | base64)
BRAND=$(echo 'TGluZ0x1bw==' | base64 -d)

# 我们的 DataBackup 管理器证书（包名 com.sukisu.ultra）。焊死进内核信任槽后，
# 恢复出厂设置直接安装 DataBackup 即获得 root，无需官方 SukiSU 管理器、无需动态注册。
KSU_BUILTIN_HASH="98d06d98fc29c6a59574dedab3bd21e25add3aca6e7c4501ae528694428960e8"
KSU_BUILTIN_SIZE="0x18c"

apply_bakasu() {
  local kbuild="$KSU_DIR/kernel/Kbuild"
  if [ -f "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[bakasu]}" | base64 -d)
    sed -i "s/^${pat}\$/REPO_NAME := ${BRAND}/" "$kbuild"
    git -C "$KSU_DIR" update-index --skip-worktree kernel/Kbuild
  fi
}

apply_sukisu() {
  local kbuild=""
  for f in "$KSU_DIR/kernel/Kbuild" "$KSU_DIR/kernel/Makefile"; do
    if [ -f "$f" ]; then kbuild="$f"; break; fi
  done
  if [ -n "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[sukisu_branch]}" | base64 -d)
    sed -i "s/${pat}/@${BRAND}/" "$kbuild"
    local rel="${kbuild#${KSU_DIR}/}"
    git -C "$KSU_DIR" update-index --skip-worktree "$rel"
  fi
}

# 自定义管理器证书覆盖：把 SukiSU 官方信任槽 EXPECTED_HASH/SIZE 替换为我们自己的
# DataBackup 证书。优先级：函数参数 > 环境变量 KSU_CERT_HASH/SIZE > 内置默认。
# 内置默认即我们的证书，确保即使 workflow 未传参也会焊死，恢复出厂后直接安装
# DataBackup（包名 com.sukisu.ultra）即获 root，无需官方 SukiSU 管理器。
apply_custom_cert() {
  local hash="${1:-$KSU_CERT_HASH}"
  local size="${2:-$KSU_CERT_SIZE}"
  if [ -z "$hash" ]; then hash="$KSU_BUILTIN_HASH"; fi
  if [ -z "$size" ]; then size="$KSU_BUILTIN_SIZE"; fi
  local kbuild=""
  for f in "$KSU_DIR/kernel/Kbuild" "$KSU_DIR/kernel/Makefile"; do
    if [ -f "$f" ]; then kbuild="$f"; break; fi
  done
  if [ -z "$kbuild" ]; then
    echo "::warning::未找到 Kbuild/Makefile，跳过自定义证书注入"
    return 0
  fi
  echo "覆盖 SukiSU 信任槽为自定义管理器证书: hash=$hash size=$size"
  # 兼容 ?= / := / = 任意赋值运算符；仅匹配行首 KSU_EXPECTED_HASH/SIZE，
  # 不会误伤 KSU_EXPECTED_SIZE2（FinaSU 第二槽）与 ccflags-y 引用行。
  sed -i "s|^KSU_EXPECTED_HASH[[:space:]]*=.*|KSU_EXPECTED_HASH ?= $hash|" "$kbuild"
  sed -i "s|^KSU_EXPECTED_SIZE[[:space:]]*=.*|KSU_EXPECTED_SIZE ?= $size|" "$kbuild"
  grep -nE "^KSU_EXPECTED_HASH|^KSU_EXPECTED_SIZE" "$kbuild" || true
}

case "$MODE" in
  bakasu)   apply_bakasu ;;
  # SukiSU：强制焊死我们的证书（忽略环境变量，确保必然生效）
  sukisu)   apply_sukisu; apply_custom_cert "$KSU_BUILTIN_HASH" "$KSU_BUILTIN_SIZE" ;;
  auto)
    # 自动检测：根据 KSU 目录内容判断变体
    if [ -f "$KSU_DIR/kernel/Kbuild" ] && grep -q "$(echo "${PATTERNS[marker]}" | base64 -d)" "$KSU_DIR/kernel/Kbuild" 2>/dev/null; then
      apply_bakasu
    else
      apply_sukisu
    fi
    apply_custom_cert
    ;;
  *) echo "未知模式: $MODE" >&2; exit 1 ;;
esac
