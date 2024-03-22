VPN Wi-Fi router using a Raspberry Pi
=====================================

This tutorial will configure a Raspberry Pi as a Wi-Fi router with the following properties:

  1. The Pi connects to an OpenVPN server (such as NordVPN) over the Internet, via the Pi's Ethernet port.

  2. Wi-Fi clients can connect to a Wi-Fi network served by the Pi.

  3. All Internet access for Wi-Fi clients is routed via the VPN tunnel. Internet access for Wi-Fi clients is blocked if the VPN tunnel is offline.

  4. The Pi acts as a DHCP and DNS server for the Wi-Fi clients. DNS queries resolved by the Pi on behalf of Wi-Fi clients are routed to Cloudflare Public DNS via the VPN tunnel to prevent DNS leaks.

  5. Internet access for the Pi itself (e.g. for apt package updates), including DNS queries on its own behalf, are routed to the Internet directly. The VPN tunnel is only used for Wi-Fi clients. This is to avoid potential information leaks that could arise from the Pi switching between direct access and VPN access.


Pre-requisites
--------------

The following tutorial assumes the following:

  * You are running Raspberry Pi OS version 12 (Debian Bookworm). This version introduced NetworkManager by default, which is used to configure networking in this tutorial.

  * You have copied the contents of this repo to the Pi. Any reference in this tutorial to `$CONFIG_PREFIX` means the directory where you copied the contents of this repo. This can be set as a variable in your shell, e.g. `export CONFIG_PREFIX=/tmp/raspberry-pi-vpn-router`

  * You have shell access on the Pi, via SSH or the console.

  * You are using the shell as the root user. If you can't log in as root directly, log in as another user and then switch to root with `su` or `sudo su`.

This tutorial and configuration files were developed using a Raspberry Pi 4. Some details such as interface names may differ across Pi models. I used the Raspberry Pi Imager to image Raspberry Pi OS Lite onto an SD card.

NordVPN is used in the examples below, but these instructions and configs should generally work with any OpenVPN server.


Step 1: Disable IPv6 and set Wi-Fi country
------------------------------------------

Edit `/boot/firmware/cmdline.txt` and add the following parameters, replacing XX with your country code for Wi-Fi. Put the country you are actually in, not the country you want to VPN through.

```
ipv6.disable=1 cfg80211.ieee80211_regdom=XX
```

Also copy these files into place and reboot:

```
cp $CONFIG_PREFIX/etc/sysctl.d/local.conf /etc/sysctl.d/local.conf
cp $CONFIG_PREFIX/etc/rc.local /etc/rc.local
reboot
```

After reboot, type `ip addr` and check that there are no IPv6 addresses listed.


Step 2: Configure DNS over HTTPS
--------------------------------

Install `cloudflared` to provide DNS over HTTPS:

```
apt update
apt install curl lsb-release dnsutils
curl -L https://pkg.cloudflare.com/cloudflare-main.gpg > /usr/share/keyrings/cloudflare-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-archive-keyring.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" > /etc/apt/sources.list.d/cloudflared.list
apt update
apt install cloudflared
useradd -s /usr/sbin/nologin -r -M cloudflared
cp $CONFIG_PREFIX/etc/systemd/system/cloudflared.service /etc/systemd/system/cloudflared.service
systemctl enable cloudflared
systemctl start cloudflared
```

`cloudflared` should now be listening for DNS requests on port 5053. Test it using `dig`:

```
dig @127.0.0.1 -p 5053 google.com
```

You should see a DNS response that shows an IP address for google.com.

*Note:* In the next step, the Cloudflare DNS servers will be blackholed so they can only be accessed when the VPN tunnel is up. Therefore the above test using `dig` will not work after you've completed the next step.


Step 3: Configure networking
----------------------------

Create a special routing table for Wi-Fi clients. We will populate the routes later:

```
echo "200 wificlient" >> /etc/iproute2/rt_tables
```

