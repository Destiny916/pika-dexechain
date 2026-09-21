# KFCv2 头相机与 HDF5 改造进度

本文用于后续清理上下文后的接续。当前目标已经收敛为：KFCv2 压缩图在采集过程中在线拆分并保存左右目，默认不保存原始拼接图；HDF5 采用“先存 PIKA raw，再采后离线转换”的路线。

## 当前目标

### KFCv2 头相机

KFCv2 后端不走 Python adapter，不把 `/camera/kfc_compressed` 解码成 `/camera_head/color/image_raw`。

目标链路：

```text
kfcv2_publisher
  -> /camera/kfc_compressed
  -> dataCapture 直接订阅 sensor_msgs/msg/CompressedImage
  -> episodeN/camera/color/pikaHeadCamera_l/*.jpg
  -> episodeN/camera/color/pikaHeadCamera_r/*.jpg
```

当前采集过程中在线拆分出左右目，默认 `640x360`；原始拼接图已关闭保存以节省空间。离线拆分脚本仍可用于旧数据或异常帧的修复工具。

Orbbec 旧头相机仍保留：

```text
usb_camera.py
  -> /camera_head/color/image_raw
  -> episodeN/camera/color/pikaHeadCamera/*.jpg
```

配置原则：`HEAD_CAMERA_DRIVER=kfcv2` 时，头部相机订阅 `/camera/kfc_compressed`，在线拆分到 `camera/color/pikaHeadCamera_l` 和 `camera/color/pikaHeadCamera_r`，默认不落盘 `camera/color/pikaHeadCamera`。不能混用 Orbbec 的 `/camera_head/color/image_raw`。

### HDF5

不做在线 HDF5 采集器。流程保留为：

```text
先保存 PIKA raw episode
采集结束后可选调用 raw_to_hdf5 脚本转换
```

HDF5 文件格式尚未给出，因此当前只预留钩子，不实现具体转换格式。转换失败不应破坏 raw 数据。

## 当前编辑位置

当前实现位于：

```text
/home/agilex/app/pika
```

说明：当前迁移测试项目已经落在 `/home/agilex/app/pika`；本机原生背包环境是另一套目录 `/home/agilex/pika_ros`。两者代码目录不同，但会共享宿主机全局资源，例如 `/etc/udev/rules.d`、`/dev/ttyUSB50`、`/dev/video50`、`/opt/dexe_sensors` 和 Docker 容器名。

## 已实现

### dataCapture 直接订阅并在线处理 CompressedImage

文件：

```text
pika_ros/src/data_tools/include/dataUtility.h
pika_ros/src/data_tools/src/dataCapture.cpp
```

新增内容：

- 新增 `dataInfo.camera.compressed.*` 参数。
- 新增 `sensor_msgs/msg/CompressedImage` 订阅。
- KFC compressed 订阅使用 `best_effort + volatile` QoS，匹配 KFC 示例订阅方式。
- ROS 回调只把 `CompressedImage` 放入队列；独立保存线程执行 JPEG 解码、左右拆分、resize 和编码，避免阻塞订阅回调。
- 当前 `saveOriginal: false`，不写原始拼接 JPEG；左右眼保存路径为：

```text
episodeN/camera/color/<name>_l/*.jpg
episodeN/camera/color/<name>_r/*.jpg
```

KFC 配置下 `<name>` 为 `pikaHeadCamera`，因此最终目录为 `pikaHeadCamera_l/r`。

### KFCv2 专用采集配置

新增：

```text
pika_ros/src/data_tools/config/multi_pika_kfcv2_data_params.yaml
pika_ros/install/data_tools/share/data_tools/config/multi_pika_kfcv2_data_params.yaml
```

该配置中：

- `camera.color` 只包含 D405 左右 RGB 和鱼眼左右 RGB 四路。
- 不包含 `/camera_head/color/image_raw`。
- `camera.compressed.names: ['pikaHeadCamera']`
- `camera.compressed.topics: ['/camera/kfc_compressed']`
- `camera.compressed.onlineSplit: true`、`saveOriginal: false`（已完成第一版验证，当前不再保存原始拼接图）
- `splitWidth: 640`、`splitHeight: 360`、`jpegQuality: 95`

原 `multi_pika_data_params.yaml` 保留 Orbbec 头相机路径，兼容旧头相机。

### sensor launch 支持可配置头相机

文件：

```text
pika_ros/src/sensor_tools/launch/open_multi_sensor.launch.py
pika_ros/install/sensor_tools/share/sensor_tools/launch/open_multi_sensor.launch.py
```

新增 launch 参数：

