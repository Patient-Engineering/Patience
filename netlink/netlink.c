// Dump current routes and links using AF_NETLINK socket.

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/types.h>

#include <unistd.h>

#include <linux/netlink.h>
#include <linux/rtnetlink.h>

#define CHECK(X)                       \
  if ((X) < 0) {                       \
    printf("RIP %s %d", #X, __LINE__); \
    exit(0);                           \
  }

void print_link(struct nlmsghdr *h) {
  struct ifinfomsg *iface = NLMSG_DATA(h);
  int len = h->nlmsg_len - NLMSG_LENGTH(sizeof(*iface));

  printf("link {\n");
  for (struct rtattr *attribute = IFLA_RTA(iface); RTA_OK(attribute, len);
       attribute = RTA_NEXT(attribute, len)) {
    if (attribute->rta_type == IFLA_IFNAME) {
      char *ifname = (char *)RTA_DATA(attribute);
      printf("  name = %s;\n", ifname);
    } else if (attribute->rta_type == IFLA_ADDRESS) {
      unsigned char *addr = (char *)RTA_DATA(attribute);
      printf("  hwaddr = %02x:%02x:%02x:%02x:%02x:%02x;\n", addr[0], addr[1],
             addr[2], addr[3], addr[4], addr[5]);
    }
  }
  printf("}\n");
}

void print_route(struct nlmsghdr *h) {
  struct rtmsg *route_entry = (struct rtmsg *)NLMSG_DATA(h);
  unsigned char route_netmask = route_entry->rtm_dst_len;
  unsigned char route_protocol = route_entry->rtm_protocol;
  int len = RTM_PAYLOAD(h);

  printf("route {\n");
  printf("  proto %d;\n", route_entry->rtm_protocol);
  for (struct rtattr *attribute = RTM_RTA(route_entry); RTA_OK(attribute, len);
       attribute = RTA_NEXT(attribute, len)) {
    char address[32];
    if (attribute->rta_type == RTA_DST) {
      inet_ntop(AF_INET, RTA_DATA(attribute), address, sizeof(address));
      printf("  dest = %s/%d;\n", address, route_entry->rtm_dst_len);
    } else if (attribute->rta_type == RTA_SRC) {
      inet_ntop(AF_INET, RTA_DATA(attribute), address, sizeof(address));
      printf("  src = %s/%d;\n", address, route_entry->rtm_dst_len);
    } else if (attribute->rta_type == RTA_PREFSRC) {
      inet_ntop(AF_INET, RTA_DATA(attribute), address, sizeof(address));
      printf("  prefsrc = %s/%d;\n", address, route_entry->rtm_dst_len);
    } else if (attribute->rta_type == RTA_GATEWAY) {
      inet_ntop(AF_INET, RTA_DATA(attribute), address, sizeof(address));
      printf("  via = %s;\n", address);
    }
  }
  printf("}\n");
}

bool netlink_parse(int fd, struct sockaddr_nl *kernel) {
  char reply[8192];
  struct iovec io;
  memset(&io, 0, sizeof(struct iovec));
  io.iov_base = reply;
  io.iov_len = sizeof(reply);

  struct msghdr reply_msg;
  memset(&reply_msg, 0, sizeof(reply_msg));
  reply_msg.msg_iov = &io;
  reply_msg.msg_iovlen = 1;
  reply_msg.msg_name = kernel;
  reply_msg.msg_namelen = sizeof(*kernel);

  int len = recvmsg(fd, &reply_msg, 0);

  for (struct nlmsghdr *nh = (struct nlmsghdr *)reply; NLMSG_OK(nh, len);
       nh = NLMSG_NEXT(nh, len)) {
    if (nh->nlmsg_type == NLMSG_DONE) {
      return false;
    }

    if (nh->nlmsg_type == NLMSG_ERROR) {
      printf("RIP\n");
      continue;
    } else if (nh->nlmsg_type == RTM_NEWLINK) {
      print_link(nh);
    } else if (nh->nlmsg_type == RTM_NEWROUTE) {
      print_route(nh);
    } else {
      printf("a co to za smieci %d\n", nh->nlmsg_type);
    }
  }
  return true;
}

struct sockaddr_nl make_socket(pid_t pid) {
  struct sockaddr_nl sock;
  memset(&sock, 0, sizeof(struct sockaddr_nl));
  sock.nl_family = AF_NETLINK;
  sock.nl_pid = pid;
  sock.nl_groups = 0;
  return sock;
}

void netlink_request(int fd, int req, struct sockaddr_nl *kernel, pid_t pid) {
  struct nlmsghdr hdr;
  memset(&hdr, 0, sizeof(hdr));
  hdr.nlmsg_len = NLMSG_LENGTH(sizeof(struct rtgenmsg));
  hdr.nlmsg_type = req;
  hdr.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
  hdr.nlmsg_seq = 1;
  hdr.nlmsg_pid = pid;

  struct rtgenmsg gen;
  memset(&gen, 0, sizeof(gen));
  gen.rtgen_family = AF_INET;

  struct iovec io[2];
  io[0].iov_base = &hdr;
  io[0].iov_len = sizeof(struct nlmsghdr);

  io[1].iov_base = &gen;
  io[1].iov_len = sizeof(struct rtgenmsg);

  struct msghdr msg;
  memset(&msg, 0, sizeof(msg));
  msg.msg_iov = &io[0];
  msg.msg_iovlen = 2;
  msg.msg_name = kernel;
  msg.msg_namelen = sizeof(*kernel);

  sendmsg(fd, (struct msghdr *)&msg, 0);
}

int main() {
  pid_t pid = getpid();

  struct sockaddr_nl local = make_socket(pid);
  int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
  bind(fd, (struct sockaddr *)&local, NETLINK_ROUTE);

  struct sockaddr_nl kernel = make_socket(0);

  netlink_request(fd, RTM_GETLINK, &kernel, pid);
  while (netlink_parse(fd, &kernel))
    ;

  netlink_request(fd, RTM_GETROUTE, &kernel, pid);
  while (netlink_parse(fd, &kernel))
    ;
}
