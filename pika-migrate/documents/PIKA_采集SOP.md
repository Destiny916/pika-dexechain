# Pika Sense 数据采集 SOP(Docker 环境版)

> 适用:本机 Docker 化部署的 AgileX Pika Sense 双手持采集套件。
> 改编自松灵「Pika 部署于双臂」SOP,已替换为我们的路径 / Docker 命令 / `run_pika.sh`。
>
> **环境前提**:容器 `pika` 已构建;基站、定位标签、两只 Sense、两台 D405 已就位。
> **路径约定**:项目根 `/home/dex/app/pika`,数据落 `/home/dex/agilex/data/<任务名>/episodeN`。

---

## 全流程一览

```
0. 进容器  →  1. 环境检查+基站校准  →  2. 启动设备  →  3. 采集(run_pika.sh)
                                                              ↓
            5. UMI workflow 生成 HDF5  ←  4. UniVis / screen 快速复核  ←┘
```

不需要松灵的:`run_pika.sh`(松灵原版,我们用自己封装的同名脚本)、导出方案一脚本(那是松灵内部仓库)。

---

## 🚀 日常一键采集(推荐,等价于第 0~3 步)

**宿主机**一条命令,从开机到进采集循环,退出自动清理:
```bash
bash /home/dex/app/pika/pika_ros/scripts/start_collect.sh
```
头部相机后端可配置:
```bash
# 默认:Orbbec Dabai DC1(/dev/video52)
bash /home/dex/app/pika/pika_ros/scripts/start_collect.sh

# KFCv2 网络头相机(压缩图模式,相机 IP 固定为 192.168.20.30)
HEAD_CAMERA_DRIVER=kfcv2 HEAD_CAMERA_IP=192.168.20.30 \
  bash /home/dex/app/pika/pika_ros/scripts/start_collect.sh

# 无头相机/排查
HEAD_CAMERA_DRIVER=none bash /home/dex/app/pika/pika_ros/scripts/start_collect.sh
```
它自动做(失败会停下提示,不会硬闯):
1. `docker start pika` + `xhost +local:root`
2. **选/建本次任务**:列出已有任务让你选编号,或按 `n` 新建——数据按任务分目录存(详见下方说明)
3. **校准自动判定**:定位已解算达标(acc err<0.005)就跳过;否则引导 `--force-calibrate`
4. 后台起设备栈(日志 `docker exec pika cat /tmp/multi_sensor.log`)
5. **健康自检**(四软链 + `pika_pose_l/r` 定位节点 + 相机 topic)——代替每天挥手核对
6. 若使用 **KFCv2**，每次按回车启动采集前都会弹出画面对齐窗口：实时画面按标准图尺寸 resize，并与标准图幽灵叠加；调整完成后关闭窗口才继续。未收到实时帧时不会启动采集。Orbbec/none 自动跳过。
7. 进采集循环:**双击夹爪**录制;每条采完按 `[回车]` 采下一条、`输入文字+回车` 带语言标注、`q` 退出

KFCv2 对齐每次都会从 `KFC_ALIGN_REFERENCE_DIR` 顶层选取创建时间最新的 `.jpg/.jpeg`；
默认目录是 `~/agilex/kfc_reference/`。放入新参考图后，下次启动采集会自动使用，无需重新迁移。

退出方式:循环里 `q` 或 `Ctrl+C` → **自动停设备栈、放 dongle**(trap 清理,不留孤儿)。
只想停设备栈:`bash start_collect.sh stop`。

### 📁 按任务分目录采集(避免不同任务/配置混在一起)

数据不再全平铺在 `data/` 下,而是**按任务分子目录**:`data/<任务名>/episodeN`。
每个任务**独立编号(各自从 episode0 起)、独立统计(`.run_pika_stats.tsv`)、独立质检**,互不干扰。

- **怎么选任务**:`start_collect.sh` 启动后会列出已有任务,输入编号复用,或按 `n` 新建。
  - 优先**从已有任务里选**,避免 `叠衣服`/`fold`/`fold_clothes` 同义异名把一个任务拆成多个目录。
- **任务命名规范**:只允许 **英文/数字/下划线/连字符**(如 `fold_clothes`、`market_bottle_01`)。
  不允许中文/空格——路径要经 `ros2 launch datasetDir:=` 传进容器给 C++ 采集程序,中文/空格有编码与解析风险。
