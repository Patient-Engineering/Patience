// Just another hypervisor

#include <err.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>

#define CHECK(X)                       \
  if ((X) < 0) {                       \
    err(X, "fail line: %d", __LINE__); \
  }

int secure_function(char *text) {
  while (*text) {
    char what = *text;
    asm volatile(
        "mov $0x3f8, %%edx\n"
        "mov %0, %%al\n"
        "out %%al, (%%dx)\n"
        :
        : "r"(what)
        : "%edx", "%eax");
    text++;
  }
  asm volatile("hlt");
}

void init_code(char *outptr) {
  char *inptr = (char *)secure_function;
  while (*outptr++ = *inptr++, inptr[-1] != '\xf4')
    ;
}

int main() {
  char code[4096] = {};
  init_code(code);

  int kvmfd;
  CHECK(kvmfd = open("/dev/kvm", O_RDWR | O_CLOEXEC));
  printf("[init] /dev/kvm opened (fd %d)\n", kvmfd);

  int kvm_api;
  CHECK(kvm_api = ioctl(kvmfd, KVM_GET_API_VERSION, NULL));
  if (kvm_api != 12) {
    errx(1, "KVM_GET_API_VERSION %d, expected 12", kvm_api);
  }

  int vmfd;
  CHECK(vmfd = ioctl(kvmfd, KVM_CREATE_VM, 0));
  printf("[init] vm created (fd %d)\n", vmfd);

  const size_t mem_size = 0x10000;
  void *mem_page = mmap(NULL, mem_size, PROT_READ | PROT_WRITE,
                        MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  memcpy(mem_page, code, sizeof(code));
  strcpy((char *)mem_page + 0x500, ":kotchivaya:\n");

  struct kvm_userspace_memory_region mem_region = {
      .slot = 0,
      .flags = 0,
      .guest_phys_addr = 0,
      .memory_size = mem_size,
      .userspace_addr = (uint64_t)mem_page,
  };
  CHECK(ioctl(vmfd, KVM_SET_USER_MEMORY_REGION, &mem_region));
  printf("[init] code segment allocated\n");

  int vcpufd;
  CHECK(vcpufd = ioctl(vmfd, KVM_CREATE_VCPU, 0));
  printf("[init] vcpu created (fd %d)\n", vcpufd);

  size_t mmap_size = ioctl(kvmfd, KVM_GET_VCPU_MMAP_SIZE, NULL);
  struct kvm_run *run = (struct kvm_run *)mmap(
      NULL, mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpufd, 0);

  struct kvm_regs regs = {
      .rip = 0,
      .rdi = 0x500,
      .rsp = 0xf00,
      .rflags = 0x2,
  };
  ioctl(vcpufd, KVM_SET_REGS, &regs);
  printf("[init] regs initialised\n");

  struct kvm_sregs sregs;
  ioctl(vcpufd, KVM_GET_SREGS, &sregs);

  uint64_t pml4_addr = 0x1000;
  uint64_t pdpt_addr = 0x2000;
  uint64_t pd_addr = 0x3000;

  *(uint64_t *)((char *)mem_page + pml4_addr) = 3 | pdpt_addr;
  *(uint64_t *)((char *)mem_page + pdpt_addr) = 3 | pd_addr;
  *(uint64_t *)((char *)mem_page + pd_addr) = 3 | 0x80;

  sregs.cr3 = pml4_addr;
  sregs.cr4 = 1 << 5;
  sregs.cr0 = 0x80050033;
  sregs.efer = 0x500;

  struct kvm_segment seg = {
      .base = 0,
      .limit = 0xffffffff,
      .selector = 1 << 3,
      .present = 1,
      .type = 11,
      .dpl = 0,
      .db = 0,
      .s = 1,
      .l = 1,
      .g = 1,
  };
  sregs.cs = seg;
  seg.type = 3;
  seg.selector = 2 << 3;
  sregs.ds = sregs.es = sregs.fs = sregs.gs = sregs.ss = seg;

  ioctl(vcpufd, KVM_SET_SREGS, &sregs);
  printf("[init] sregs initialised\n");

  printf("[init] entering main loop\n");
  while (1) {
    ioctl(vcpufd, KVM_RUN, NULL);
    switch (run->exit_reason) {
      case KVM_EXIT_HLT:
        printf("[loop] KVM_EXIT_HLT\n");
        return 0;
      case KVM_EXIT_IO:
        if (run->io.direction == KVM_EXIT_IO_OUT && run->io.port == 0x3f8) {
          putchar(*(((char *)run) + run->io.data_offset));
        } else {
          errx(1, "[loop] unknown KVM_EXIT_IO");
        }
        break;
      case KVM_EXIT_FAIL_ENTRY:
        errx(1, "[loop] KVM_EXIT_FAIL_ENTRY");
      case KVM_EXIT_INTERNAL_ERROR:
        errx(1, "[loop] KVM_EXIT_INTERNAL_ERROR");
    }
  }
}
