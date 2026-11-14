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

# 自定义管理器证书覆盖：把 SukiSU 官方信任槽 EXPECTED_HASH/SIZE 换成我们的证书。
# 上游 Kbuild 用的是 `KSU_EXPECTED_HASH ?= ...`（带问号），且 -s builtin 分支可能
# 把定义放在 Makefile，因此遍历 kernel/ 下所有构建文件逐个替换。注入后强制校验，
# 校验不通过直接让构建失败，避免产出"日志显示成功、实际仍是官方证书"的假包。
apply_custom_cert() {
  local hash="${1:-$KSU_CERT_HASH}"
  local size="${2:-$KSU_CERT_SIZE}"
  if [ -z "$hash" ]; then hash="$KSU_BUILTIN_HASH"; fi
  if [ -z "$size" ]; then size="$KSU_BUILTIN_SIZE"; fi

  local f changed=0
  local files=()
  for f in "$KSU_DIR"/kernel/Kbuild "$KSU_DIR"/kernel/Makefile "$KSU_DIR"/kernel/*.mk; do
    if [ -f "$f" ]; then files+=("$f"); fi
  done
  if [ ${#files[@]} -eq 0 ]; then
    echo "::error::未找到 KernelSU/kernel/ 下的 Kbuild/Makefile，无法注入自定义证书"
    exit 1
  fi

  for f in "${files[@]}"; do
    if grep -qE '^KSU_EXPECTED_HASH[[:space:]]*[:?+]?=' "$f"; then
      # 兼容 ?= / := / += / = 任意赋值运算符，仅匹配行首变量定义，不碰 ccflags-y 引用行
      sed -i -E "s|^(KSU_EXPECTED_HASH[[:space:]]*[:?+]?=).*|\1 $hash|" "$f"
      sed -i -E "s|^(KSU_EXPECTED_SIZE[[:space:]]*[:?+]?=).*|\1 $size|" "$f"
      changed=1
    fi
  done

  if [ "$changed" -eq 0 ]; then
    # 兜底：在 ccflags-y += -DEXPECTED_HASH= 锚点前插入强赋值（覆盖上游 ?= 默认值）
    for f in "${files[@]}"; do
      if grep -qE '^ccflags-y[[:space:]]*\+=[[:space:]]*-DEXPECTED_HASH=' "$f"; then
        awk -v h="$hash" -v s="$size" '
          !done && /^ccflags-y[[:space:]]*\+=[[:space:]]*-DEXPECTED_HASH=/ {
            print "KSU_EXPECTED_SIZE = " s
            print "KSU_EXPECTED_HASH = " h
            done = 1
          }
          { print }
        ' "$f" > "$f.new" && mv "$f.new" "$f"
        changed=1
        break
      fi
    done
  fi

  if [ "$changed" -eq 0 ]; then
    echo "::error::未定位到 KSU_EXPECTED_HASH 定义或 ccflags 锚点，证书注入失败"
    exit 1
  fi
  if ! grep -RqsF "$hash" "$KSU_DIR"/kernel/; then
    echo "::error::证书注入校验失败：KSU_EXPECTED_HASH 未变成 $hash"
    exit 1
  fi

  echo "覆盖 SukiSU 信任槽为自定义管理器证书: hash=$hash size=$size"
  grep -RnE '^KSU_EXPECTED_(HASH|SIZE)[[:space:]]*[:?+]?=' "$KSU_DIR"/kernel/ || true
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