- **数据落点**:`/home/dex/agilex/data/<任务名>/episodeN`,采完自动 chown 回 `dex`(不会被 root 锁)。
- **存量数据**:迁移前的 150 条旧数据已归档到 `data/market_bottle_old/`。
- **采后筛查**:`start_collect.sh` 退出时使用 `pika-migrate/screen_episodes.py`
  触发项目内筛查脚本；阈值已和 EmbodiChain raw precheck 的核心流连续性判断对齐，
  该结果用于现场快速复核，上传前仍以 UMI workflow 报告为准。
- **UniVis 浏览**:新迁移包使用 DexEChain 工具容器启动 UniVis，默认 raw workspace 指向
  **数据总根** `/home/dex/agilex/data`。启动命令见第 4 步。

> **什么时候用下面的手动流程**:一键脚本报错要排查、或换了设备/重插后要做**左右核对**(走
> `setup_hardware.sh ④`,日常一键里不含)、或想理解每步原理。日常顺利时用上面一条就够。

---

## 第 0 步:进入容器(手动流程 / 排查用)

```bash
# 宿主机执行
docker start pika            # 已在跑(docker ps 能看到)就跳过
xhost +local:root            # 允许容器内 GUI(rviz/rqt/realsense)连宿主 X
docker exec -it pika bash    # 进容器,之后所有命令都在容器里
```
> ⚠️ 不要用 `docker_run.sh` 来"开机启动" —— 那会**重建**容器、丢掉容器内配置。日常只用 `docker start pika`。

### 重要:一个容器,开多个终端(不是开多个容器!)

采集时要同时跑「启动设备」和「采集」两件事,需要**两个终端**。但**只有一个容器** `pika`,
两个终端都用 `docker exec` 进**同一个容器**——它们共享同一套进程、ROS 话题、设备、网络,
ROS 节点之间才能互相通信。

```bash
# 宿主机开第 1 个终端窗口:
docker exec -it pika bash      # → 跑「启动设备」(第 2 步),挂着别关

# 宿主机再开第 2 个终端窗口:
docker exec -it pika bash      # → 跑「采集」(第 3 步)
```
要几个终端就 `docker exec -it pika bash` 几次(校准/定位/相机/采集各占一个都行)。

> ❌ **千万别开第二个容器**(比如又跑 `docker_run.sh`)。两个容器是隔离的,ROS 节点互相
> 看不到对方的话题,采集就收不到数据。**永远是:一个容器 `pika` + 多个 `docker exec` 终端。**

---

## 第 1 步:环境检查 + 基站校准

### 1.1 环境检查(肉眼)
- [ ] 周围无其他红外设备(如某些深度相机、红外遥控)
- [ ] 无强烈太阳光直射
- [ ] 基站工作视角内无镜面 / 玻璃反射(必要时用黑布挡)
- [ ] 接收器与基站、Sense 与基站之间**无遮挡**

### 1.2 上电
- [ ] 两台基站插电(**频道 10 / 11 不同**,同频道会定位乱跳)
- [ ] **长按定位标签电源键到绿灯** —— 大头中间那个按钮,**不是夹爪!**
      (这是反复栽过的坑:只亮夹爪绿灯没用,定位标签不亮 dongle 收不到数据)

### 1.3 校准
```bash
# 容器内(若 .bashrc 没配 LD_LIBRARY_PATH,先 export 一行,否则 survive-cli 会 cannot open shared object)
export LD_LIBRARY_PATH=/home/dex/app/pika/pika_ros/install/libsurvive/lib:$LD_LIBRARY_PATH
cd /home/dex/app/pika/pika_ros/install/libsurvive/bin && ./survive-cli
```
- **基站没挪过** → 用上面这条普通模式,确认定位不漂即可(校准已持久化在 `libsurvive_config`)
- **基站被碰/移动过,或坐标在飘** → 改用强制重标:
  ```bash
  ./survive-cli --force-calibrate
  ```
  等每轮 **acc err < 0.005**,期间 Sense 保持**完全静止**,达标后 **Ctrl+C** 结束。
  启动设备栈后，在 RViz 里移动左右夹爪，确认定位轨迹丝滑连续、不跳变不卡顿。

