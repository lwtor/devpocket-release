#!/usr/bin/env bash
# DevPocket 一键安装器（macOS / Linux，POSIX Bash，兼容 macOS 自带 Bash 3.2）。
#
# 安全取舍：请把安装器下载到本地后再执行，而不是 `curl <url> | bash`。
#   curl -fsSL https://github.com/lwtor/devpocket-release/releases/latest/download/install.sh -o devpocket-install.sh
#   sh devpocket-install.sh
# 这样能在执行前查看/审计脚本内容；本脚本自身也只做「下载 -> 校验 -> 安装」。
#
# 行为要点：
#   - 只写入用户级目录（默认 ${XDG_DATA_HOME:-$HOME/.local/share}/devpocket），不使用 sudo，
#     不修改任何系统目录。
#   - latest 会解析成明确版本，最终下载的是版本化不可变附件 devpocket-<version>.zip。
#   - SHA-256 校验失败即 fail closed；manifest 缺字段 / 非法 JSON / 版本不一致一律拒绝安装。
#   - 解压前校验压缩包条目，拒绝 Zip Slip（路径穿越）与符号链接逃逸。
#   - 升级失败完整回滚：恢复 current 指针、删除本次新建版本、还原入口脚本。
#   - 绝不关闭 TLS 校验；绝不采集或上传宿主项目信息。
#
# 退出码：
#   0 成功  2 参数/配置错误  3 下载失败  4 SHA-256 不匹配
#   5 发布清单非法或版本不一致  6 解压失败（含路径穿越）  7 安装失败（已回滚）

set -u

# macOS Bash 3.2 没有 pipefail 之外的多数 bash4 特性，这里只用 3.2 语法。
SCRIPT_VERSION="1.0.0"

DEFAULT_BASE_URL="https://github.com/lwtor/devpocket-release/releases/latest/download"

VERSION_REQUEST=""
BASE_URL="${DEVPOCKET_RELEASE_BASE_URL:-}"
INSTALL_DIR="${DEVPOCKET_INSTALL_DIR:-}"
BIN_DIR=""
NO_BIN=0
UPDATE_PROFILE=0
CURL_BIN=""
WGET_BIN=""

usage() {
  cat <<'EOF'
用法：install.sh [选项]

选项：
  -v, --version <x.y.z>   安装指定版本（默认 latest，会解析为明确版本后下载不可变附件）
  -b, --base-url <url>    Release Base URL（默认取环境变量 DEVPOCKET_RELEASE_BASE_URL）
  -d, --dir <path>        安装目录（默认 ${XDG_DATA_HOME:-$HOME/.local/share}/devpocket）
      --bin-dir <path>    入口目录（默认 $HOME/.local/bin）
      --no-bin            不创建 ~/.local/bin/devpocket 入口
      --update-profile    可选：幂等地向 shell profile 追加 PATH（默认不修改）
  -h, --help              显示帮助

环境变量：DEVPOCKET_RELEASE_BASE_URL、DEVPOCKET_INSTALL_DIR
EOF
}

log()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }
die()  { code="$1"; shift; err "错误：$*"; exit "$code"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version)      VERSION_REQUEST="${2:-}"; shift 2 || shift ;;
    -b|--base-url)     BASE_URL="${2:-}"; shift 2 || shift ;;
    -d|--dir)          INSTALL_DIR="${2:-}"; shift 2 || shift ;;
    --bin-dir)         BIN_DIR="${2:-}"; shift 2 || shift ;;
    --no-bin)          NO_BIN=1; shift ;;
    --update-profile)  UPDATE_PROFILE=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) err "错误：未知参数 $1"; usage; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 前置检查
command -v curl  >/dev/null 2>&1 && CURL_BIN="curl"
command -v wget  >/dev/null 2>&1 && WGET_BIN="wget"
[ -n "$CURL_BIN" ] || [ -n "$WGET_BIN" ] || die 2 "需要 curl 或 wget 下载发布包。"
command -v unzip >/dev/null 2>&1 || die 2 "需要 unzip 解压发布包。"

