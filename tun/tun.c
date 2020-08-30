#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_ether.h>
#include <linux/if_tun.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define CHECK(X)                       \
  if ((X) < 0) {                       \
    printf("RIP %s %d", #X, __LINE__); \
    exit(0);                           \
  }

#define ARP_ETHERNET 0x0001
#define ARP_IPV4 0x0800
#define ARP_REQUEST 0x0001
#define ARP_REPLY 0x0002

const uint32_t MY_IP = 0x0100530a;  // 10.83.0.1
const char MY_MAC[] = "\x61\x62\x63\x64\x65\x66";

// Ethernet frame (layer 2).
struct eth_hdr {
  unsigned char dmac[6];
  unsigned char smac[6];
  uint16_t ethertype;
  unsigned char payload[];
} __attribute__((packed));

// ARP frame (layer 2).
struct arp_hdr {
  uint16_t hwtype;
  uint16_t protype;
  unsigned char hwsize;
  unsigned char prosize;
  uint16_t opcode;
  unsigned char data[];
} __attribute__((packed));

// IP-specific ARP data (layer 2).
struct arp_ipv4 {
  unsigned char smac[6];
  uint32_t sip;
  unsigned char dmac[6];
  uint32_t dip;
} __attribute__((packed));

// Allocate a tun device. To simplify code, it's not activated
// programatically, so you still need to run this manually:
//
// ip link set dev tap0 up
int tun_alloc(char *dev) {
  struct ifreq ifr;
  int fd, err;

  CHECK(fd = open("/dev/net/tap", O_RDWR));
  memset(&ifr, 0, sizeof(ifr));

  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
  if (*dev) {
    strncpy(ifr.ifr_name, dev, IFNAMSIZ);
  }

  CHECK(ioctl(fd, TUNSETIFF, (void *)&ifr));
  strcpy(dev, ifr.ifr_name);
  return fd;
}

// Handle ARP packet
// Generate response if it's directed at us, otherwise ignore it.
void handle_arp(int tun_fd, struct eth_hdr *hdr) {
  struct arp_hdr *arphdr = (struct arp_hdr *)hdr->payload;

  if (ntohs(arphdr->hwtype) != ARP_ETHERNET) {
    printf("[arp] unknown hardware");
    return;
  }

  if (ntohs(arphdr->protype) != ARP_IPV4) {
    printf("[arp] unknown protocol");
    return;
  }

  if (ntohs(arphdr->opcode) != ARP_REQUEST) {
    printf("[arp] unknown opcode");
    return;
  }

  struct arp_ipv4 *arpdata = (struct arp_ipv4 *)arphdr->data;

  printf("[arp] request\n");
  printf("[arp] from %02x:%02x:%02x:%02x:%02x:%02x\n", arpdata->smac[0],
         arpdata->smac[1], arpdata->smac[2], arpdata->smac[3], arpdata->smac[4],
         arpdata->smac[5]);
  printf("[arp] who-has %d.%d.%d.%d\n", (arpdata->dip >> 0) & 0xFF,
         (arpdata->dip >> 8) & 0xFF, (arpdata->dip >> 16) & 0xFF,
         (arpdata->dip >> 24) & 0xFF);

  if (MY_IP != arpdata->dip) {
    printf("[arp] not relevant to us\n");
    return;
  }

  printf("[arp] response\n");
  memcpy(arpdata->dmac, arpdata->smac, 6);
  arpdata->dip = arpdata->sip;
  memcpy(arpdata->smac, MY_MAC, 6);
  arpdata->sip = MY_IP;
  arphdr->opcode = htons(ARP_REPLY);

  memcpy(hdr->smac, MY_MAC, 6);
  memcpy(hdr->dmac, arpdata->dmac, 6);

  int len = (sizeof(struct eth_hdr) + sizeof(struct arp_hdr) +
             sizeof(struct arp_ipv4));
  CHECK(write(tun_fd, (char *)hdr, len));
}

// Handle a generic ethernet frame. Currently only ARP is supported.
void handle_eth(int tun_fd, struct eth_hdr *packet) {
  int ethtype = ntohs(packet->ethertype);
  if (ethtype == ETH_P_ARP) {
    printf("[eth] incoming arp\n");
    handle_arp(tun_fd, packet);
  } else if (ethtype == ETH_P_IP) {
    printf("[eth] incoming ipv4\n");
  } else if (ethtype == ETH_P_IPV6) {
    printf("[eth] incoming ipv6\n");
  } else {
    printf("[eth] incoming type=%x\n", ethtype);
  }
}

int main() {
  char dev[10];
  int tun_fd = tun_alloc(dev);
  printf("[init] tun %s\n", dev);

  char buf[8192];

  while (true) {
    CHECK(read(tun_fd, buf, sizeof(buf)));
    handle_eth(tun_fd, (struct eth_hdr *)buf);
  }
}