**成功标志(全到齐才算好)**:
```
Got OOTX packet 11 1e8bddb6      # 两台基站各一行,频道不同(如 11/10)
Got OOTX packet 10 e56cd637
Global solve ... acc err 0.0007  # 每台 acc err < 0.005
```

**卡住排查(常见,不是报错)**:若一直刷 `OOTX not set` / `OOTX Decoder: Bad sync bit`、
**迟迟不出 `Got OOTX packet`** = 基站信号没解出来(收得到光、解不出标定):
- `OOTX not set ... attaching ootx decoder`、`Preamble found` 都是**正常中间态**,别被吓到;
- 真正要治的是 `Bad sync bit` 死循环 → 按概率调:**① 大头离基站太远/角度偏/被遮挡**(拿近、正对、清遮挡)
  → **② 反光面**(玻璃/金属/强反射墙,移开或挡黑布)→ **③ 阳光/其他红外**(拉窗帘、关红外设备)
  → **④ 大头在动**(必须完全静止)→ **⑤ 基站没撕膜/镜头脏**;通常是反光/遮挡/距离。

---

## 第 2 步:启动设备(在【终端1】,跑起来后别关)

```bash
# 终端1(docker exec 进 pika)—— 日常只需这一条(设备绑定已由宿主机 udev 固定,不用每次跑 setup_device)
cd /home/dex/app/pika/pika_ros/scripts/ && bash start_multi_sensor.bash
rqt    # 或 rviz,用来核对(可在终端1之外再 exec 一个终端开 rqt)
```

> ⚠️ **不要每次跑 `setup_device.py`!** 它是交互式绑定向导(要求一次只插一个串口设备),
> 我们这套 Docker 部署是用**宿主机 udev 规则**(`pika-sensor-bind.rules`)按物理端口固定绑定的,
> `ttyUSB50/51`、`video50/51` 开机即在。`setup_device.py` 只在**绑定真出问题**(左右手反、设备认不到)
> 时才考虑,且我们一般是去改宿主机 udev 规则而非用这个工具。误跑了直接 Ctrl+C 退出即可。

### 启动后必查两项
1. **左右手图像对不对(有没有反)** —— rqt 里看两路鱼眼图像。
   反了 → 一般是宿主机 udev 端口绑定问题,改 `pika-sensor-bind.rules` 的左右端口后重载;
   (不建议用 `setup_device.py`,那是另一套绑定机制,会和 udev 规则冲突。)
2. **坐标会不会漂** —— rviz 里看左右手坐标系;小幅度动夹爪若导致坐标**疯狂漂移**:
   → 回第 1 步 `--force-calibrate` 重标;**频繁出现说明基站摆位不行**,要重新摆基站。

---

## 第 3 步:采集(在【终端2】,终端1 的设备保持运行)

```bash
# 宿主机另开一个窗口 → docker exec -it pika bash → 进同一个容器
cd /home/dex/app/pika/pika_ros/scripts/
bash run_pika.sh                 # 采下一条
bash run_pika.sh "pick up cup"   # 顺带带语言标注(可选,实验性)
```

脚本自动做 5 件事(对齐松灵 run_pika.sh):
1. **删残缺目录**(pose 帧为 0 的死 episode)
2. **自动选号**(在现有数据后 append,自己算下一个 episode 号)
3. **启动采集**(自动 source 环境 + 起 ROS 采集节点)
4. **采集后体检**(打印这条 pose 帧数,残缺会提示重录)
5. **归还数据属主**(容器内是 root,写出的数据宿主侧默认 root 属主、宿主用户删不动;
   采完自动 `chown` 回宿主用户。属主从数据根目录自动推断,无需配置)

### 操作要点
- **双击夹爪**开始录制,再**双击**结束。
- **采集结束 = 先双击停录(存盘)→ 再 Ctrl+C(结束采集节点)→ PikaCapture 窗口 3 秒自动关**(不用按回车)。
  顺序别反:先双击停、后 Ctrl+C;别用 Ctrl+C 去停正在录的(会存成残缺被自动删)。
  (采集节点是常驻 service,录完不自退,靠 Ctrl+C 结束 run_pika 才能体检——这是松灵设计,正常。)
- 初始姿态尽量贴近参考初始位置,遵循数据协议。
- **段错误**(松灵采集脚本通病:双击开始/结束时偶发):直接**重跑** `bash run_pika.sh`
  —— 它会先把崩掉的残缺目录删掉,再用同一个号重来。