SHA_BIN=""
if command -v shasum >/dev/null 2>&1; then SHA_BIN="shasum"
elif command -v sha256sum >/dev/null 2>&1; then SHA_BIN="sha256sum"
else die 2 "需要 shasum -a 256 或 sha256sum 计算 SHA-256。"; fi

file_sha256() {
  if [ "$SHA_BIN" = "shasum" ]; then shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  else sha256sum "$1" 2>/dev/null | cut -d' ' -f1; fi
}

# ---------------------------------------------------------------- 参数归一
if [ -z "$BASE_URL" ]; then BASE_URL="$DEFAULT_BASE_URL"; fi
case "$BASE_URL" in
  *\<*|*\>*|*"OWNER"*|*"REPO"*)
    die 2 "Release Base URL 仍为占位符（$BASE_URL）。请通过 --base-url 或环境变量 DEVPOCKET_RELEASE_BASE_URL 指定真实地址。" ;;
esac
BASE_URL="${BASE_URL%/}"

if [ -z "$INSTALL_DIR" ]; then
  XDG_DATA="${XDG_DATA_HOME:-}"
  [ -n "$XDG_DATA" ] || XDG_DATA="$HOME/.local/share"
  INSTALL_DIR="$XDG_DATA/devpocket"
fi
if [ -z "$BIN_DIR" ]; then BIN_DIR="$HOME/.local/bin"; fi

is_valid_version() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}
if [ -n "$VERSION_REQUEST" ] && ! is_valid_version "$VERSION_REQUEST"; then
  die 2 "版本号必须是 x.y.z：$VERSION_REQUEST"
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/devpocket-install.XXXXXX")" || die 2 "无法创建临时目录。"
cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# 下载（严禁 -k / --insecure；TLS 校验失败即失败）
download() {
  url="$1"; out="$2"
  if [ -n "$CURL_BIN" ]; then
    curl -fsSL --retry 2 --connect-timeout 20 -o "$out" "$url" || return 1
  else
    wget -q -T 20 -O "$out" "$url" || return 1
  fi
  [ -s "$out" ] || return 1
}

# ---------------------------------------------------------------- 1) 发布清单
MANIFEST_FILE="$TMP_ROOT/release-manifest.json"
if [ -n "$VERSION_REQUEST" ]; then
  # 显式版本读取版本化不可变清单
  MANIFEST_URL="$BASE_URL/devpocket-$VERSION_REQUEST.release-manifest.json"
else
  MANIFEST_URL="$BASE_URL/release-manifest.json"
fi
log "读取发布清单：$MANIFEST_URL"
download "$MANIFEST_URL" "$MANIFEST_FILE" \
  || die 3 "下载发布清单失败（$MANIFEST_URL）。"

[ -f "$MANIFEST_FILE" ] || die 5 "发布清单不存在。"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST_FILE" \
    || die 5 "release-manifest.json 不是合法 JSON。"
else
  head -c 1 "$MANIFEST_FILE" | grep -q '{' || die 5 "release-manifest.json 不是合法 JSON。"
fi

manifest_string() {
  key="$1"
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$MANIFEST_FILE" | head -n 1
}

M_SCHEMA="$(manifest_string schemaVersion)"
M_TOOL="$(manifest_string toolVersion)"
M_ARCHIVE="$(manifest_string archive)"
M_SHA="$(manifest_string sha256)"
M_MINPS="$(manifest_string minimumPowerShell)"
M_CREATED="$(manifest_string createdAt)"

for pair in "schemaVersion:$M_SCHEMA" "toolVersion:$M_TOOL" "archive:$M_ARCHIVE" \
            "sha256:$M_SHA" "minimumPowerShell:$M_MINPS" "createdAt:$M_CREATED"; do
  key="${pair%%:*}"; val="${pair#*:}"
  [ -n "$val" ] || die 5 "release-manifest.json 缺少字段或字段为空：$key"
done
grep -q '"supportedPlatforms"' "$MANIFEST_FILE" \
  || die 5 "release-manifest.json 缺少字段：supportedPlatforms"

[ "$M_SCHEMA" = "1.0" ] || die 5 "不支持的 manifest schemaVersion：$M_SCHEMA（期望 1.0）。"
is_valid_version "$M_TOOL" || die 5 "manifest.toolVersion 非法：$M_TOOL"

