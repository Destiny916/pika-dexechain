
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
camera_fps=30
camera_width=640
camera_height=480
header_depth_camera_no=315122272729
header_serial_port=/dev/ttyUSB70
sudo chmod a+rw /dev/ttyUSB*
header_fisheye_port=70
sudo chmod a+rw /dev/video*

source /opt/ros/humble/setup.bash && cd $SCRIPT_DIR/../install/sensor_tools/share/sensor_tools/scripts/ && chmod 777 usb_camera.py
source $SCRIPT_DIR/../install/setup.bash && ros2 launch sensor_tools open_header.launch.py depth_camera_no:=_$header_depth_camera_no serial_port:=$header_serial_port fisheye_port:=$header_fisheye_port camera_fps:=$camera_fps camera_width:=$camera_width camera_height:=$camera_height camera_profile:=$camera_width,$camera_height,$camera_fps
                