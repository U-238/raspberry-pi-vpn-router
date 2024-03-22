#!/usr/bin/env bash

ip route replace default via $4 dev $1 table wificlient
ip route replace 1.1.1.1/32 via $4 dev $1
ip route replace 1.0.0.1/32 via $4 dev $1
iptables -t nat -A POSTROUTING -o $1 -j MASQUERADE