- xterm 弹窗会实时显示各话题帧率;`config` topic 所有状态应为 **1**。

### ⚠️ 关于 `timeout`(易误解,已查证源码)
- 它**不是**采集总时长,是**掉频容忍秒数**(单位:秒)。
- 含义:某话题实际帧率持续 `<=` 期望 hz(默认 20)超过 `timeout` 秒 → 节点判 `fail` → **直接中断采集**。
- 松灵默认仅 2 秒(很严,正常采集偶尔抖一下就可能被掐),脚本里用**验证过的 100**(放宽)。
- 想让"传感器真掉线尽快报错"可调小:`TIMEOUT=10 bash run_pika.sh`(代价:偶发掉帧也会中断)。

### 其他可调参数
```bash
DATASET_DIR=/path bash run_pika.sh    # 换数据目录(默认 /home/dex/agilex/data)
MIN_POSE=20 bash run_pika.sh          # pose 少于 20 帧也算残缺会被删(默认 1,只删 0 帧的)
DATA_OWNER=1000:1000 bash run_pika.sh # 强制数据属主(默认自动从数据根目录推断;一般不用设)
```

> **数据属主(权限锁)说明**:容器以 root 运行,采集写出的文件在宿主侧默认属 `root:root`,
> 宿主普通用户(dex)删不动/改不动。`run_pika.sh` 采完会自动把新数据 `chown` 回宿主用户,
> 无需手动处理。**若有早期遗留的 root 数据**(脚本更新前采的),在宿主侧一次性解锁:
> ```bash
> sudo chown -R dex:dex /home/dex/agilex/data    # 在宿主机执行,非容器内
> ```

---

## 第 4 步:UniVis 实时质量检查

UniVis 由软件轨安装的 DexEChain 工具容器 `dexechain-tools` 启动。它和 PIKA 采集容器分离，
但共享宿主机 `/home/dex/agilex/data`。

```bash
# 若服务没开,宿主机执行:
cd /home/dex/app/pika-migrate
bash start_dexechain_tools.sh univis
```
浏览器打开 **http://127.0.0.1:8010**。raw workspace 默认是 `/home/dex/agilex/data`。

### 采一条看一条,重点查:
1. **有没有无法解析的 episode** —— 目录里有、`run_pika.sh` 也没自动删掉的,大概率是
   采到一半 pose 信息丢了。
2. **轨迹有没有剧烈抖动** —— 尤其是和图像对不上的抖动,肉眼扫一遍。
3. (自动可达性检查:UniVis 后续支持,coming soon)

> 本地快速回放(可选):`python /home/dex/app/pika/pika_ros/scripts/data_replay.py /home/dex/agilex/data/<任务名>/episodeN`

---

## 第 5 步:导出 HDF5 / UMI workflow

推荐生产链路改为使用 DexEChain UMI workflow 生成 HDF5，UniVis 主要用于可视化和人工复核。

`pika-migrate` 在数采侧只是 EmbodiChain workflow 的使用者：它负责启动处理容器、
生成本次输入/输出路径并调用仓库里的 YAML 模板，不维护 workflow 阈值、放行策略、
相机格式兼容或数据修复逻辑。发现 EmbodiChain workflow 存在功能缺陷时，应按
“采集场景 + raw 数据现象 + workflow 报告/错误”的方式反馈给 EmbodiChain 侧修复，
不要在 `pika-migrate` 里无限堆兼容分支。

```bash
cd /home/dex/app/pika-migrate

# 一键 raw_checker + raw_to_hdf5。调用 EmbodiChain run_workflow.sh；
# 覆盖 inputs/output_dir，并按 HEAD_CAMERA_DRIVER 映射 head_camera_format。
bash start_dexechain_tools.sh raw2hdf5 /home/dex/agilex/data/<任务名>
```

不指定输出目录时，默认会生成一次独立 run：
`/home/dex/agilex/hdf5_workflow/<任务名>_YYYYMMDD_HHMMSS`。
输入单条 episode 时为：
`/home/dex/agilex/hdf5_workflow/<任务名>_<episodeN>_YYYYMMDD_HHMMSS`。

基础 HDF5 不再额外平铺到 `hdf5/` 目录；上传使用：
`<output_dir>/<任务名>/*.hdf5`。
UniVis 的 HDF5 adapter 也应打开这个实际包含 `.hdf5` 文件的目录。
预检报告在：
`<output_dir>/stages/raw_checker/<任务名>/quick_report.txt`。