```text
head_camera_driver: orbbec | kfcv2 | none
head_camera_port
head_camera_ip
```

行为：

- `orbbec`：启动 `sensor_tools/usb_camera.py`，发布 `/camera_head/color/image_raw`。
- `kfcv2`：启动 `kfcv2/kfcv2_publisher`，参数 `video_index:=<head_camera_ip>`，发布 `/camera/kfc_compressed`。
- `none`：不启动头相机节点。
- 不启动 adapter。

### 启动脚本读取 runtime 配置

文件：

```text
pika_ros/scripts/start_multi_sensor.bash
pika_ros/src/sensor_tools/scripts/start_multi_sensor.bash
pika_ros/install/sensor_tools/share/sensor_tools/scripts/start_multi_sensor.bash
```

会读取：

```text
$PIKA_DIR/pika_runtime.env
```

KFCv2 模式会先 source：

```text
/opt/dexe_sensors/install/setup.bash
```

然后把 `head_camera_driver/head_camera_ip/head_camera_port` 传给 launch。

### run_pika 自动选择采集配置

文件：

```text
pika_ros/scripts/run_pika.sh
```

行为：

- 读取 `pika_runtime.env`。
- `HEAD_CAMERA_DRIVER=kfcv2` 时默认 `DATA_TYPE=multi_pika_kfcv2`。
- 其他情况默认 `DATA_TYPE=multi_pika`。
- 默认健康检查阈值：

```text
orbbec: CAPTURE_HZ=20
kfcv2: CAPTURE_HZ=10
```

可用环境变量覆盖 `DATA_TYPE` 和 `CAPTURE_HZ`。

已预留采后 HDF5 钩子：

```bash
ENABLE_HDF5_CONVERT=true
HDF5_CONVERT_SCRIPT=/path/to/raw_to_hdf5.sh
```

脚本会在 episode 生成后对新 episode 调用：

```bash
bash "$HDF5_CONVERT_SCRIPT" "$DATASET_DIR/episodeN"
```

### start_collect 一键流程适配

文件：

```text
pika_ros/scripts/start_collect.sh
```

行为：

- 读取 `pika_runtime.env`，不再硬编码 `/home/dex`。
- 启动设备栈时把 `HEAD_CAMERA_DRIVER/HEAD_CAMERA_IP/HEAD_CAMERA_PORT/CAPTURE_HZ` 传入容器。
- 健康检查按后端分支：
  - `kfcv2` 检查 `/camera/kfc_compressed` publisher。
  - `orbbec` 检查 `/camera_head/color/image_raw` publisher。
  - `none` 跳过头相机检查。
- 停设备栈时会清理 `kfcv2_publisher`。

### Docker 和迁移配置

文件：

```text
docker_run.sh
pika_migrate.conf
migrate_software.sh
setup_hardware.sh
```

当前状态：

- `docker_run.sh` 读取 `pika_runtime.env`，挂载配置路径和数据路径，并挂载：

```text
/opt/dexe_sensors:/opt/dexe_sensors:ro
```

- `pika_migrate.conf` 支持配置用户、路径、Docker/ROS、头相机后端、KFC IP、采集 Hz、HDF5 后处理开关。
- `migrate_software.sh` 在交互式终端运行时会先让用户选择头相机后端：`kfcv2`、`orbbec` 或 `none`；非交互运行时继续使用 `pika_migrate.conf`/环境变量。
- `migrate_software.sh` 会生成 `$PIKA_DIR/pika_runtime.env`。
- 只有选择 `HEAD_CAMERA_DRIVER=kfcv2` 时才会安装/校验 KFCv2 `dexe-sensors` deb；选择 `orbbec` 或 `none` 会跳过该依赖安装。
- `migrate_software.sh` 已扩展路径修复：除 `/home/dex` 外，还会修复旧包中的 `/home/ppn/pika_ros -> $PIKA_DIR/pika_ros`，这对跨机迁移和后续 colcon build 很关键。
- `setup_hardware.sh` 会检查 KFCv2 deb、`/opt/dexe_sensors`、`192.168.20.x` 网段和相机 IP 可达性。

## 已验证

### KFCv2 ROS 链路

已在本机验证：

```bash
source /opt/ros/humble/setup.bash
source /opt/dexe_sensors/install/setup.bash
export ROS_DOMAIN_ID=42
ros2 run kfcv2 kfcv2_publisher --ros-args -p video_index:=192.168.20.30
```

结果：

```text
主机网口: 192.168.20.20/24
相机 IP: 192.168.20.30
ping: 成功
topic: /camera/kfc_compressed
type: sensor_msgs/msg/CompressedImage
rate: 约 30Hz
```