if [ -n "$VERSION_REQUEST" ]; then
  [ "$M_TOOL" = "$VERSION_REQUEST" ] \
    || die 5 "请求版本 $VERSION_REQUEST 与发布清单版本 $M_TOOL 不一致，拒绝安装。"
  VERSION="$VERSION_REQUEST"
else
  VERSION="$M_TOOL"
fi
log "已解析安装版本：$VERSION"

EXPECTED_ARCHIVE="devpocket-$VERSION.zip"
[ "$M_ARCHIVE" = "$EXPECTED_ARCHIVE" ] \
  || die 5 "manifest.archive($M_ARCHIVE) 与版本化附件名($EXPECTED_ARCHIVE) 不一致，拒绝安装。"

# ---------------------------------------------------------------- 2) 下载 + 校验
ZIP_FILE="$TMP_ROOT/$EXPECTED_ARCHIVE"
log "下载发布包：$BASE_URL/$EXPECTED_ARCHIVE"
download "$BASE_URL/$EXPECTED_ARCHIVE" "$ZIP_FILE" \
  || die 3 "下载 $EXPECTED_ARCHIVE 失败。"

# sidecar 若存在必须与 manifest 一致（双源交叉校验，任一不符即拒绝）
if download "$BASE_URL/$EXPECTED_ARCHIVE.sha256" "$TMP_ROOT/$EXPECTED_ARCHIVE.sha256"; then
  SIDE_SHA="$(cut -d' ' -f1 "$TMP_ROOT/$EXPECTED_ARCHIVE.sha256" | head -n 1)"
  [ "$SIDE_SHA" = "$M_SHA" ] \
    || die 4 "$EXPECTED_ARCHIVE.sha256($SIDE_SHA) 与 release-manifest.json($M_SHA) 不一致，拒绝安装。"
fi

ACTUAL_SHA="$(file_sha256 "$ZIP_FILE")"
[ -n "$ACTUAL_SHA" ] || die 4 "无法计算 $EXPECTED_ARCHIVE 的 SHA-256。"
[ "$ACTUAL_SHA" = "$M_SHA" ] \
  || die 4 "SHA-256 不匹配：期望 $M_SHA，实际 $ACTUAL_SHA。已放弃安装（fail closed）。"
log "SHA-256 校验通过：$ACTUAL_SHA"

# ---------------------------------------------------------------- 3) 安全解压
EXTRACT_DIR="$TMP_ROOT/extract"
mkdir -p "$EXTRACT_DIR"

ENTRY_LIST="$TMP_ROOT/entries.txt"
unzip -Z1 "$ZIP_FILE" > "$ENTRY_LIST" 2>/dev/null \
  || die 6 "无法读取压缩包条目（unzip -Z1 失败）。"

while IFS= read -r entry || [ -n "$entry" ]; do
  [ -z "$entry" ] && continue
  case "$entry" in
    /*)            die 6 "压缩包含绝对路径条目，拒绝解压：$entry" ;;
    *\\*)          die 6 "压缩包含反斜杠条目，拒绝解压：$entry" ;;
    ..|../*|*/../*|*/..) die 6 "压缩包含路径穿越条目（Zip Slip），拒绝解压：$entry" ;;
  esac
done < "$ENTRY_LIST"

unzip -q -o "$ZIP_FILE" -d "$EXTRACT_DIR" || die 6 "解压失败。"
SYMLINKS="$(find "$EXTRACT_DIR" -type l 2>/dev/null || true)"
[ -z "$SYMLINKS" ] \
  || die 6 "压缩包解压后出现符号链接，拒绝安装（符号链接逃逸）：$SYMLINKS"

SRC="$EXTRACT_DIR/devpocket-$VERSION"
[ -d "$SRC" ] || die 6 "压缩包缺少顶层目录 devpocket-$VERSION/。"
[ -f "$SRC/VERSION" ] || die 6 "发布包缺少 VERSION 文件。"
PKG_VERSION="$(head -n 1 "$SRC/VERSION" | tr -d '[:space:]')"
[ "$PKG_VERSION" = "$VERSION" ] \
  || die 5 "包内 VERSION($PKG_VERSION) 与安装版本($VERSION) 不一致，拒绝安装。"