如果后续要继续跑完整 trainable workflow，最终 HDF5 默认在 workflow 输出目录的
`<batch>/` 下。详见 DexEChain 仓库：
`docs/source/overview/vla/umi_workflow.md`。

---

## 常见问题速查

| 现象 | 原因 | 处理 |
|---|---|---|
| survive-cli 卡住 / 无数据 | **定位标签没开**(只亮了夹爪绿灯) | 长按定位标签电源键到绿灯 |
| 定位坐标乱跳 | 两台基站同频道 | 改成 10 / 11 不同频道 |
| 坐标漂移、动一下夹爪疯狂飘 | 基站被移动 / 摆位差 | 关相机进程 → 回第 1 步 `--force-calibrate`;频繁则重摆基站 |
| `pika_pose_l`/`pika_pose_r` 帧数为 0(单边) | 该侧大头定位器掉线(没电/休眠/被遮挡/dongle 掉) | 充电+开机到绿灯;看端口枚举(见附录 A);采集中别挡住大头看基站 |
| 采集中途定位/相机一起掉、USB 反复 disconnect | **多个设备挤在同一个 USB hub,带宽/供电不够** | **把设备分到不同 USB 控制器/口**,别共用一个 hub;改完按附录 B 重绑 udev |
| RealSense `serial NOT found` / 只认到一台 D405 | 两台 D405 挤带宽,或没插稳 | 分到不同 USB3 口,`rs-enumerate-devices -s` 确认两台都在(附录 A) |
| RealSense `No plugins found image_transport` | realsense2_camera 偶发竞态 | 重启;`ros2 daemon stop && start` 后重跑;持续则装 `ros-humble-image-transport-plugins` |
| 双击夹爪时段错误 | 松灵采集脚本通病 | 重跑 `bash run_pika.sh`(自动清残缺) |
| 双击夹爪灯变了但没录上 | **采集节点没在跑**(只起了设备) | 终端2 必须跑 `run_pika.sh`,它在跑时双击才录 |
| 左右手图像反了 | USB 端口绑定左右接反 | 改 `pika-sensor-bind.rules` 左右端口、重载(见附录 B);**别用 setup_device.py** |
| Orbbec 头相机没图 / `camera_head` 不停重启 | `/dev/video52` 没生成(头相机没插/没开,或 udev 规则没装) | 插好 Orbbec→`bash setup_hardware.sh` 跑 ① 装 `99-orbbec-head.rules`;`ls -l /dev/video52` 应指向 Orbbec 的 video 节点 |
| KFCv2 头相机没图 / cam_high 自检 warn | deb 未安装、容器未挂 `/opt/dexe_sensors`、相机 IP 不通、或 `/camera/kfc_compressed` 没发布 | 确认 `test -f /opt/dexe_sensors/install/setup.bash`;网口设 `192.168.20.x`;`ping 192.168.20.30`;容器内 `ros2 topic hz /camera/kfc_compressed` |
| 采集中途自己停了,提示 "device frequency does not match" | 某话题掉频超过 timeout 秒被判 fail | 检查该传感器;必要时调大 `TIMEOUT` 重采 |
| 容器内 GUI 弹不出来 | 没授权 X11 | 宿主机 `xhost +local:root` |

---

## 一句话流程(贴墙版)

> `docker start pika` + `xhost +local:root` + `docker exec -it pika bash`
> → 开定位标签绿灯 → `./survive-cli` 确认不漂
> → 终端1 `start_multi_sensor.bash` + rqt 核左右手/漂移
> → 终端2 `bash run_pika.sh` 双击夹爪采集(段错误就重跑)
> → `start_dexechain_tools.sh univis` 看质量 → UMI workflow 生成 HDF5

---

# 附录 A:设备「查」—— 摸清当前 USB 拓扑 / 序列号

设备绑定分两类(改之前先搞清你要查的是哪类):

| 设备 | 绑定依据 | 怎么查 |
|---|---|---|
| **夹爪串口(ch341)+ 鱼眼相机** | **物理 USB 端口路径**(udev) | 见下方端口查询 |
| **大头定位器(Sense)** | **LHR 序列号**(配在 `pika_L/R_code`) | survive-cli(底层显示 WM0/WM1)/ get_code(rviz 显示 LHR);**别看 dongle serial,它永远是裸的** |
| **D405 深度相机** | **相机序列号** | `rs-enumerate-devices -s` |