这只证明本机能启动 KFC publisher 并收到 KFC compressed topic，不等于 PIKA episode 采集已经端到端通过。

### 本机原生背包环境保护检查

2026-07-08 在本机确认：

```text
原生背包环境: /home/agilex/pika_ros
迁移测试环境: /home/agilex/app/pika/pika_ros
```

两套代码目录不同，迁移项目不会直接覆盖 `/home/agilex/pika_ros`。但硬件绑定脚本会写宿主机全局 udev 规则，已经实际触发过冲突。

已确认原本存在的规则：

```text
/etc/udev/rules.d/sensor_serial.rules
/etc/udev/rules.d/sensor_fisheye.rules
```

迁移流程新增/复制过的规则：

```text
/etc/udev/rules.d/pika-sensor-bind.rules
/etc/udev/rules.d/99-orbbec-head.rules
/etc/udev/rules.d/81-vive.rules
```

其中 `pika-sensor-bind.rules` 会生成同名软链 `/dev/ttyUSB50`、`/dev/ttyUSB51`、`/dev/video50`、`/dev/video51`，并且曾与原规则左右相反，导致两个软链一度指向同一个真实设备。

当前已将迁移新增/复制的三份 active 规则移到：

```text
/home/agilex/app/pika-migrate/udev_rules_disabled_20260708_212039/
```

当前 active 规则只剩原生环境两份：

```text
/etc/udev/rules.d/sensor_serial.rules
/etc/udev/rules.d/sensor_fisheye.rules
```

当前软链恢复为不同真实设备：

```text
/dev/ttyUSB50 -> ttyUSB4
/dev/ttyUSB51 -> ttyUSB5
/dev/video50  -> video14
/dev/video51  -> video24
```

结论：在这台已有原生背包环境的机器上，不要再跑迁移包 `setup_hardware.sh` 的手柄绑定阶段，除非明确要重写全局 udev 规则。KFCv2 网络相机不需要这套 USB 绑定规则。

### 原生 setup_device.py 当前失败原因

用户反馈原生背包自己的绑定流程报错：

```text
Unknown device "/sys/bus/usb/devices/3-2.3.3": No such device
左侧定位标签序列号获取失败
```

检查 `/home/agilex/pika_ros/scripts/setup_device.py` 后确认，该脚本默认写死：

```text
left_loc_usb  = 3-2.3.3
right_loc_usb = 3-1.3.3
```

当前内核只枚举到一个 LHR：

```text
3-1.3.3 product=LHR serial=LHR-881ED31D vid=28de pid=2300
```

`3-2.3` 当前只是 USB2 hub，其下没有 `3-2.3.3` 这个 LHR 子设备。因此这是定位标签 USB 枚举/在线状态问题，不是 KFCv2 代码链路问题，也不是当前 active udev 规则残留导致。后续若要排查，应检查另一只定位标签是否开机、接收器/线缆/Hub 是否枚举、是否换了 USB 拓扑。

### 静态检查

已通过：

```text
bash -n start_multi_sensor.bash
bash -n run_pika.sh
bash -n start_collect.sh
bash -n docker_run.sh
bash -n migrate_software.sh
bash -n setup_hardware.sh
python3 -m py_compile open_multi_sensor.launch.py run_data_capture.launch.py
```

### 编译检查

已完成：

```bash
source /opt/ros/humble/setup.bash
source /tmp/pika-project-compressed-edit/pika/pika_ros/install/setup.bash
colcon build --packages-select data_tools \
  --build-base /tmp/pika-kfc-build-project-install-2 \
  --install-base /tmp/pika-project-compressed-edit/pika/pika_ros/install \
  --cmake-args -DCMAKE_BUILD_TYPE=Release
```

结果：

```text
data_tools 编译并安装成功。
只有既有 PCL deprecation / system("clear") 警告。
```

说明：为了避免 colcon hook 中记录临时路径，编译后已把文本中的临时路径规范化回 `/home/dex/app/pika/pika_ros`，迁移脚本会按目标机器路径再替换。

## 端到端验证

PIKA 真实设备数采流程已经跑通：

- `start_collect.sh` 能启动完整设备栈和 KFCv2 publisher。
- 通过双击夹爪能够开始和结束 episode，相关 service remapping 回归已修复。
- `/camera/kfc_compressed` 约 30 FPS，在线拆分线程没有持续积压。
- 重启采集并启用 `saveOriginal: false` 后，episode 只保存左右眼：