Edit `$CONFIG_PREFIX/etc/NetworkManager/system-connections/LAN.nmconnection` and update the following settings for the Ethernet interface:

  * `interface-name`: Ensure this matches the name of the Ethernet interface as seen from the `ip link` command. In the default config this is "end0".

  * `address1`: Set a static IP address and default gateway for accessing the Internet. In the default config, the upstream LAN uses the 192.168.7.xxx range, so the Raspberry Pi is assigned 192.168.7.10, and the default gateway is set to the broadband router's address of 
192.168.7.1. Alter these as appropriate for your upstream LAN.

  * `dns`: In the default config this is set to use Google Public DNS (8.8.8.8 and 8.8.4.4). You can change this to your broadband router or ISP's DNS servers if you wish. Do **not** use localhost or Cloudflare to provide DNS here; we will use Cloudflare to provide DNS to Wi-Fi clients via the VPN tunnel, whereas the DNS servers you provide here will be used for the Pi's *own* Internet use that *isn't* routed via the VPN tunnel (e.g. for apt package updates).

Edit `$CONFIG_PREFIX/etc/NetworkManager/system-connections/Hotspot.nmconnection` and update the following settings for the Wi-Fi interface:

  * `interface-name`: Ensure this matches the name of the Wi-Fi interface as seen from the `ip link` command. In the default config this is "wlan0".

  * `ssid`: Set the SSID you want to use for Wi-Fi clients to connect to (this must be different to your regular home Wi-Fi SSID).

  * `psk`: Set the password for Wi-Fi clients to join the network.

  * `address1`: This specifies the subnet that will be used for Wi-Fi clients. The default config uses 192.168.12.xxx. This **must** be different to the subnet used by the upstream LAN. There's not much reason to change this unless the 192.168.12.xxx range clashes with your upstream LAN.

If your Ethernet interface is not called "end0", update the interface name in `$CONFIG_PREFIX/etc/NetworkManager/dispatcher.d/10-dns-blackhole`

If your Wi-Fi interface is not called "wlan0", or if you changed the IP address of either the Wi-Fi or Ethernet interface, update these in `$CONFIG_PREFIX/etc/NetworkManager/dispatcher.d/20-wifi-pbr`

Now install these and reboot:

```
rm /etc/NetworkManager/system-connections/*.nmconnection
cp $CONFIG_PREFIX/etc/NetworkManager/system-connections/*.nmconnection /etc/NetworkManager/system-connections
chmod 600 /etc/NetworkManager/system-connections/*.nmconnection
cp $CONFIG_PREFIX/etc/NetworkManager/dispatcher.d/10-dns-blackhole /etc/NetworkManager/dispatcher.d/10-dns-blackhole
cp $CONFIG_PREFIX/etc/NetworkManager/dispatcher.d/20-wifi-pbr /etc/NetworkManager/dispatcher.d/20-wifi-pbr
chmod 755 /etc/NetworkManager/dispatcher.d/10-dns-blackhole
chmod 755 /etc/NetworkManager/dispatcher.d/20-wifi-pbr
reboot
```


Step 4: Verify networking configuration
---------------------------------------

The Ethernet and Wi-Fi interfaces should now be up and have the IP addresses that were configured in the previous step, and no IPv6 addresses:

```
root@pi:~# ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: end0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether e4:5f:01:01:01:01 brd ff:ff:ff:ff:ff:ff
    inet 192.168.7.10/24 brd 192.168.7.255 scope global noprefixroute end0
       valid_lft forever preferred_lft forever
3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether e4:5f:01:02:02:02 brd ff:ff:ff:ff:ff:ff
    inet 192.168.12.1/24 brd 192.168.12.255 scope global noprefixroute wlan0
       valid_lft forever preferred_lft forever
```

IPv4 forwarding should be enabled:

```
root@pi:~# cat /proc/sys/net/ipv4/ip_forward
1
```

The default routing table should access Internet through the Ethernet interface and blackhole Cloudflare DNS when the VPN is not connected:

```
root@pi:~# ip route show
default via 192.168.7.1 dev end0 proto static metric 100 
blackhole 1.0.0.1 
blackhole 1.1.1.1 
192.168.7.0/24 dev end0 proto kernel scope link src 192.168.7.10 metric 100 
192.168.12.0/24 dev wlan0 proto kernel scope link src 192.168.12.1 metric 600 
```

