#!/bin/bash

iptables -C $@ >/dev/null 2>&1 || iptables -A $@