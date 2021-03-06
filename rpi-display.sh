#!/usr/bin/env bash

# run: sudo /bin/bash rpi-display.sh [0, 90, 180, 270]


# ask y/n function
function ask()
{
  while true; do
    read -p "$1 y/n " REPLY

    case "$REPLY" in
      Y*|y*) return 0 ;;
      N*|n*) return 1 ;;
    esac
  done
}


# reboot system
function reboot_system()
{
  echo "Rebooting now..."
  reboot
}


# update system
function update_system()
{
  apt-get -y update
  #apt-get -y upgrade

  #only rpi-update has no DMA support for SPI
  REPO_URI=https://github.com/notro/rpi-firmware rpi-update
}


# check for fbtft
function check_fbtft()
{
  if [ ! -d "/proc/device-tree" ]; then
    echo "Note: No Device Tree Kernel found."
    echo
    if ask "Update the system now?"; then
      update_system
    else
      echo "Installation aborted."
      exit 1
    fi
  fi

  if ! modinfo fbtft > /dev/null; then
    echo "Note: You need a Device Tree Kernel with FBTFT."
    echo
    if ask "Update the system now?"; then
      update_system
    else
      echo "Installation aborted."
      exit 1
    fi
  fi

  if ! modinfo -F parm spi_bcm2708 | grep -q -i "dma"; then
    echo "Note: No DMA support for spi_bcm2708 found."
    echo
    if ask "Update the system now?"; then
      update_system
    fi
  fi
}


# update config.txt
function update_configtxt()
{
  echo "--- Updating /boot/config.txt ---"
  echo
  echo "Please reboot the system after the installation."
  echo

  if grep -q "dtoverlay=rpi-display" "/boot/config.txt"; then
    sed -i 's/dtoverlay=rpi-display,speed=32000000,rotate=.*/dtoverlay=rpi-display,speed=32000000,rotate='$rotate'/g' "/boot/config.txt"
  else
    cat >> /boot/config.txt <<EOF

dtoverlay=rpi-display,speed=32000000,rotate=$rotate
EOF
    fi
}


# update xorg.conf
function update_xorg()
{
  echo "--- Updating /etc/X11/xorg.conf.d ---"
  echo
  echo "startx -- -layout TFT"
  echo "startx -- -layout HDMI"
  echo "When -layout is not set, the first is used: TFT"
  echo

  mkdir -p /etc/X11/xorg.conf.d

  if [ "${rotate}" == "0" ]; then
    invertx="0"
    inverty="0"
    swapaxes="0"
  fi
  if [ "${rotate}" == "90" ]; then
    invertx="1"
    inverty="0"
    swapaxes="1"
  fi
  if [ "${rotate}" == "180" ]; then
    invertx="1"
    inverty="1"
    swapaxes="0"
  fi
  if [ "${rotate}" == "270" ]; then
    invertx="0"
    inverty="1"
    swapaxes="1"
  fi

  cat > /etc/X11/xorg.conf.d/99-ads7846-cal.conf <<EOF
Section "InputClass"
    Identifier "calibration"
    MatchProduct "ADS7846 Touchscreen"
    Option "InvertX" "$invertx"
    Option "InvertY" "$inverty"
    Option "SwapAxes" "$swapaxes"
    Option "Calibration" ""
EndSection
EOF

  cat > /etc/X11/xorg.conf.d/50-fbtft.conf <<'EOF'
# FBTFT xorg config file
#
# startx -- -layout TFT
# startx -- -layout HDMI
# When -layout is not set, the first is used: TFT

Section "ServerLayout"
    Identifier "TFT"
    Screen 0 "ScreenTFT"
EndSection

Section "ServerLayout"
    Identifier "HDMI"
    Screen 0 "ScreenHDMI"
EndSection

Section "Screen"
    Identifier "ScreenHDMI"
    Monitor "MonitorHDMI"
    Device "DeviceHDMI"
Endsection

Section "Screen"
    Identifier "ScreenTFT"
    Monitor "MonitorTFT"
    Device "DeviceTFT"
Endsection

Section "Monitor"
    Identifier "MonitorHDMI"
Endsection

Section "Monitor"
    Identifier "MonitorTFT"
Endsection

Section "Device"
    Identifier "DeviceHDMI"
    Driver "fbturbo"
    Option "fbdev" "/dev/fb0"
    Option "SwapbuffersWait" "true"
EndSection

Section "Device"
    Identifier "DeviceTFT"
    Option "fbdev" "/dev/fb1"
EndSection
EOF
}


# create symlink for ads7846 device
function update_udev()
{
  echo "--- Creating /dev/input/touchscreen ---"

  cat > /etc/udev/rules.d/95-ads7846.rules <<'EOF'
SUBSYSTEM=="input", KERNEL=="event[0-9]*", ATTRS{name}=="ADS7846*", SYMLINK+="input/touchscreen"
EOF
}


