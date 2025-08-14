#!/usr/bin/env bash
set -euo pipefail

# ########################################################################################
# # 1) 安装工具（在你的 PC 上）
# sudo apt update
# sudo apt install -y git git-lfs python3 curl

# # 安装 repo（谷歌的多仓库同步工具）
# curl -o ~/bin/repo https://storage.googleapis.com/git-repo-downloads/repo
# chmod +x ~/bin/repo
# export PATH=$HOME/bin:$PATH

# # 2) 用 Rockchip 的 RK3588 Linux manifest 初始化、同步（含内核 5.10.160）
# mkdir -p ~/rk3588-sdk && cd ~/rk3588-sdk
# repo init -u https://gitlab.com/rk3588_linux/rockchip/platform/manifests.git -b linux \
#   -m rk3588_linux_release_v1.1.0_20230420.xml
# repo sync -j"$(nproc)"

# # 3) 进入 SDK 内核目录（同步完成后一般是 kernel/ 或 kernel/kernel）
# cd kernel || cd kernel/kernel

# # 4) 用板子当前的配置来对齐（先从板子上拿 /proc/config.gz）
# #   如果你已经有了 .config 就跳过这步
# # （在板子上）    zcat /proc/config.gz > /tmp/rk3588.config
# # （回到PC上）    scp bk@板子IP:/tmp/rk3588.config .config

# # 5) 最小准备 & 核对将要产出的 kernelrelease
# make olddefconfig
# make prepare modules_prepare
# make -s kernelrelease
# ########################################################################################

### ======= 连接与路径配置（按需改） =======
BOARD_USER="${BOARD_USER:-bk}"
BOARD_HOST="${BOARD_HOST:-192.168.0.109}"
BOARD_PASS="${BOARD_PASS:-12345678}"   # 板子密码
BOARD="${BOARD_USER}@${BOARD_HOST}"

# 默认使用 repo 拉下来的 SDK 内核源码目录
KERNEL_SRC="${KERNEL_SRC:-$HOME/rk3588-sdk/kernel}"
# 自动探测 repo 拉下的 kernel 目录（有时在 kernel/ 或 kernel/kernel）
if [ ! -d "$KERNEL_SRC" ]; then
  if [ -d "$HOME/rk3588-sdk/kernel/kernel" ]; then
    KERNEL_SRC="$HOME/rk3588-sdk/kernel/kernel"
  fi
fi

# unused, placeholder only! kzeng
KERNEL_BRANCH="${KERNEL_BRANCH:-orange-pi-5.10-rk3588}"

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH="${ARCH:-arm64}"

# 要编译的模块目录
MOD_DIRS=(
  "drivers/usb/storage"   # usb-storage / uas
  "drivers/scsi"          # sd_mod
  "fs/exfat"              # exfat（可选）
)

WORKDIR="${WORKDIR:-$PWD/rk3588-usb-build}"
OUTPKG_NAME="${OUTPKG_NAME:-rk3588-usb-mods.tgz}"

### ======= 安装依赖 =======
sudo apt-get update -y
sudo apt-get install -y git build-essential gcc-aarch64-linux-gnu \
  bc bison flex libssl-dev libncurses5-dev dwarves fakeroot cpio sshpass