[ -f "$SRC/devpocket" ] || die 6 "发布包缺少 POSIX 入口 devpocket。"

# 测试注入点：解压后、切换前失败（验证留下的是旧版本且无残留）
if [ "${DEVPOCKET_TEST_FAIL_AFTER_EXTRACT:-}" = "1" ]; then
  die 7 "测试注入：解压后失败（DEVPOCKET_TEST_FAIL_AFTER_EXTRACT）。"
fi

# ---------------------------------------------------------------- 4) 安装
VERSIONS_DIR="$INSTALL_DIR/versions"
TARGET="$VERSIONS_DIR/$VERSION"
CURRENT_FILE="$INSTALL_DIR/current"
mkdir -p "$VERSIONS_DIR" || die 7 "无法创建安装目录：$VERSIONS_DIR"

PREV_VERSION=""
[ -f "$CURRENT_FILE" ] && PREV_VERSION="$(head -n 1 "$CURRENT_FILE" | tr -d '[:space:]')"

CREATED_NEW=0
if [ -d "$TARGET" ]; then
  log "版本 $VERSION 已存在，保留现有安装（幂等重装）。"
else
  TMP_TARGET="$TMP_ROOT/target-$VERSION"
  mv "$SRC" "$TMP_TARGET" || die 7 "无法暂存解包内容。"
  mkdir -p "$TARGET" || die 7 "无法创建版本目录：$TARGET"
  # 同卷移动，尽量避免跨设备复制
  if ! mv "$TMP_TARGET" "$TARGET.staging" 2>/dev/null; then
    cp -R "$TMP_TARGET" "$TARGET.staging" || die 7 "无法写入版本目录：$TARGET"
    rm -rf "$TMP_TARGET"
  fi
  rm -rf "$TARGET"
  mv "$TARGET.staging" "$TARGET" || die 7 "无法落位版本目录：$TARGET"
  CREATED_NEW=1
fi

chmod 755 "$TARGET/devpocket" 2>/dev/null || true
if [ -d "$TARGET/scripts/cli" ]; then
  find "$TARGET/scripts/cli" -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
fi
[ -f "$TARGET/installers/install.sh" ] && chmod 755 "$TARGET/installers/install.sh" 2>/dev/null || true

rollback() {
  if [ "$CREATED_NEW" = "1" ] && [ "$PREV_VERSION" != "$VERSION" ]; then
    rm -rf "$TARGET"
  fi
  if [ -n "$PREV_VERSION" ]; then
    printf '%s\n' "$PREV_VERSION" > "$CURRENT_FILE"
  else
    rm -f "$CURRENT_FILE"
  fi
  if [ -n "${SHIM_BACKUP:-}" ] && [ -f "$SHIM_BACKUP" ]; then
    mv "$SHIM_BACKUP" "$SHIM_PATH" 2>/dev/null || true
  elif [ "${SHIM_CREATED:-0}" = "1" ]; then
    rm -f "$SHIM_PATH" 2>/dev/null || true
  fi
}

switch_current() {
  printf '%s\n' "$VERSION" > "$CURRENT_FILE.tmp" || return 1
  mv "$CURRENT_FILE.tmp" "$CURRENT_FILE" || return 1
}

if ! switch_current; then err "写入 current 指针失败，开始回滚。"; rollback; die 7 "安装失败并已回滚。"; fi

# 测试注入点：切换后、入口创建前失败（验证 current 指针被还原）
if [ "${DEVPOCKET_TEST_FAIL_AFTER_SWITCH:-}" = "1" ]; then
  err "测试注入：切换后失败（DEVPOCKET_TEST_FAIL_AFTER_SWITCH）。"
  rollback
  die 7 "安装失败并已回滚。"
fi

SHIM_PATH=""
SHIM_CREATED=0
SHIM_BACKUP=""
if [ "$NO_BIN" != "1" ]; then
  SHIM_PATH="$BIN_DIR/devpocket"
  SHIM_CONTENT="#!/usr/bin/env bash