### A1. 查夹爪串口在哪个物理端口(ch341 = 夹爪编码器)
```bash
for d in /dev/ttyUSB*; do
  echo -n "$d → "; udevadm info -q path -n "$d" | grep -oE "[0-9]+-[0-9.]+" | tail -1
done
```

### A2. 查鱼眼相机端口(区分鱼眼 vs RealSense)
```bash
for d in /dev/video*; do
  vid=$(udevadm info -q property -n "$d" | grep -oE "ID_VENDOR_ID=[0-9a-f]+" | cut -d= -f2)
  pp=$(udevadm info -q path -n "$d" | grep -oE "[0-9]+-[0-9.]+:" | tail -1)
  [ "$vid" = "8086" ] && tag=RealSense || tag=鱼眼
  echo "$d  [$tag]  端口=$pp"
done
```
> 💡 鱼眼相机厂商是 `1bcf`(DECXIN),RealSense 是 `8086`(Intel)。
> 一只夹爪的鱼眼(`端口.1`)和串口(`端口.4`)**共用同一个 hub**,所以按 hub(如 `1-1.4.4`)定左右即可,两者一起绑。

### A3. 查 D405 深度相机序列号(配在 `start_multi_sensor.bash`)
```bash
rs-enumerate-devices -s        # 列出两台(左右由 setup_hardware ② 按物理插拔自动绑定,以实际为准)
lsusb | grep -c 8086:0b5b      # USB 上 D405 数量,应为 2
```
只认到 1 台 = 两台挤带宽 → 分到不同 USB3 口。

### A4. 查接收器(dongle)与大头是否在线

> ⚠️ **重要更正**:本套 Sense 走 **watchman dongle 无线**,dongle 的 USB `serial` **永远是裸的**
> (如 `072602FDA9`)、**不会变成 `LHR-xxxx`**;libsurvive 里大头叫 **WM0/WM1** 而非 LHR。
> 所以**不能**用"`/sys` serial 是不是 LHR"判断大头在线(老文档此处判据是错的,会误报"没连")。

**① 查接收器 dongle 在不在**(端口动态扫描,不写死):
```bash
for s in /sys/bus/usb/devices/*/product; do
  case "$(cat "$s" 2>/dev/null)" in *Watchman*|*LHR*)
    echo "$(basename "$(dirname "$s")"): $(cat "$(dirname "$s")/serial" 2>/dev/null)";; esac
done
# 有输出(裸 Watchman serial 正常)= 接收器就绪
```

**② 查大头是否真的连上 + 读 LHR 序列号**

> 💡 **首选 `lhr_probe`**(`setup_hardware.sh ②` 用的同一个):读 `survive_simple_serial_number`,
> 设备 config 一到就返回真正的 `LHR-xxxx`,**不需校准/解算、十几秒出结果**。比 `get_code` 快且可靠
> ——`get_code` 必须**解算成功(有位姿)**才把 LHR 发到 TF,没校准/信号差时根本看不到。

```bash
# 编译一次(已随项目带源码 pika_ros/scripts/lhr_probe.c;/tmp/lhr_probe 在则跳过)
D=/home/dex/app/pika/pika_ros/install/libsurvive
gcc /home/dex/app/pika/pika_ros/scripts/lhr_probe.c -o /tmp/lhr_probe \
  -I"$D/include" -I"$D/include/libsurvive" -I"$D/include/libsurvive/redist" \
  -I"$D/include/cnkalman" -I"$D/include/cnmatrix" -L"$D/lib" -lsurvive
export LD_LIBRARY_PATH="$D/lib:$LD_LIBRARY_PATH"
/tmp/lhr_probe          # 打印 name=WM0 serial=LHR-414376D8 / WM1 serial=LHR-50E5EE8C
```
- 出两行 `serial=LHR-xxxx` = **两只大头都在线**;只出一行/零行 = 那只没开机(充电+长按到绿灯)。
- ⚠️ `lhr_probe` 占 dongle,**不能和 `start_multi_sensor` / `survive-cli` 同跑**(LIBUSB_BUSY)。
- 本机左 `LHR-414376D8`、右 `LHR-50E5EE8C`。