SSH_CMD=(sshpass -p "$BOARD_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$BOARD")
SCP_CMD=(sshpass -p "$BOARD_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

### ======= 检查源码树 =======
if [ ! -d "$KERNEL_SRC" ]; then
  echo "[X] 找不到源码目录：$KERNEL_SRC（尝试过 $HOME/rk3588-sdk/kernel 和 $HOME/rk3588-sdk/kernel/kernel）"
  exit 1
fi

cd "$KERNEL_SRC"
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "[*] 当前源码分支: $CUR_BRANCH"

### ======= 从板子抓取目标信息 =======
mkdir -p "$WORKDIR/target-info"
if "${SSH_CMD[@]}" 'test -f /proc/config.gz'; then
  "${SSH_CMD[@]}" 'cat /proc/config.gz' > "$WORKDIR/target-info/config.gz"
else
  KR="$("${SSH_CMD[@]}" 'uname -r' || true)"
  "${SSH_CMD[@]}" "cat /boot/config-${KR}" > "$WORKDIR/target-info/config" || true
fi
"${SSH_CMD[@]}" 'uname -a' > "$WORKDIR/target-info/uname-a.txt" || true
"${SSH_CMD[@]}" 'uname -r' > "$WORKDIR/target-info/uname-r.txt" || true
if "${SSH_CMD[@]}" 'test -f /lib/modules/$(uname -r)/Module.symvers'; then
  "${SSH_CMD[@]}" 'cat /lib/modules/$(uname -r)/Module.symvers' > "$WORKDIR/target-info/Module.symvers"
fi
"${SSH_CMD[@]}" 'mod=$(find /lib/modules/$(uname -r) -type f -name "*.ko" | head -n1); if [ -n "$mod" ]; then modinfo -F vermagic "$mod"; fi' \
  > "$WORKDIR/target-info/vermagic.txt" || true

echo "[*] 目标 uname -a:"
cat "$WORKDIR/target-info/uname-a.txt" || true
echo "[*] 目标 vermagic:"
cat "$WORKDIR/target-info/vermagic.txt" || true

# 记录远端内核版本并做规范化（某些发行 uname -r 带前缀 linux）
REMOTE_KREL_RAW="$(cat "$WORKDIR/target-info/uname-r.txt" 2>/dev/null || true)"
REMOTE_KREL="${REMOTE_KREL_RAW#linux}"

# 本地源码根据 .config 计算的内核版本并规范化
LOCAL_KREL_RAW="$(make -s kernelrelease)"
LOCAL_KREL="${LOCAL_KREL_RAW#linux}"

echo "    remote uname -r (raw): ${REMOTE_KREL_RAW}"
echo "    local  kernelrelease (raw): ${LOCAL_KREL_RAW}"
echo "    remote uname -r: ${REMOTE_KREL}"
echo "    local  kernelrelease: ${LOCAL_KREL}"
if [ -n "$REMOTE_KREL" ] && [ -n "$LOCAL_KREL" ] && [ "$REMOTE_KREL" != "$LOCAL_KREL" ]; then
  echo "[X] 本地源码内核版本 (${LOCAL_KREL}) 与目标运行内核 (${REMOTE_KREL}) 不一致。"
  echo "    请改用匹配的源码/headers（包含 Module.symvers），或调整 CONFIG_LOCALVERSION 后重试。"
  exit 2
fi

### ======= 套用 .config 与符号表 =======
if [ -f "$WORKDIR/target-info/config.gz" ]; then
  zcat "$WORKDIR/target-info/config.gz" > .config
elif [ -f "$WORKDIR/target-info/config" ]; then
  cp "$WORKDIR/target-info/config" .config
fi
if [ -f "$WORKDIR/target-info/Module.symvers" ]; then
  cp "$WORKDIR/target-info/Module.symvers" .
else
  if "${SSH_CMD[@]}" 'test -f /lib/modules/$(uname -r)/build/Module.symvers'; then
    "${SSH_CMD[@]}" 'cat /lib/modules/$(uname -r)/build/Module.symvers' > "$WORKDIR/target-info/Module.symvers"
    cp "$WORKDIR/target-info/Module.symvers" .
  else
    echo "[X] 找不到匹配的 Module.symvers（目标板也未提供 headers/build）。无法安全构建可加载模块。"
    exit 3
  fi
fi

export ARCH CROSS_COMPILE
make olddefconfig
make prepare modules_prepare

### ======= 保留必要模块 =======
[ -x scripts/config ] || make scripts
enable_m () { ./scripts/config --module "$1" || ./scripts/config --enable "$1" || true; }

enable_m CONFIG_USB_STORAGE
enable_m CONFIG_USB_UAS
enable_m CONFIG_SCSI
enable_m CONFIG_BLK_DEV_SD
./scripts/config --enable CONFIG_SCSI_SCAN_ASYNC || true
enable_m CONFIG_VFAT_FS
enable_m CONFIG_MSDOS_FS
enable_m CONFIG_EXFAT_FS
enable_m CONFIG_NLS_CODEPAGE_437
enable_m CONFIG_NLS_ISO8859_1
enable_m CONFIG_EXT4_FS

make olddefconfig
make prepare modules_prepare

### ======= 编译 =======
for d in "${MOD_DIRS[@]}"; do
  echo "-> make M=${d} modules"
  make -j"$(nproc)" M="${d}" modules
done

### ======= 校验 vermagic =======
echo "[*] 校验 vermagic..."
MODINFO_BIN="$(command -v modinfo || echo /sbin/modinfo)"
BUILD_VERMAGIC="$("$MODINFO_BIN" -F vermagic drivers/usb/storage/usb-storage.ko 2>/dev/null || true)"
TARGET_VERMAGIC="$(cat "$WORKDIR/target-info/vermagic.txt" 2>/dev/null || true)"
echo "    build vermagic:  ${BUILD_VERMAGIC:-<unknown>}"
echo "    target vermagic: ${TARGET_VERMAGIC:-<unknown>}"
if [ -n "${TARGET_VERMAGIC:-}" ] && [ -n "${BUILD_VERMAGIC:-}" ] && [ "$BUILD_VERMAGIC" != "$TARGET_VERMAGIC" ]; then
  echo "[!] 警告：vermagic 不匹配，加载可能失败。"
fi

### ======= 收集与安装 =======
OUTROOT="$WORKDIR/outmods/extra"
mkdir -p "$OUTROOT"
find drivers/usb/storage -name "*.ko" -exec cp -v {} "$OUTROOT"/ \;
find drivers/scsi        -name "sd_mod.ko" -exec cp -v {} "$OUTROOT"/ \;
find fs/exfat            -name "*.ko" -exec cp -v {} "$OUTROOT"/ \; 2>/dev/null || true

cat > "$WORKDIR/outmods/install_and_load.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 打印路径以便排错
echo "SCRIPT_DIR=${SCRIPT_DIR}"
ls -l "${SCRIPT_DIR}/extra" || true
KREL="$(uname -r)"
MODBASE="/lib/modules/${KREL}"
mkdir -p "${MODBASE}/extra"
cp -v "${SCRIPT_DIR}/extra/"*.ko "${MODBASE}/extra/" || true
depmod -a "${KREL}"
modprobe usb-storage || true
modprobe uas || true
modprobe sd_mod || true
modprobe exfat || true
dmesg | tail -n 80
EOS
chmod +x "$WORKDIR/outmods/install_and_load.sh"

tar -C "$WORKDIR/outmods" -czf "$WORKDIR/${OUTPKG_NAME}" .
"${SCP_CMD[@]}" "$WORKDIR/${OUTPKG_NAME}" "${BOARD}:/tmp/${OUTPKG_NAME}"
"${SSH_CMD[@]}" "rm -rf /tmp/rkmods && mkdir -p /tmp/rkmods && \
  tar --no-same-owner --no-same-permissions -xzf /tmp/${OUTPKG_NAME} -C /tmp/rkmods && \
  echo '$BOARD_PASS' | sudo -S bash /tmp/rkmods/install_and_load.sh"

echo '[*] 完成。'
