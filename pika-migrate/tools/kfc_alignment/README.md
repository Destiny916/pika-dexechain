# KFCv2 采集前画面对齐

这里是 `pika-migrate` 持有的标准对齐组件：

- `align_kfc_camera.py`：容器内运行的 ROS 2/OpenCV 实时叠加窗口。
- `align_before_capture.sh`：宿主机入口，由 `start_collect.sh` 调用。

`migrate_software.sh` 会把 Python 脚本安装到 `$PIKA_DIR`，并幂等地给
`start_collect.sh` 加入受管钩子。不要直接修改安装后的副本；修改本目录后重新运行迁移脚本。

每次启动时从 `KFC_ALIGN_REFERENCE_DIR` 的顶层选取创建时间最新的 `.jpg/.jpeg`；
默认目录为 `~/agilex/kfc_reference/`。文件系统不提供创建时间时回退到修改时间。

行为约定：关闭窗口表示确认；未收到实时帧或按 `Ctrl+C` 都会取消本次采集。