**(备选)看 survive 实跑**判是否在解算(校准/排障时用):
```bash
cd "$D/bin"; timeout 12 ./survive-cli 2>&1 | grep -iE "Preamble|LightcapMode|acc err|Got OOTX"
```
- 有 `Got OOTX packet` + `acc err` = 在解算;只有 `Preamble`/`LightcapMode→2`、没 `Got OOTX` = 信号没解出(见 §1.3 卡住排查)。

> ⚠️ `survive-cli` 占 dongle,**不能和 `start_multi_sensor` 同时跑**(会 LIBUSB_BUSY 抢设备)。

---

# 附录 B:设备「改 + 验」—— 重新绑定夹爪 USB 端口

**什么时候要做**:换了 USB 口 / 重排了 hub / 左右手图像反了 / `video50,51` `ttyUSB50,51` 没出来。

> 🟢 **日常优先用脚本,别手动**:在迁移包目录跑 `bash setup_hardware.sh` →
> - 选 **②(按手柄绑定)**:一次插一只手柄,自动 diff 出夹爪端口 + D405 序列号、左右天然一致,
>   最后提示**把两只都插上再验证**四个软链；wireless 模式还会探测两只 LHR 并写入 `.bashrc`
>   (每只从"两只全拔"的空白基线起检测,避开设备号复用漏检)。
> - 选 **③(基站校准)**:先用 `survive-cli --force-calibrate` 建立有效定位坐标。
> - 选 **④(左右手核对)**:校准完成后先用鱼眼确认物理左右，再同步比较两路 Pose 的实际运动量；
>   明确反向时可一键对调并自动重启复测。退出、报错或 `Ctrl+C` 都会清理本步骤启动的节点。
>
> **本附录(B1~B5)是手动备份 / 原理说明**——断网、脚本异常、或想理解 udev 规则时再照着做。
> ⚠️ 任何情况都**不要用 `setup_device.py`**(它是另一套绑定,和 udev 规则冲突)。

### B1. 用附录 A 查出左右两只夹爪 hub 的实际端口
例:左手 hub `1-1.4.4`、右手 hub `1-4.4.4`。一只 hub 下:`.1`=鱼眼、`.4`=串口。

### B2. 改规则文件 `/home/dex/app/pika/pika-sensor-bind.rules`
约定 **50=左,51=右**。把端口填成查到的(相机 `.1`、串口 `.4`):
```
# 左手(hub 1-1.4.4)
ACTION=="add", KERNELS=="1-1.4.4.4:1.0", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="ttyUSB50"
ACTION=="add", KERNEL=="video[0,2,4,...,48]*", KERNELS=="1-1.4.4.1:1.0", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="video50"
# 右手(hub 1-4.4.4)
ACTION=="add", KERNELS=="1-4.4.4.4:1.0", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="ttyUSB51"
ACTION=="add", KERNEL=="video[0,2,4,...,48]*", KERNELS=="1-4.4.4.1:1.0", SUBSYSTEMS=="usb", MODE:="0777", SYMLINK+="video51"
```

### B3. 装到宿主机并重载(需 sudo)
```bash
sudo cp /home/dex/app/pika/pika-sensor-bind.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger --action=add
```

### B4. 验证软链按预期生成
```bash
for s in video50 ttyUSB50 video51 ttyUSB51; do
  echo -n "$s → "; udevadm info -q path -n /dev/$s | grep -oE "1-[0-9](\.[0-9]+)+" | tail -1
done
# 期望:50→左 hub,51→右 hub
```

### B5. 重启设备栈 + rqt 挥手复核左右(必做)
```bash
# 终端1
cd /home/dex/app/pika/pika_ros/scripts/ && bash start_multi_sensor.bash
# 终端2
ros2 run rqt_image_view rqt_image_view   # 选 /camera_fisheye_l 与 /camera_fisheye_r
```
对着**左手夹爪**挥手 → `camera_fisheye_l` 动 = ✅;若 `camera_fisheye_r` 动 = 左右反了,
把 B2 里左右两个 hub 端口对调,重做 B3~B5。

> 📌 经验:**别把多个设备挤在同一个 USB hub**(带宽/供电不足会集体掉线);两只夹爪、两台 D405 尽量分到不同 USB 控制器口。每次重插都会改变端口号 → 要重做附录 B。
