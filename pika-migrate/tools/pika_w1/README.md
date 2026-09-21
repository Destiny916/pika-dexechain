# pika-w1 deploy

部署命令负责把相机运行载荷安全部署到目标机；运行控制命令负责启停相机节点。

```bash
# 只在本地构建、检查载荷
bash tools/pika_w1/pika-w1 deploy all --dry-run

# 实际部署；每台机器输入一次 SSH 密码
bash tools/pika_w1/pika-w1 deploy pc1
bash tools/pika_w1/pika-w1 deploy pc2
# 或依次部署两台
bash tools/pika_w1/pika-w1 deploy all

# 运行控制（使用各自 current release，不会按进程名误杀 W1）
bash tools/pika_w1/pika-w1 start pc1
bash tools/pika_w1/pika-w1 stop pc1
bash tools/pika_w1/pika-w1 status pc1
bash tools/pika_w1/pika-w1 start pc2
bash tools/pika_w1/pika-w1 stop pc2
bash tools/pika_w1/pika-w1 status pc2
```

目标：

- PC1：`dexforce@192.168.20.20`
- PC2：`dexforce@192.168.20.21`
- 安装根目录：`/home/dexforce/workspace/pika_w1`

远端采用内容哈希版本目录：

```text
~/workspace/pika_w1/
├── releases/<role>-<hash>/
├── current -> releases/<role>-<hash>
├── config/
├── logs/
└── run/
```

PC1 的 ARM64 deb 使用 `dpkg-deb -x` 解到 release 内部，不执行 `dpkg -i`，不会修改
`/home/dexforce/w1` 或系统 dpkg 状态。

PC2 部署前要求系统已有 ROS 2 Humble，并检查：`v4l2-ctl`、OpenCV、rclpy、cv_bridge、
tf2_ros、`compressed_image_transport` 和 NumPy < 2。缺失时部署会逐项列出缺少的命令、
ROS 包或 Python 模块，并打印可直接复制的 `apt-get` 安装命令；部署不会擅自执行 sudo，
也不会切换 `current`。系统依赖建议在 PC2 预装：

```bash
sudo apt-get install -y v4l-utils python3-opencv \
  ros-humble-cv-bridge ros-humble-compressed-image-transport
```

主机、路径或载荷位置可编辑 `config.env`，也可通过同名环境变量临时覆盖。
