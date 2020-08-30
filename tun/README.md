# tun.c

A simple and pretty naive ARP client using TUN device.

## How to use

```
$ make
$ sudo tun
$ sudo ip link set dev tap0 up
$ arping -I tap0 10.83.0.1
```