# activate console on TFT display
function activate_console()
{
  sed -i 's/rootwait/rootwait fbcon=map:10 fbcon=font:VGA8x8/g' "/boot/cmdline.txt"
  sed -i 's/BLANK_TIME=.*/BLANK_TIME=0/g' "/etc/kbd/config"
}


# deactivate console on TFT display
function deactivate_console()
{
  sed -i 's/rootwait fbcon=map:10 fbcon=font:VGA8x8/rootwait/g' "/boot/cmdline.txt"
  sed -i 's/BLANK_TIME=0/BLANK_TIME=10/g' "/etc/kbd/config"
  echo
  echo "Set screen blanking time to 10 minutes."
  echo
}


# install fbcp
function install_fbcp()
{
  echo "--- Installing fbcp ---"

  cd /tmp
  apt-get install -y cmake
  git clone https://github.com/tasanakorn/rpi-fbcp
  mkdir -p rpi-fbcp/build
  cd rpi-fbcp/build
  cmake ..
  make
  install fbcp /usr/local/bin/fbcp
  cd ../..
  rm -r rpi-fbcp
}


# download and install xinput-calibrator
function install_xinputcalibrator()
{
  echo "--- Installing xinput-calibrator ---"

  cd /tmp
  wget -N http://tronnes.org/downloads/xinput-calibrator_0.7.5-1_armhf.deb
  dpkg -i -B xinput-calibrator_0.7.5-1_armhf.deb
  rm xinput-calibrator_0.7.5-1_armhf.deb

  cat > /etc/X11/Xsession.d/xinput_calibrator_pointercal <<'EOF'
#!/bin/sh
PATH="/usr/bin:$PATH"
BINARY="xinput_calibrator"
CALFILE="/etc/X11/xorg.conf.d/99-ads7846-cal.conf"
LOGFILE="/var/log/xinput_calibrator.pointercal.log"

CALDATA=`grep -o 'Option[[:space:]]*"Calibration".*' $CALFILE`
if [ 30 -lt "${#CALDATA}" ] ; then
    echo "Using calibration data stored in $CALFILE"
    exit 0
fi

CALDATA=`DISPLAY=:0 $BINARY --output-type xorg.conf.d --device 'ADS7846 Touchscreen' | tee $LOGFILE | grep -o 'Option[[:space:]]*"Calibration".*' | sed -E 's/[[:space:]]+/ /g'`
if [ ! -z "$CALDATA" ] ; then
    sed -i -E "s/Option[[:space:]]+\"Calibration\".*/$CALDATA/g" "$CALFILE"
    echo "Calibration data stored in $CALFILE (log in $LOGFILE)"
fi
EOF

  if grep -q "xinput_calibrator_pointercal" "/etc/xdg/lxsession/LXDE-pi/autostart"; then
    echo "xinput_calibrator already in LXDE autostart"
  else
    cat >> /etc/xdg/lxsession/LXDE-pi/autostart <<'EOF'
sudo /bin/sh /etc/X11/Xsession.d/xinput_calibrator_pointercal
EOF
  fi
}


# download and install ts_lib
function install_tslib()
{
  echo "--- Installing ts_lib ---"

  apt-get install -y tslib libts-bin
  # install ts_test with quit button
  #wget -O /usr/bin/ts_test http://tronnes.org/downloads/ts_test
  #chmod +x /usr/bin/ts_test
}


# calibrate touchpanel
function calibrate_touchpanel()
{
  echo "--- Calibrating touchpanel ---"

  TSLIB_FBDEVICE=/dev/fb1 TSLIB_TSDEVICE=/dev/input/touchscreen /usr/bin/ts_calibrate
  #startx
  #DISPLAY=:0 xinput_calibrator --device "ADS7846 Touchscreen" --output-type xinput
}


# main function
if [ $EUID -ne 0 ]; then
  echo "The script must be run as root. Try: sudo $0"
  exit 1
fi

rotate="$1"

if [ "${rotate}" != "0" ] && [ "${rotate}" != "90" ] && [ "${rotate}" != "180" ] && [ "${rotate}" != "270" ]; then
  echo "Usage: sudo bash $0 [0, 90, 180 or 270]"
  exit 1
fi

check_fbtft

if ask "Enable TFT display driver and activate X windows on TFT display?"; then
  update_configtxt
  update_xorg
fi

if ask "Activate the console on the TFT display?"; then
  activate_console
else
  deactivate_console
fi

if modinfo -F parm spi_bcm2708 | grep -q -i "dma"; then
  if ask "Install fbcp (Framebuffer Copy)?"; then
    install_fbcp
  fi
fi

if ask "Install xinput-calibrator?"; then
  install_xinputcalibrator
fi

if ask "Install ts_lib?"; then
  update_udev
  install_tslib
fi

if [ -f "/usr/bin/ts_calibrate" ]; then
  if ask "Calibrate the touchpanel now?"; then
    calibrate_touchpanel
  fi
fi

if ask "Reboot the system now?"; then
  reboot_system
fi
