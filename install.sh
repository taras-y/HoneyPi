[ -z $BASH ] && { exec bash "$0" "$@" || exit; }
#!/bin/bash
# file: install.sh
#
# This script will install required software for HoneyPi.
# It is recommended to run it in your home directory.
#

# check if sudo is used
if [ "$(id -u)" != 0 ]; then
  echo 'Sorry, you need to run this script with sudo'
  exit 1
fi

# target directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
w1gpio=11

# error counter
ERR=0

# sys update
echo '>>> System update'
apt-get update
apt-get upgrade -y

# enable I2C on Raspberry Pi
# enable 1-Wire on Raspberry Pi
echo '>>> Enable I2C and 1-Wire'
if grep -q '^i2c-dev' /etc/modules; then
  echo '1 - Seems i2c-dev module already exists, skip this step.'
else
  echo 'i2c-dev' >> /etc/modules
fi
if grep -q '^w1_gpio' /etc/modules; then
  echo '2 - Seems w1_gpio module already exists, skip this step.'
else
  echo 'w1_gpio' >> /etc/modules
fi
if grep -q '^w1_therm' /etc/modules; then
  echo '3 - Seems w1_therm module already exists, skip this step.'
else
  echo 'w1_therm' >> /etc/modules
fi
if grep -q '^dtoverlay=w1-gpio' /boot/config.txt; then
  echo '4 - Seems w1-gpio parameter already set, skip this step.'
else
  echo 'dtoverlay=w1-gpio,gpiopin='$w1gpio >> /boot/config.txt
fi
if grep -q '^dtparam=i2c_arm=on' /boot/config.txt; then
  echo '5 - Seems i2c_arm parameter already set, skip this step.'
else
  echo 'dtparam=i2c_arm=on' >> /boot/config.txt
fi

# Enable Wifi-Stick on Raspberry Pi 1 & 2
if grep -q '^net.ifnames=0' /boot/cmdline.txt; then
  echo '6 - Seems net.ifnames=0 parameter already set, skip this step.'
else
  echo 'net.ifnames=0' >> /boot/cmdline.txt
fi

# Change timezone in Debian 9 (Stretch)
echo '>>> Change Timezone to Berlin'
ln -fs /usr/share/zoneinfo/Europe/Berlin /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Install NTP for time synchronisation with wittyPi
apt-get install -y ntp
dpkg-reconfigure ntp

# change hostname to http://HoneyPi.local
echo '>>> Change Hostname to HoneyPi'
sudo sed -i 's/127.0.1.1.*raspberry.*/127.0.1.1 HoneyPi/' /etc/hosts
sudo bash -c "echo 'HoneyPi' > /etc/hostname"

# rpi-scripts
echo '>>> Install software for measurement python scripts'
apt-get install -y rpi.gpio python-smbus python-setuptools python3-pip libatlas-base-dev
pip3 install -r requirements.txt

# rpi-webinterface
echo '>>> Install software for Webinterface'
apt-get install -y lighttpd php7.1-cgi
lighttpd-enable-mod fastcgi fastcgi-php
service lighttpd force-reload

echo '>>> Create www-data user'
groupadd www-data
usermod -G www-data -a pi

# give www-data all right for shell-scripts
echo '>>> Give shell-scripts rights'
if grep -q 'www-data ALL=NOPASSWD: ALL' /etc/sudoers; then
  echo 'Seems www-data already has the rights, skip this step.'
else
  echo 'www-data ALL=NOPASSWD: ALL' | sudo EDITOR='tee -a' visudo
fi

# Install software for surfstick
echo '>>> Install software for Surfsticks'
apt-get install -y wvdial usb-modeswitch
cp overlays/wvdial.conf /etc/wvdial.conf
chmod 755 /etc/wvdial.conf
cp overlays/wvdial /etc/ppp/peers/wvdial
echo '>>> Put wvdial into Autostart'
if grep -q "wvdial &" /etc/rc.local; then
  echo 'Seems wvdial already in rc.local, skip this step.'
else
  sed -i -e '$i \wvdial &\n' /etc/rc.local
  chmod +x /etc/rc.local
  systemctl enable rc-local.service
fi

# wifi networks
echo '>>> Setup Wifi Configuration'
cp overlays/wpa_supplicant.conf /etc/wpa_supplicant/wpa_supplicant.conf
cp overlays/interfaces /etc/network/interfaces


# Autostart
echo '>>> Put Measurement Script into Autostart'
if grep -q "$DIR/rpi-scripts/main.py" /etc/rc.local; then
  echo 'Seems measurement main.py already in rc.local, skip this step.'
else
  sed -i -e '$i \(sleep 3;python3 '"$DIR"'/rpi-scripts/main.py)&\n' /etc/rc.local
  chmod +x /etc/rc.local
  systemctl enable rc-local.service
fi

# AccessPoint
echo '>>> Set Up Raspberry Pi as Access Point'
apt-get install -y dnsmasq hostapd
systemctl stop dnsmasq
systemctl stop hostapd
# Configuring a static IP
cp overlays/dhcpcd.conf /etc/dhcpcd.conf
service dhcpcd restart && systemctl daemon-reload
# Configuring the DHCP server (dnsmasq)
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig
cp overlays/dnsmasq.conf /etc/dnsmasq.conf
# Configuring the access point host software (hostapd)
cp overlays/hostapd.conf /etc/hostapd/hostapd.conf
cp overlays/hostapd /etc/default/hostapd
# Start it up
systemctl start hostapd
systemctl start dnsmasq
# Add routing and masquerade
cp overlays/sysctl.conf /etc/sysctl.conf # sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A  POSTROUTING -o eth0 -j MASQUERADE
sh -c "iptables-save > /etc/iptables.ipv4.nat"
if grep -q 'iptables-restore < /etc/iptables.ipv4.nat' /etc/rc.local; then
  echo 'Seems "iptables-restore < /etc/iptables.ipv4.nat" already in rc.local, skip this step.'
else
  sed -i -e '$i \iptables-restore < /etc/iptables.ipv4.nat\n' /etc/rc.local
fi

echo
# Replace HoneyPi files with latest releases
if [ $ERR -eq 0 ]; then
  # waiting for internet connection
  echo ">>> Waiting for internet connection ..."
  while ! timeout 0.2 ping -c 1 -n api.github.com &> /dev/null
  do
    printf "."
  done
  sh update.sh
else
  echo '>>> Something went wrong. Updating measurement scripts skiped.'
fi

if [ $ERR -eq 0 ]; then
  echo '>>> All done. Please reboot your Pi :-)'
else
  echo '>>> Something went wrong. Please check the messages above :-('
fi