# DevPocket 启动器（由 install.sh 生成，指向 \$INSTALL_DIR/current 指向的版本）
INSTALL_DIR=\"$INSTALL_DIR\"
CURRENT_FILE=\"\$INSTALL_DIR/current\"
if [ ! -f \"\$CURRENT_FILE\" ]; then
  echo \"DevPocket 未正确安装：缺少 \$CURRENT_FILE\" >&2
  exit 1
fi
VER=\"\$(head -n 1 \"\$CURRENT_FILE\" | tr -d '[:space:]')\"
ENTRY=\"\$INSTALL_DIR/versions/\$VER/devpocket\"
if [ ! -f \"\$ENTRY\" ]; then
  echo \"DevPocket 版本 \$VER 缺失：\$ENTRY\" >&2
  exit 1
fi
exec \"\$ENTRY\" \"\$@\"
"
  mkdir -p "$BIN_DIR" || { err "无法创建入口目录：$BIN_DIR"; rollback; die 7 "安装失败并已回滚。"; }
  if [ -f "$SHIM_PATH" ]; then
    if [ "$(cat "$SHIM_PATH" 2>/dev/null)" != "$SHIM_CONTENT" ]; then
      SHIM_BACKUP="$TMP_ROOT/shim.bak"
      cp "$SHIM_PATH" "$SHIM_BACKUP" || { err "无法备份既有入口 $SHIM_PATH"; rollback; die 7 "安装失败并已回滚。"; }
      printf '%s' "$SHIM_CONTENT" > "$SHIM_PATH" || { err "写入入口失败：$SHIM_PATH"; rollback; die 7 "安装失败并已回滚。"; }
      SHIM_UPDATED=1
    else
      SHIM_UPDATED=0
    fi
  else
    printf '%s' "$SHIM_CONTENT" > "$SHIM_PATH" || { err "写入入口失败：$SHIM_PATH"; rollback; die 7 "安装失败并已回滚。"; }
    SHIM_CREATED=1
    SHIM_UPDATED=1
  fi
  chmod 755 "$SHIM_PATH" || { err "无法设置入口可执行权限：$SHIM_PATH"; rollback; die 7 "安装失败并已回滚。"; }
fi

# 可选：幂等写入 shell profile
PROFILE_MARKER="# devpocket:PATH"
if [ "$UPDATE_PROFILE" = "1" ]; then
  PROFILE_FILE="$HOME/.profile"
  case "${SHELL:-}" in
    *zsh) PROFILE_FILE="$HOME/.zshrc" ;;
    *bash) PROFILE_FILE="$HOME/.bashrc" ;;
  esac
  if [ -f "$PROFILE_FILE" ] && grep -qF "$PROFILE_MARKER" "$PROFILE_FILE"; then
    log "shell profile 已包含 DevPocket PATH，跳过（幂等）。"
  else
    {
      printf '\n%s\n' "$PROFILE_MARKER"
      printf 'case ":$PATH:" in *":%s:"*) ;; *) export PATH="%s:$PATH" ;; esac\n' "$BIN_DIR" "$BIN_DIR"
    } >> "$PROFILE_FILE" || { err "写入 $PROFILE_FILE 失败"; rollback; die 7 "安装失败并已回滚。"; }
    log "已向 $PROFILE_FILE 追加 PATH。新开终端或执行 source $PROFILE_FILE 生效。"
  fi
fi

log ""
log "DevPocket $VERSION 安装完成。"
log "  安装目录：$INSTALL_DIR"
log "  当前版本：$INSTALL_DIR/versions/$VERSION"
if [ -n "$SHIM_PATH" ]; then log "  命令入口：$SHIM_PATH"; fi
if [ "$UPDATE_PROFILE" != "1" ] && [ -n "$SHIM_PATH" ]; then
  log "  提示：$BIN_DIR 可能不在 PATH 中。可执行："
  log "        export PATH=\"$BIN_DIR:\$PATH\""
  log "     或重新运行 install.sh --update-profile 以幂等写入 shell profile。"
fi
log "  验证：devpocket capability && devpocket doctor"
exit 0