Wi-Fi clients should use the "wificlient" routing table:

```
root@pi:~# ip rule show
0:	from all lookup local
32765:	from 192.168.12.0/24 lookup wificlient
32766:	from all lookup main
32767:	from all lookup default
```

Routing table for Wi-Fi clients should have no default route when the VPN is not connected:

```
root@pi:~# ip route show table wificlient
192.168.12.0/24 dev wlan0 scope link src 192.168.12.1 
```

Hosts on the Ethernet subnet should be blocked from communicating with hosts on the Wi-Fi subnet and vice-versa:

```
root@pi:~# iptables -L
Chain INPUT (policy ACCEPT)
target     prot opt source               destination         

Chain FORWARD (policy ACCEPT)
target     prot opt source               destination         
DROP       all  --  192.168.12.0/24      192.168.7.0/24      
DROP       all  --  192.168.7.0/24       192.168.12.0/24     

Chain OUTPUT (policy ACCEPT)
target     prot opt source               destination  
```

The Pi itself should be configured to use the DNS servers specified in the previous step (8.8.8.8 and 8.8.4.4 unless modified). *Note:* Cloudflare will be used to resolve DNS queries for Wi-Fi clients via the VPN tunnel, but is *not* used to resolve DNS queries for direct (non-VPN) Internet access by the Pi itself.

```
root@pi:~# cat /etc/resolv.conf 
# Generated by NetworkManager
nameserver 8.8.8.8
nameserver 8.8.4.4
```

Internet should be accessible from the Pi:

```
root@pi:~# curl https://google.com
<HTML><HEAD><meta http-equiv="content-type" content="text/html;charset=utf-8">
<TITLE>301 Moved</TITLE></HEAD><BODY>
<H1>301 Moved</H1>
The document has moved
<A HREF="https://www.google.com/">here</A>.
</BODY></HTML>
```

If any of the above do not give the expected results, fix it before continuing.


Step 5: Configure OpenVPN
-------------------------

You will need the following before continuing:

  1. **OpenVPN credentials:** For NordVPN, get these by logging into your Nord account and going to Services > NordVPN > Set up NordVPN manually. For other VPN providers, refer to their documentation.

  2. **OpenVPN server to use:** For NordVPN, select a server from https://nordvpn.com/servers/tools/. For other VPN providers, refer to their documentation.

  3. **OpenVPN configuration file:** For NordVPN, this can be downloaded from https://downloads.nordcdn.com/configs/files/ovpn_udp/servers/SERVER_ID.nordvpn.com.udp.ovpn where SERVER_ID is replaced with the server ID, e.g. "us001". For other VPN providers, refer to their documentation.

Install OpenVPN:

```
apt update
apt install openvpn
```

Rename the downloaded .ovpn file to "nord.conf". Open the file and add the following additional lines:

```
auth-user-pass /etc/openvpn/nord.auth
script-security 2
up /etc/openvpn/nord-up.sh
down /etc/openvpn/nord-down.sh
route-nopull
```

If the file contains the line "auth-user-pass" with no file path, remove that line. It should be "auth-user-pass" with a file path as shown above.

Install config files:

```
cp nord.conf /etc/openvpn/nord.conf
cp $CONFIG_PREFIX/etc/openvpn/nord-up.sh /etc/openvpn/nord-up.sh
cp $CONFIG_PREFIX/etc/openvpn/nord-down.sh /etc/openvpn/nord-down.sh
chown -R root:root /etc/openvpn
chmod 644 /etc/openvpn/nord.conf
chmod 755 /etc/openvpn/nord-up.sh
chmod 755 /etc/openvpn/nord-down.sh
```

Create a new file at `/etc/openvpn/nord.auth` that contains your OpenVPN username on the first line, and your OpenVPN password on the second line. For example if your username is "SScujHrRSScujHrR" and password is "irjQbfhairjQbfha", the file will look like this:

```
SScujHrRSScujHrR
irjQbfhairjQbfha
```

Then set permissions so only root can read the file:

```
chown root:root /etc/openvpn/nord.auth
chmod 600 /etc/openvpn/nord.auth
```


Step 6: Verify OpenVPN configuration
------------------------------------

