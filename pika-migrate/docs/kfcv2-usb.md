# KFCv2 USB 运行手册

KFCv2 只支持 USB UVC。采集节点固定使用 `/dev/kfcv2-camera`，不要配置 `/dev/videoN`，也不要配置相机 IP。

## 首次或硬件变化后

```bash
cd /home/kw/app/pika-migrate && bash setup_hardware.sh
```

- 选项 1 安装 Vive 与 KFCv2 udev 规则，并读取三帧 `3840x1080@30` MJPEG。
- 选项 2 绑定夹爪、鱼眼、D405 和 LHR。KFCv2 可以保持连接，不会被当作鱼眼。
- 选项 4 临时禁用头相机，只核对左右手映射。
- 零台或多台 capture-capable `1f3b:1021` 都会中止，不会自动猜测设备。

生成的硬件状态位于 `/home/kw/app/pika/pika_hardware.env`，属主应为 `kw:kw`。

## 日常采集

```bash
bash /home/kw/app/pika/pika_ros/scripts/start_collect.sh
```

脚本在进入采集前要求：稳定软链正确、设备未被旧进程占用、ROS publisher 恰好一个、能收到真实 `CompressedImage`，并且测得帧率不低于 25 FPS。之后仍使用原来的对齐窗口、左右拆图、episode、筛选与 HDF5 流程。

## 诊断

```bash
readlink -f /dev/kfcv2-camera
udevadm info -q property -n /dev/kfcv2-camera
v4l2-ctl -d /dev/kfcv2-camera --list-formats-ext
fuser /dev/kfcv2-camera
docker exec pika ros2 topic type /camera/kfc_compressed
docker exec pika ros2 topic info /camera/kfc_compressed
docker exec pika timeout 10 ros2 topic echo --once /camera/kfc_compressed sensor_msgs/msg/CompressedImage
docker exec pika timeout 8 ros2 topic hz --window 30 /camera/kfc_compressed
```

重插后 `/dev/videoN` 允许变化，但 `/dev/kfcv2-camera` 必须自动恢复。如果 `fuser` 显示占用，先确认没有正在采集，再使用：

```bash
bash /home/kw/app/pika/pika_ros/scripts/start_collect.sh stop
```

## 回滚

部署前备份保存在 `/home/kw/app/backups/kfcv2-usb-日期时间/`。先停止设备栈，人工确认要使用的精确备份目录，再把其中的文件复制回原路径并重新构建 `sensor_tools`。不要删除 `/home/kw/app/pika/pika_hardware.env` 或任何采集数据；需要替换硬件配置时，把旧文件移动到备份目录保留。

本次 USB-only 部署的精确备份目录是 `/home/kw/app/backups/kfcv2-usb-20260921-105335`。
