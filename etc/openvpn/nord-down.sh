#!/usr/bin/env bash

ip route del default table wificlient
ip route replace blackhole 1.1.1.1/32
ip route replace blackhole 1.0.0.1/32
iptables -t nat -D POSTROUTING -o $1 -j MASQUERADE