Run OpenVPN in the shell using this command:

```
/usr/sbin/openvpn --config /etc/openvpn/nord.conf
```

If you see "Initialization Sequence Completed", the VPN tunnel has connected successfully. The tunnel will remain online as long as OpenVPN remains open in the shell. Therefore, open a new shell (e.g. a new SSH connection) to run the following verification commands.

There should now be a tunnel interface "tun0" visible in the output of `ip addr`:

```
root@pi:~# ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: end0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether e4:5f:01:01:01:01 brd ff:ff:ff:ff:ff:ff
    inet 192.168.7.10/24 brd 192.168.7.255 scope global noprefixroute end0
       valid_lft forever preferred_lft forever
3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether e4:5f:01:02:02:02 brd ff:ff:ff:ff:ff:ff
    inet 192.168.12.1/24 brd 192.168.12.255 scope global noprefixroute wlan0
       valid_lft forever preferred_lft forever
4: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UNKNOWN group default qlen 500
    link/none 
    inet 10.8.1.9/24 scope global tun0
       valid_lft forever preferred_lft forever
```

The default routing table should now route Cloudflare DNS (1.1.1.1 and 1.0.0.1) via the tunnel interface:

```
root@pi:~# ip route show
default via 192.168.7.1 dev end0 proto static metric 100 
1.0.0.1 via 10.8.1.9 dev tun0 
1.1.1.1 via 10.8.1.9 dev tun0 
10.8.1.0/24 dev tun0 proto kernel scope link src 10.8.1.9 
192.168.7.0/24 dev end0 proto kernel scope link src 192.168.7.10 metric 100 
192.168.12.0/24 dev wlan0 proto kernel scope link src 192.168.12.1 metric 600
```

The routing table for Wi-Fi clients should now have a default route via the VPN tunnel:

```
root@pi:~# ip route show table wificlient
default via 10.8.1.9 dev tun0 
192.168.12.0/24 dev wlan0 scope link src 192.168.12.1 
```

The NAT table should show that all packets going out the tun0 interface will be NAT'ed using MASQUERADE (meaning the Wi-Fi client IP will be replaced with the tunnel client IP):

```
root@pi:~# iptables -t nat -L -v -n
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination         

Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination         

Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination         

Chain POSTROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination         
    0     0 MASQUERADE  0    --  *      tun0    0.0.0.0/0            0.0.0.0/0  
```

You should also now be able to ping 1.1.1.1 via the tunnel:

```
root@pi:~# ip route get 1.1.1.1
1.1.1.1 dev tun0 src 10.8.1.9 uid 0 
    cache 
root@pi:~# ping 1.1.1.1
PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
64 bytes from 1.1.1.1: icmp_seq=1 ttl=58 time=219 ms
64 bytes from 1.1.1.1: icmp_seq=2 ttl=58 time=219 ms
64 bytes from 1.1.1.1: icmp_seq=3 ttl=58 time=219 ms
64 bytes from 1.1.1.1: icmp_seq=4 ttl=58 time=218 ms
```

and `cloudflared` should be able to resolve DNS names:

```
root@pi:~# dig @127.0.0.1 -p 5053 google.com
(successful DNS output shown here)
```

If any of the above do not give the expected results, fix it before continuing.

Press Ctrl-C in the shell running OpenVPN to disconnect.

When OpenVPN is no longer running, the tun0 interface should disappear, and the routes should revert back as they were in the "Verify networking configuration" step.


Step 7: Make OpenVPN start automatically at system boot
-------------------------------------------------------

Edit `/etc/default/openvpn` and add this line:

```
AUTOSTART="nord"
```

Then set OpenVPN to start at system boot:

```
systemctl daemon-reload
systemctl enable openvpn
systemctl start openvpn
```

If OpenVPN started successfully, there should be a tun0 interface as in the previous step. Use `journalctl -xe` to check logs if OpenVPN did not start successfully.


Step 8: Install dnsmasq as a DHCP and DNS server for Wi-Fi clients
------------------------------------------------------------------