```text
episodeN/camera/color/pikaHeadCamera_l/*.jpg
episodeN/camera/color/pikaHeadCamera_r/*.jpg
```

- 左右眼文件按输入时间戳对应，输出尺寸为 640×360；不再生成原始拼接 JPEG。

## 2026-08-26：KFC topic 可发现但宿主机收不到数据

### 现象与定位

在 `pika` 容器内以 `root` 单独启动 `kfcv2_publisher` 后：

- ROS domain 42 上能发现 `/camera/kfc_compressed`，`Publisher count: 1`；
- 容器内 `root` 执行 `ros2 topic hz` 能稳定收到约 `30.3 Hz`；
- 宿主机 `dex`（UID 1000）只能发现 topic，`ros2 topic hz` 收不到消息；
- 容器内改用 UID 1000 订阅同样收不到消息。

根因是 Fast DDS 在同机通信时优先使用 `/dev/shm`。容器内 `root` publisher 创建的共享内存对象归 `root:root`，宿主机 UID 1000 的订阅者可以通过 DDS discovery 发现 endpoint，但不能正常接收图像 payload。因此“能看到 topic”不等于“能收到数据”。

### 已验证的临时处理

将独立 KFC publisher 改为 UID/GID 1000 运行后，宿主机 domain 42 已验证：

```text
/camera/kfc_compressed
format: jpeg
rate: about 30.3 Hz
```

该独立实例的运行目录为容器内 `/tmp/kfcv2-standalone/`，日志为 `node.log`。容器重启后不会自动恢复。

### 对正式数采的影响

正式 `start_collect.sh` 不复用上述独立实例。它会先按 `CHILD_PATTERN` 清理残留的 `kfcv2_publisher`，然后在 `pika` 容器内以默认用户 `root` 启动完整设备栈；`run_pika.sh` 启动的数据采集节点也在同一容器内以 `root` 运行。因此 KFC publisher 到落盘订阅者是 `root -> root`，不会触发本次跨 UID 的共享内存权限问题。

仍需注意：

- 正式数采启动 root publisher 后，宿主机 `dex` 直接订阅仍可能出现“topic 存在但没画面”；采集前对齐工具因此在数采容器内直接订阅原始压缩 topic；
- 当前 KFC 健康检查只验证 publisher 数量，但强制执行的采集前对齐必须实际收到至少一帧，否则不会进入本次采集；
- 以后仍应把健康检查升级为在数采容器内实际接收至少一帧 `CompressedImage`。

建议的数采前 payload 检查：

```bash
docker exec pika bash -lc '
  source /opt/ros/humble/setup.bash
  source /opt/dexe_sensors/install/setup.bash
  export ROS_DOMAIN_ID=42
  timeout 5 ros2 topic echo --once \
    /camera/kfc_compressed \
    sensor_msgs/msg/CompressedImage \
    --field format
'
```

期望输出 `jpeg`。后续待办：把等价检查加入 `start_collect.sh::health_check()`。

## 下一步建议

数采功能和 `saveOriginal: false` 实采验证已完成。下一步刷新迁移包内的 `pika-project.tar.gz`；不要直接覆盖半写包，建议先写新文件、校验后再原子替换：

```bash
cd /home/agilex/app/pika-migrate
tar -czf pika-project.tar.gz.new -C /home/agilex/app pika
mv pika-project.tar.gz pika-project.tar.gz.prev
mv pika-project.tar.gz.new pika-project.tar.gz
```

打包后应检查归档同时包含新 `dataCapture` 二进制、KFCv2 配置、采集入口和画面对齐接入，并在临时目录做一次解包完整性检查。

## 打包迁移目录

若只需要把当前 `pika-migrate` 整体发给下一台机器，并且包含镜像包、项目包和 KFC deb，建议在父目录执行：

```bash
cd /home/agilex/app
tar --exclude='pika-migrate/pika-project.tar.gz.bak' \
    --exclude='pika-migrate/pika-project.tar.gz.prev' \
    --exclude='pika-migrate/udev_rules_disabled_*' \
    -czf pika-migrate-$(date +%Y%m%d_%H%M%S).tar.gz pika-migrate
```

如果只想打“脚本和文档”，不带大镜像/项目包/deb：

```bash
cd /home/agilex/app
tar --exclude='pika-migrate/pika-image.tar.gz' \
    --exclude='pika-migrate/pika-project.tar.gz*' \
    --exclude='pika-migrate/dexe-sensors_*.deb' \
    --exclude='pika-migrate/udev_rules_disabled_*' \
    -czf pika-migrate-light-$(date +%Y%m%d_%H%M%S).tar.gz pika-migrate
```
