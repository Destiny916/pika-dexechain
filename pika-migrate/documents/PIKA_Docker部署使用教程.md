<div align="center">

# 🦾 Pika Sense 双采集套件 · Docker 部署与使用教程

**从零部署到采集双手轨迹数据 · 可在新机器完整复刻**

`Ubuntu 22.04` · `Docker` · `ROS 2 Humble` · `RealSense D405 ×2` · `Lighthouse 定位`

</div>

---

> [!NOTE]
> 本教程基于一次**完整成功**的部署整理，覆盖官方文档没讲的 **Docker 适配点**与**全部踩坑**。
> 采集内容：**双手轨迹位姿 + 双 RealSense 深度相机 + 双鱼眼相机 + 双夹爪角度**。
>
> **路径约定**：部署根目录 `/home/dex/app/pika`（新机请替换用户名 `dex`）。
> **图标约定**：⚠️ = 必看的坑 · 🔧 = 含「本机特定值」、新机要重新获取 · 💡 = 提示

---

## 📑 目录

| | 章节 | 内容 |
|---|---|---|
| 🐳 | [Docker 小白须知](#-docker-小白须知必读) | 容器怎么进/出/停/启 · **不熟 Docker 必读** |
| 0 | [前置条件](#0-前置条件) | 硬件 / 系统要求 |
| 1 | [硬件搭建](#1-硬件搭建) | 基站供电·频道·配对·接线 |
| 2 | [Docker 基础环境](#2-docker-基础环境) | 装 Docker·配代理 |
| 3 | [构建镜像与项目](#3-构建-pika-镜像与项目) | Dockerfile·容器·udev·install |
| 4 | [基站校准](#4-基站校准) | survive-cli·acc err |
| 5 | [设备使能](#5-设备使能) | 绑定·左右手·相机序列号·启动 |
| 6 | [采集数据](#6-采集数据) | xterm 状态窗·录制 |
| 7 | [数据同步](#7-数据同步) | sync.txt |
| 8 | [数据重播](#8-数据重播-可选) | data_replay |
| 9 | [日常使用速查](#9-日常使用速查) | 开机即用 |
| 10 | [踩坑速查](#10-踩坑速查-troubleshooting) | 故障排查表 |

---

## 🗺️ 总览流程

```text
硬件搭建            软件部署(一次性)                     日常使用(每次)
─────────          ──────────────────────              ──────────────
基站供电            ① 装 Docker + 代理                   ① docker start pika
调不同频道    ──▶   ② 构建 pika:humble 镜像        ──▶   ② xhost +local:root
Sense 配对          ③ 起容器 + udev + install            ③ 校准(基站动过才需)
夹爪接 USB          ④ 校准 / 绑定 / 左右手               ④ start_multi_sensor.bash
                                                         ⑤ 采集 → 同步 → 重播
```

---

## 🐳 Docker 小白须知（必读）

> 不熟 Docker 也没关系，记住下面几点就够用了。

### 概念（一句话版）

- **镜像 (image)** = 一张「装好环境的光盘模板」，本项目叫 `pika:humble`。
- **容器 (container)** = 用光盘开出来的「正在运行的盒子」，本项目叫 `pika`。我们所有 ROS/采集命令都在盒子里跑。
- 我们的盒子是**常驻**的（一直在后台开着发呆），可以反复「走进去」用。数据和代码放在
  `/home/dex/app/pika`、`/home/dex/agilex`，这两个目录**宿主机和盒子里是同一份**（改一边另一边同步变）。

### 我现在在盒子里，还是在宿主机？看提示符 👀

| 提示符长这样 | 你在哪 |
|---|---|
| `dex@dex-MS-Terminator-B650M:~$` | **宿主机**（你的真实系统） |
| `root@dex-MS-Terminator-B650M:/...#` | **容器里**（盒子内，注意是 `root@` 和 `#`） |

### 四个核心操作

| 想做什么 | 命令 | 在哪执行 |
|---|---|---|
| **进**盒子（开一个终端） | `docker exec -it pika bash` | 宿主机 |
| **出**盒子（盒子继续后台跑） | `exit` 或按 `Ctrl+D` | 容器内 |
| **停**整个盒子（关机/释放资源时） | `docker stop pika` | 宿主机 |
| **启**盒子（重启电脑后） | `docker start pika` | 宿主机 |

### 必须记住的几点 ⚠️

1. **`exit` 不会关闭容器** —— 它只是离开当前终端，盒子还在后台跑。真要停用 `docker stop pika`。
2. **要开多个终端**（一个跑传感器、一个跑采集…）就**多次** `docker exec -it pika bash`，每次开一个新窗口走进同一个盒子。
3. 如果某个终端**正跑着东西**（在刷日志），先按 `Ctrl+C` 停掉它，再 `exit`。
4. **重启电脑后**：用 `docker start pika`（恢复原盒子，配置都在），**不要**用 `docker_run.sh`（那是**重建**新盒子，会丢配置）。
5. 容器里**没有** `code`（VS Code）、`docker` 等命令；**看/改文件、用 VS Code 在宿主机做**（同一份文件）。
6. 进盒子后要用图形界面(rviz/采集弹窗)，记得宿主机先 `xhost +local:root` 授权。
7. 路径都用**绝对路径**（`/home/dex/...`）；容器里 `~` 是 `/root`，和宿主机的家目录不是一回事。

---

## 0. 前置条件

| 项 | 要求 |
|---|---|
| **系统** | Ubuntu 22.04 (x86_64)，Python 3.10 |
| **硬件** | 2× Pika Sense 手持夹爪（每个含 定位标签 + RealSense D405 + 鱼眼 + 夹爪串口）· 2× 无线接收器(dongle) · 2× 定位基站(SteamVR 2.0) · 三脚架 |
| **GPU** | NVIDIA 显卡 + 驱动（可选，用于 rviz/相机加速） |
| **网络** | 能访问 GitHub / Docker Hub / apt 源（国内通常需代理） |

---

## 1. 硬件搭建

> 💡 可与「软件部署」并行进行。

### 1.1　基站

1. **供电** — 用配套 HTC 220V 适配器 + 供电线束**直连基站**（基站之间、与电脑之间**都无线缆**）。
2. **摆放** — 两台装三脚架**架高 ~2 m**、置于工作区**对角**、镜头**俯视**，FOV 共同覆盖采集区，Sense 全程无遮挡。
3. **不同频道** — 用回形针/卡针戳基站**背面频道键**，绿灯闪一次 = 频道 +1，两台调成**不同频道**。

> [!WARNING]
> - 撕掉基站正面**镜面保护膜**。
> - 不要正对**玻璃/镜子**等反光面（必须时用黑布隔开）。
> - 房间**无阳光直射**、**无其他主动红外**设备。
> - 两台基站**必须不同频道**，否则红外冲突、定位乱跳（§4 校准时可用 `survive-cli` 输出确认）。

### 1.2　Pika Sense 配对（仅首次，需 Windows）

- 接收器插 Windows，装 SteamVR → `设备 > 配对控制器 > HTC Vive 追踪器`，长按 Sense 电源键配对，指示灯**绿色常亮** = 成功。
- 每个 Sense 配一个 dongle。

> [!IMPORTANT]
> Sense 与 dongle **一一绑定**，记清配对关系。

### 1.3　接入本机

- 2 个 dongle、2 个夹爪 USB 线都插本机；**RealSense 必须插 USB 3.0 口**。

> [!WARNING]
> 每个夹爪**固定插某个 USB 口后别再换口** —— §5 的相机/串口绑定按物理端口固定。

---

## 2. Docker 基础环境

### 2.1　安装 Docker + NVIDIA 容器运行时

```bash
# Docker（若未装）
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker      # 当前用户免 sudo 用 docker

# NVIDIA 容器运行时（有 N 卡时，参考官方安装指南）
docker info | grep -i runtime      # 应出现 nvidia
nvidia-smi -L                      # 应列出显卡
```

### 2.2　配置代理 ⚠️

> [!WARNING]
> Docker **守护进程**的代理与宿主 shell **是分开的**，不单独配会导致拉镜像 `EOF`/超时。
> 把下方 `127.0.0.1:7890` 换成**你这台机器的实际代理**(查:`env | grep -i proxy`,端口因 clash 配置而异)。无需代理可跳过本节。

<details>
<summary><b>(a) 守护进程代理</b></summary>

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null <<'EOF'
[Service]
Environment="HTTP_PROXY=http://127.0.0.1:7890"
Environment="HTTPS_PROXY=http://127.0.0.1:7890"
Environment="NO_PROXY=localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,::1"
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
docker pull hello-world          # 验证
```
</details>

<details>
<summary><b>(b) 客户端代理（让 build 时容器内 apt/pip 走代理）</b></summary>

```bash
mkdir -p ~/.docker
cat > ~/.docker/config.json <<'EOF'
{ "proxies": { "default": {
  "httpProxy": "http://127.0.0.1:7890",
  "httpsProxy": "http://127.0.0.1:7890",
  "noProxy": "localhost,127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,::1"
}}}
EOF
```
</details>

---

## 3. 构建 Pika 镜像与项目

> 💡 **用迁移包的用户跳过整个 §3**:不需要 clone/build,直接 `bash migrate_software.sh`(见「迁移到新机器清单.md」)。§3 仅供**从零构建**镜像时参考,否则会白等 20–40 分钟还可能版本不一致。

### 3.1　克隆代码

```bash
mkdir -p /home/dex/app/pika && cd /home/dex/app/pika
git clone https://github.com/agilexrobotics/pika_ros.git
cd pika_ros && git checkout ros2 && git submodule update --init --recursive
ls source/      # 确认有 librealsense-2.55.1.zip、curl-7.75.0.zip、install.zip
```

### 3.2　构建镜像

准备精简构建上下文（硬链接，不占额外空间）：

```bash
cd /home/dex/app/pika && mkdir -p imgbuild
ln -f pika_ros/source/librealsense-2.55.1.zip imgbuild/
ln -f pika_ros/source/curl-7.75.0.zip imgbuild/
```

<details>
<summary><b>📄 imgbuild/Dockerfile（点击展开）</b></summary>

```dockerfile
FROM osrf/ros:humble-desktop
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      libjsoncpp-dev libpcap-dev python3-pcl build-essential zlib1g-dev libx11-dev \
      libusb-1.0-0-dev freeglut3-dev liblapacke-dev libopenblas-dev libatlas-base-dev \
      cmake git libssl-dev pkg-config libgtk-3-dev libglfw3-dev libgl1-mesa-dev \
      libglu1-mesa-dev g++ python3-pip libopenvr-dev ros-humble-diagnostic-updater \
      cutecom wget unzip usbutils ca-certificates xterm python3-tk \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common \
    && add-apt-repository ppa:ubuntu-toolchain-r/test -y \
    && apt-get update && apt-get install -y --no-install-recommends \
       gcc-13 g++-13 libstdc++6 libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

# ⚠️ cv_bridge 需 numpy<2，否则鱼眼/采集会崩（_ARRAY_API not found）；matplotlib 供 data_replay.py 重播
# 关键是先钉死 numpy<2；opencv-python 不必钉版本，pip 会自动挑兼容 numpy<2 的版本
#（本迁移包镜像实测落 opencv 4.13.0.92 + numpy 1.26.4，共存正常）。
# 曾踩坑:pip 未让 numpy<2 真正生效 → numpy 被拉到 2.x → cv_bridge 崩；故这里显式钉 numpy<2。
RUN pip3 install --no-cache-dir "numpy<2" opencv-python matplotlib

# librealsense 2.55.1（用仓库自带 source，内含定制静态 curl）
COPY librealsense-2.55.1.zip curl-7.75.0.zip /tmp/
RUN cd /opt && unzip -q /tmp/librealsense-2.55.1.zip && unzip -q /tmp/curl-7.75.0.zip \
    && sed -i 's#/home/agilex/pika_ros/source/curl-7.75.0#/opt/curl-7.75.0#g' \
         /opt/librealsense-2.55.1/CMake/external_libcurl.cmake \
    && cd /opt/librealsense-2.55.1 && mkdir build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j"$(nproc)" && make install && ldconfig \
    && rm -rf /tmp/*.zip /opt/librealsense-2.55.1/build

RUN echo 'source /opt/ros/humble/setup.bash' >> /root/.bashrc
WORKDIR /home/dex/app/pika
CMD ["bash"]
```
> 💡 相比官方教程，这里把 `numpy<2` 与 `xterm` **提前装进镜像**，省去后续踩坑。
</details>

```bash
cd /home/dex/app/pika
DOCKER_BUILDKIT=0 docker build --network=host -t pika:humble imgbuild/
```

> [!NOTE]
> 约 **20–40 分钟**（拉基础镜像 + 编译 librealsense）。`--network=host` 让容器内 apt/pip 走宿主代理；
> 成功标志：`Successfully tagged pika:humble`。

### 3.3　容器启动脚本

<details>
<summary><b>📄 docker_run.sh（点击展开）</b></summary>

```bash
#!/bin/bash
set -e
IMAGE_NAME="pika:humble"; CONTAINER_NAME="pika"
xhost +local:root >/dev/null 2>&1 || true
docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" && docker rm -f "$CONTAINER_NAME" >/dev/null
docker run -id --name "$CONTAINER_NAME" --privileged \
  -e ROS_DOMAIN_ID=42 \
  --gpus all -e NVIDIA_DRIVER_CAPABILITIES=all -e NVIDIA_VISIBLE_DEVICES=all \
  --network=host -e DISPLAY="$DISPLAY" -e QT_X11_NO_MITSHM=1 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v /dev:/dev --shm-size 8G -v /dev/shm:/dev/shm \
  -v /home/dex/app/pika:/home/dex/app/pika \
  -v /home/dex/agilex:/home/dex/agilex \
  "$IMAGE_NAME" sleep infinity
echo "容器已启动：docker exec -it $CONTAINER_NAME bash"
```
</details>

> 💡 关键点：`--privileged -v /dev:/dev` 访问 USB · `--network=host` + X11 透传支持 GUI 弹窗 ·
> **容器内外同路径挂载** `/home/dex/app/pika` 使硬编码路径一致。

```bash
mkdir -p /home/dex/agilex/data
cd /home/dex/app/pika && bash docker_run.sh
```

### 3.4　USB 规则（装在宿主机！）⚠️

> [!WARNING]
> 容器内**没有 udevd**，所有 udev 规则都装在**宿主机**，靠 `-v /dev:/dev` 映射进容器。

```bash
cd /home/dex/app/pika/pika_ros
sudo cp scripts/81-vive.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger --action=add
```

### 3.5　完善 install + 修复硬编码路径

```bash
cd /home/dex/app/pika/pika_ros
unzip -q source/install.zip -d .          # 得到 pika_ros/install
chmod -R 777 install
grep -rIl "/home/agilex" install | xargs -r sed -i 's#/home/agilex#/home/dex/agilex#g'
grep -rI "/home/agilex" install | wc -l   # 应为 0
```

> [!WARNING]
> **只能 sed 文本文件**，别 sed 编译好的二进制（路径长度变化会损坏，需用 patchelf）。
> 本版 install 的 colcon `setup.bash` 用相对路径自动定位，无需改；命中的只是 `data_tools` 默认数据路径。

容器内写环境变量（`docker exec -it pika bash` 后）：

```bash
cat >> /root/.bashrc <<'EOF'
source /home/dex/app/pika/pika_ros/install/setup.bash
export LD_LIBRARY_PATH=/home/dex/app/pika/pika_ros/install/libsurvive/lib:$LD_LIBRARY_PATH
EOF
# 校准结果持久化（容器重建不丢）
mkdir -p /home/dex/app/pika/libsurvive_config /root/.config
ln -sf /home/dex/app/pika/libsurvive_config /root/.config/libsurvive
```

> ✅ 验证：容器内 `realsense-viewer` 能看到相机画面；`ros2 pkg list | grep pika_locator` 有输出。

---

## 4. 基站校准

> 首次部署 / 基站被移动 / 切换频道 后都要校准。进容器：`docker exec -it pika bash`

```bash
cd /home/dex/app/pika/pika_ros/install/libsurvive/bin
./survive-cli --force-calibrate
```

> [!CAUTION]
> **最容易漏的坑**：先长按开机「**定位标签**」（夹爪顶部那个大头，**不是夹爪本身**）到**绿灯常亮**！
> 定位标签没开 → dongle 收不到数据 → 卡在 `clearing position` 不动。

校准时**保持静止**，观察输出：

- `Got OOTX packet <频道> <基站ID>` 两行 → 确认**两台频道不同**（如 `10` 和 `11`）；相同就去戳一台改频道。
- ⚠️ **每台基站 `acc err` 必须 < 0.005**（如 `0.0007` / `0.0030` 合格）。
  启动设备栈后还要在 RViz 里移动左右夹爪，确认定位轨迹丝滑连续、不跳变不卡顿。

合格后 **`Ctrl+C`** 结束（自动写入 `libsurvive_config/config.json` 持久化）。

> [!WARNING]
> 校准完到采集结束**别再碰基站**，碰了就要重校。

---

## 5. 设备使能

> 💡 **推荐直接用 `setup_hardware.sh` 引导式**(见「迁移到新机器清单.md」§3):
> ② 一次插一只手柄自动绑夹爪+D405，并在 wireless 模式探测/写入 LHR；
> ③ 先做基站校准；④ 再用鱼眼和左右 Pose 实际运动量核对左右（不用 topic Hz），
> 反向时自动对调、重启复测，退出时自动清理节点。下面 §5.1–5.3 是**手动原理/兜底**,
> 脚本失效时再用;注意脚本已把「②夹爪 + ③D405」合并为「按手柄一次插拔」。

### 5.1　🔧 绑定夹爪鱼眼 + 串口（宿主机 udev，按物理端口固定）

> 官方 `setup_device.py` 依赖容器内 udev，Docker 不适用 → 改在**宿主机**写规则。

**① 查每个夹爪的 USB 端口路径**（两夹爪都插着）：

```bash
# 串口
for t in /dev/ttyUSB*; do echo "$t -> $(basename $(readlink -f /sys/class/tty/$(basename $t)/device))"; done
# 鱼眼(1bcf:2cd1)的 video 节点与端口
for v in /sys/class/video4linux/video*; do
  [ "$(cat $v/device/../idVendor 2>/dev/null)" = "1bcf" ] && \
  echo "$(basename $v) -> $(basename $(readlink -f $v/device))"; done
```

> 💡 同一夹爪的串口与鱼眼**端口前缀相同**（如串口 `1-2.4.4.4:1.0`、鱼眼 `1-2.4.4.1:1.0` 同属 `1-2` 支路）。

**② 确定哪只是左手**（约定 **50 = 左，51 = 右**）。

> 💡 Sense 左右(§5.2)是无线的，需与相机/串口左右一致。可**晃动左手夹爪，看哪个鱼眼画面在动**来确认。
> 若先随便绑，§5.2 测出左手后发现不一致，把规则里 50/51 对调重装即可。

**③ 写规则**（把端口路径换成你①②得到的）：

```bash
sudo tee /etc/udev/rules.d/pika-sensor-bind.rules >/dev/null <<'EOF'
ACTION=="add", KERNELS=="1-2.4.4.4:1.0", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="ttyUSB50"
ACTION=="add", KERNELS=="1-1.4.4.4:1.0", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="ttyUSB51"
ACTION=="add", KERNEL=="video[0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48]*", KERNELS=="1-2.4.4.1:1.0", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="video50"
ACTION=="add", KERNEL=="video[0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48]*", KERNELS=="1-1.4.4.1:1.0", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="video51"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add        # ⚠️ 必须带 --action=add（默认 change 不匹配）
ls -l /dev/ttyUSB50 /dev/ttyUSB51 /dev/video50 /dev/video51   # 应有 4 个符号链接
```

### 5.2　🔧 区分左右手（写 Sense 编号）

```bash
docker exec -it pika bash
ros2 launch pika_locator get_code.launch.py            # rviz 出现 base_link + 两个 LHR-xxxx
# 另开一个容器终端查编号：
ros2 topic echo /tf | grep child_frame_id | sort -u
```

晃动你要设为「左手」的夹爪，看哪个 `LHR-xxxx` 在动，记下左/右编号，写入容器 `/root/.bashrc`：

```bash
echo 'export pika_L_code=LHR-XXXXXXXX' >> ~/.bashrc      # 左手
echo 'export pika_R_code=LHR-YYYYYYYY' >> ~/.bashrc      # 右手
source ~/.bashrc
```
> 完成后在 get_code 终端 `Ctrl+C` 结束。

### 5.3　🔧 改对 RealSense 序列号

```bash
docker exec pika rs-enumerate-devices -s        # 列出两台 D405 序列号
```

编辑 `pika_ros/scripts/start_multi_sensor.bash` 顶部：

```bash
l_depth_camera_no=<左手D405序列号>
r_depth_camera_no=<右手D405序列号>
```
> 💡 按物理端口判断左右：`usb1` 的 `1-2` 与 `usb2` 的 `2-2` 通常是**同一物理口**。

### 5.4　启动全部传感器（一体化）

> [!WARNING]
> 本套件的 `start_multi_sensor.bash` **已包含定位器**（定位 + 双相机 + 双鱼眼 + 双串口 + rviz）。
> **不要再单独跑 `pika_double_locator.launch.py`**，否则两个定位器抢 dongle → `LIBUSB_ERROR_BUSY`。

```bash
docker exec -it pika bash
cd /home/dex/app/pika/pika_ros/scripts && bash start_multi_sensor.bash
```

✅ 验证数据在流（另开容器终端）：

```bash
source /home/dex/app/pika/pika_ros/install/setup.bash
for t in /tf /camera_l/color/image_raw /camera_fisheye_l/color/image_raw /gripper_l/data; do
  echo -n "$t  "; timeout 4 ros2 topic hz $t 2>/dev/null | grep -m1 "average rate"; done
```
> 期望：`/tf` ~400 Hz，相机/鱼眼 ~30 Hz，夹爪 ~125 Hz。rviz 里左右手坐标系**不抖**（抖=误差大，回 §4）。

---

## 6. 采集数据

> [!WARNING]
> 采集 launch 默认用 `gnome-terminal` 弹状态窗，容器里没有 → 改用 **xterm**（已在 §3.2 镜像里预装）。
> 编辑 `pika_ros/install/data_tools/share/data_tools/launch/run_data_capture.launch.py`，
> 把 `prefix='gnome-terminal -- ...'` 那行改成：
> ```python
> prefix='xterm -fa Monospace -fs 11 -title PikaCapture -e bash -c "$0 $@; echo; echo 采集已退出，按回车关闭...; read"'
> ```

启动采集（建议在 `docker exec -it` 终端跑，会**弹出 xterm 状态窗**实时显示帧数/状态）：

```bash
docker exec -it pika bash
source /home/dex/app/pika/pika_ros/install/setup.bash
ros2 launch data_tools run_data_capture.launch.py type:=multi_pika useService:=true \
    datasetDir:=/home/dex/agilex/data episodeIndex:=0 timeout:=100
```

| 参数 | 说明 |
|---|---|
| `useService:=true` | **夹爪快速夹两下**开始录制（推荐）；`false` 则键盘触发 |
| `datasetDir` | 数据目录，落 `episodeN`（每次触发自增 N） |
| `timeout:=100` | 单条最长录 100 秒 |

> 💡 录制时 **xterm 窗口实时显示**各传感器帧数；`config` 段**全为 1** 表示一切正常。误触发会产生近空 episode 目录，属正常。

**查看录了多少 / 质量 / 大小**（不依赖弹窗）：

```bash
cat ~/agilex/data/episode2/statistic.txt   # 首行=时长(秒)；topic 段=各流帧数@频率；config 段=各流是否录上(全1为好)
du -sh ~/agilex/data/episode2              # 体积
```

---

## 7. 数据同步

> 把各传感器按时间戳对齐，生成 `sync.txt`。

```bash
docker exec -it pika bash
source /home/dex/app/pika/pika_ros/install/setup.bash
ros2 launch data_tools run_data_sync.launch.py type:=multi_pika \
    datasetDir:=/home/dex/agilex/data/ episodeIndex:=-1     # -1=同步全部；或填某个 episode 号
```
> ✅ 成功后每个模态目录生成 `sync.txt`，**各 sync.txt 行数一致** = 同步帧数。

---

## 8. 数据重播 (可选)

用 `scripts/data_replay.py`（matplotlib 可视化播放器）回放**已同步**的 episode，直接读文件、不走 ROS，
弹窗显示：左右相机画面 + 3D 轨迹(左红右蓝) + 双夹爪距离曲线 + 信息栏。

```bash
docker exec -it pika bash
export DISPLAY=:1
python3 /home/dex/app/pika/pika_ros/scripts/data_replay.py /home/dex/agilex/data/episode2
```

> 💡 控制键：`空格`暂停 · `←/→`单帧 · `↑/↓`调速 · `Home/End`首末帧 · `R`重置视角 · `Esc`退出。
> 依赖 matplotlib + python3-tk（已在 §3.2 Dockerfile 预装）；需先完成 §7 同步（脚本要求各 `sync.txt` 行数一致）。

> [!NOTE]
> 另一种回放方式是 `ros2 launch data_tools run_data_publish.launch.py type:=multi_pika datasetDir:=... episodeIndex:=N`
> （把数据重新发布成 ROS topic，在 rviz/rqt_image_view 观看）；用前需先停掉实时传感器(§5.4)，否则 topic 会与实时数据冲突。

---

## 9. 日常使用速查

> 环境装好后，每天就这几步。

```bash
# ① 开机后（每次重启电脑）
docker start pika            # ⚠️ 启动常驻容器，不要用 docker_run.sh（那是重建会丢配置）
xhost +local:root            # 授权 GUI

# ② 基站若被移动 → 重新校准（见 §4，定位标签先开机=绿灯）

# ③ 启动全部传感器（一体化）
docker exec -it pika bash
cd /home/dex/app/pika/pika_ros/scripts && bash start_multi_sensor.bash

# ④ 采集（另开容器终端，弹 xterm 状态窗）
docker exec -it pika bash
source /home/dex/app/pika/pika_ros/install/setup.bash
ros2 launch data_tools run_data_capture.launch.py type:=multi_pika useService:=true \
    datasetDir:=/home/dex/agilex/data episodeIndex:=0 timeout:=100
#   → 夹爪双击开始录制

# ⑤ 同步
ros2 launch data_tools run_data_sync.launch.py type:=multi_pika \
    datasetDir:=/home/dex/agilex/data/ episodeIndex:=-1
```

---

## 10. 踩坑速查 (Troubleshooting)

| 现象 | 原因 / 解决 |
|---|---|
| `survive-cli` 卡在 `clearing position`，dongle 无数据 | ⚠️ **定位标签没开机**！长按夹爪顶部大头到绿灯。其次查 dongle 是否被别处(另一台开 SteamVR 的电脑)占用 |
| `acc err` 降不到 0.005 / 参考基站反复切 / 两台同频道 | **两台基站同频道冲突** → 戳一台改频道错开 |
| `docker pull` EOF / 超时 | Docker **守护进程**没配代理 → §2.2 (a) |
| build 时容器内 apt 失败 | 客户端代理没配 / 没加 `--network=host` → §2.2 (b) |
| 鱼眼崩 `_ARRAY_API not found` / cv_bridge 报错 | **本迁移镜像已固化 numpy 1.26.4，正常不会再遇到**；若自行环境里 numpy 被拉到 2.x → `pip install "numpy<2"` 重装(opencv 不必动) |
| 采集报 `FileNotFoundError: gnome-terminal` | 容器无 gnome-terminal → 装 `xterm` 并改 launch prefix（§6） |
| `LIBUSB_ERROR_BUSY` (Watchman) | 重复启动了定位器 → 只跑 `start_multi_sensor.bash`；或旧进程残留，按 PID 杀 |
| RealSense `serial ... NOT found` / `resource busy` | 序列号没改对(§5.3) / 旧 realsense 节点占用相机(按 PID 杀) |
| `/dev/video50` 等绑定不出现 | `udevadm trigger` 漏了 `--action=add`；或端口路径写错(§5.1) |
| 校准重启容器后丢失 | 没建 `libsurvive_config` 软链(§3.5) |
| GUI 弹窗不显示 | 宿主忘了 `xhost +local:root`（每次开机要重做） |
| 左右手数据错位 | §5.2 Sense 左右与 §5.1/§5.3 相机/串口左右不一致 → 对调修正 |

> [!TIP]
> 残留进程清理：`docker exec pika bash -lc 'ps -eo pid,comm | grep -E "locator|realsense|usb_camera|serial_gripper"'`
> 再按 PID `kill -9`（`pkill -f` 有时匹配不到，按 PID 最稳）。

---

<div align="center">

### 📦 附：本机实际部署值（参考，新机需重新获取 🔧）

| 项 | 值 |
|---|---|
| 左手 / 右手 Sense | `LHR-414376D8` / `LHR-50E5EE8C` |
| 基站频道 | `10` 与 `11` |
| D405 序列号（左/右） | `230322273597` / `230422273164` |
| 设备绑定 | 端口每次插拔都变,**以 `setup_hardware.sh` ② 实际查到为准**(不写死) |
| 代理 | 按本机实际(`env \| grep -i proxy`),本机当前 `127.0.0.1:7890` |

**🎉 至此，从安装到采集的全流程可在新机器完整复刻。**

</div>