Review the following settings in `$CONFIG_PREFIX/etc/dnsmasq.conf`:

  * `interface`: If your Wi-Fi interface is called something other than `wlan0`, update it here.

  * `dhcp-range`: IPs will be assigned to Wi-Fi clients from this range. This range must be in the same subnet as the Wi-Fi interface. No change is required if the Wi-Fi interface is using the 192.168.12.xxx subnet in the default config.

Note also the following settings:

  * `no-resolv` and `no-poll`: This prevents dnsmasq from reading `/etc/resolv.conf` to use the servers listed there as upstream DNS servers. We certainly *don't* want to use the servers from resolv.conf, because these will be the Google Public DNS or ISP DNS servers that are *not* routed via the VPN tunnel.

  * `server=127.0.0.1#5053`: This tells dnsmasq to make DNS requests via `cloudflared`, which will use Cloudflare DNS via the VPN tunnel.

Install config and restart dnsmasq:

```
cp $CONFIG_PREFIX/etc/dnsmasq.conf /etc/dnsmasq.conf
systemctl enable dnsmasq
systemctl restart dnsmasq
```


Step 9: Verify Wi-Fi client connectivity
----------------------------------------

Before proceeding, check on the Pi that we have connectivity via OpenVPN:

```
root@pi:~# ip route get 1.1.1.1
1.1.1.1 dev tun0 src 10.8.1.9 uid 0 
    cache 
root@pi:~# ping 1.1.1.1
PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
64 bytes from 1.1.1.1: icmp_seq=1 ttl=58 time=219 ms
64 bytes from 1.1.1.1: icmp_seq=2 ttl=58 time=219 ms
64 bytes from 1.1.1.1: icmp_seq=3 ttl=58 time=219 ms
64 bytes from 1.1.1.1: icmp_seq=4 ttl=58 time=218 ms
```

Also ensure `dnsmasq` is running and is functioning correctly as a DNS server:

```
root@pi:~# dig @127.0.0.1 google.com
(successful DNS output shown here)
```

Connect a Wi-Fi client to the Pi using the SSID and Wi-Fi password that was set earlier.

From the Wi-Fi client, open the network settings and check that the client got an IP address via DHCP in the expected Wi-Fi subnet (192.168.12.xxx in the default config). DHCP should also have set the IP address of the Pi's Wi-Fi interface (192.168.12.1 in the default config) as the default router and DNS server on the Wi-Fi client.

The client should be able to ping the Pi's local IP:

```
user@MacBook ~ % ping 192.168.12.1
PING 192.168.12.1 (192.168.12.1): 56 data bytes
64 bytes from 192.168.12.1: icmp_seq=0 ttl=64 time=9.180 ms
64 bytes from 192.168.12.1: icmp_seq=1 ttl=64 time=6.854 ms
64 bytes from 192.168.12.1: icmp_seq=2 ttl=64 time=14.877 ms
64 bytes from 192.168.12.1: icmp_seq=3 ttl=64 time=9.666 ms
```

The client should also be able to ping hosts on the Internet:

```
user@MacBook ~ % ping 8.8.8.8
PING 8.8.8.8 (8.8.8.8): 56 data bytes
64 bytes from 8.8.8.8: icmp_seq=0 ttl=114 time=343.712 ms
64 bytes from 8.8.8.8: icmp_seq=1 ttl=114 time=260.754 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=114 time=280.491 ms
64 bytes from 8.8.8.8: icmp_seq=3 ttl=114 time=296.300 ms
```

The client should *not* be able to ping hosts on the upstream LAN:

```
user@MacBook ~ % ping 192.168.7.1
PING 192.168.7.1 (192.168.7.1): 56 data bytes
Request timeout for icmp_seq 0
Request timeout for icmp_seq 1
Request timeout for icmp_seq 2
Request timeout for icmp_seq 3
```

Open a browser and visit this page to check that your Internet traffic is being routed through the VPN tunnel. This page will show the ISP and location that you appear to be connecting from:

https://nordvpn.com/what-is-my-ip/

Also visit this page to check that your DNS queries are being routed through the VPN tunnel as well. If correctly configured, this page should list Cloudflare servers in the same country as the VPN server you are using:

https://nordvpn.com/dns-leak-test/

Done!
