# **Gemtek-W1700K-6.18 - OpenWrt SnapShot Build Script**

This is a customized OpenWrt firmware build srript for the **Gemtek W1700K** WiFi 7 (BE19000) router, based on the Airoha AN7581 SoC with MT7996 wireless chipset.

> [!WARNING]
> For those that prefer to build locally (For old farts like me)

## Build Commands

### Prerequisites (Ubuntu 24.04+)
```bash
sudo apt update
sudo apt install build-essential clang flex bison g++ gawk gcc-multilib \
g++-multilib gettext git libncurses5-dev libssl-dev python3-distutils rsync \ 
unzip zlib1g-dev file wget dos2unix`
```

### Clone Repo & Initial Build

```bash
git clone https://github.com/Gilly1970/Gemtek-W1700K.git
```
```bash
sudo chmod 775 -R Gemtek-W1700K
```
### Make the script executable and run script

```bash
# Make script executable
cd Gemtek-W1700K
sudo chmod +x Openwrt_Gemtek_w1700k.sh

# Run script
./Openwrt_Gemtek_w1700k.sh

```

### OpenWrt Build Commands (run inside `openwrt/`)
```bash
make menuconfig              # Configure packages and kernel options interactively
make -j$(nproc)              # Build firmware (parallel)
make -j1 V=s                 # Build with verbose output (for debugging)
./scripts/feeds update -a    # Update package feed definitions
./scripts/feeds install -a   # Install feed package symlinks
make clean                   # Clean build artifacts (keep toolchain)
make dirclean                # Full clean including toolchain
```

### Build Output
`openwrt/bin/targets/airoha/an7581/` — openwrt-airoha-an7581-gemtek_w1700k-ubi-squashfs-sysupgrade.itb/images for flashing

## How the Build Script Works

`Openwrt_Gemtek_w1700k.sh` orchestrates the full setup:
1. Clones OpenWrt from `https://git.openwrt.org/openwrt/openwrt.git`
2. Copies files from `openwrt-patches/` to their destinations in the OpenWrt tree, using `openwrt-patches/openwrt-add-patch` as the mapping list (format: `source_filename:destination_path` for conflicts)
3. Removes files listed in `openwrt-patches/openwrt-remove`
4. Copies `files/` directory into the OpenWrt `files/` overlay (runtime configs)
5. Applies `config/config.diff` as the `.config` build configuration
6. Runs `feeds update/install` then optionally `make menuconfig` before building

**To add a new patch**: place the file in `openwrt-patches/` and add its destination path to `openwrt-patches/openwrt-add-patch`.

**To add a runtime file** (lands on the router filesystem): place it under `files/etc/...`.

## luci-app-airoha-flowsense

**Monitoring dashboard for:** Visual Hardware Offload & PPE Performance Monitor for the Gemtek W1700K (Airoha AN7581 / MT7996).

<img width="780" height="842" alt="image" src="https://github.com/user-attachments/assets/5b8539bb-1aaf-4d30-b7b1-69cffaf22dea" />


## Enable and start the flowsense service

```bash
chmod +x /usr/libexec/rpcd/luci.airoha_flowsense
chmod +x /etc/init.d/npu-jitter
chmod +x /usr/libexec/npu-jitter-daemon
/etc/init.d/npu-jitter enable
/etc/init.d/npu-jitter start
/etc/init.d/rpcd restart
```
## Configuration

`/etc/config/npu-monitor` — UCI config created on install:

```
config jitter 'settings'
    option ping_target '1.1.1.1'
```

Change `ping_target` to any reachable upstream host for latency monitoring.

---

> [!NOTE]
> My builds do not have cpu overclocking and are built from master.
> This is a heavly patched repo and can and will break as new commits are added to master. 
> I have locked in the last commit that I've compiled and built and can confirm working. 
> If you want to build from the latest commit just remove the commit hash `readonly OPENWRT_COMMIT=""` and it will use the latest commit.  
 
```bash
OPENWRT_BRANCH="master"
readonly OPENWRT_COMMIT="a8d5544c8349fe78e99954e948827d1c699ac5da"
```
