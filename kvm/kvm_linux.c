// Just another hypervisor

#include <asm/bootparam.h>
#include <err.h>
#include <fcntl.h>
#include <linux/kvm.h>
#include <linux/kvm_para.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define CHECK(X)                       \
  if ((X) < 0) {                       \
    err(X, "fail line: %d", __LINE__); \
  }

int main(int argc, char *argv[]) {
  if (argc != 2) {
    printf("[init] usage: %s [image]\n", argv[0]);
    return 1;
  }

  printf("[init] open the KVM device\n");
  int kvmfd;
  CHECK(kvmfd = open("/dev/kvm", O_RDWR | O_CLOEXEC));
  printf("[init] /dev/kvm opened (fd %d)\n", kvmfd);

  printf("[init] ensure that kernel supports kvm\n");
  int kvm_api;
  CHECK(kvm_api = ioctl(kvmfd, KVM_GET_API_VERSION, NULL));
  if (kvm_api != 12) {
    errx(1, "KVM_GET_API_VERSION %d, expected 12", kvm_api);
  }

  printf("[init] create the vm object\n");
  int vmfd;
  CHECK(vmfd = ioctl(kvmfd, KVM_CREATE_VM, 0));
  printf("[init] vm created (fd %d)\n", vmfd);

  printf("[init] create irqchip\n");
  CHECK(ioctl(vmfd, KVM_CREATE_IRQCHIP, 0));

  printf("[init] create PIT2\n");
  struct kvm_pit_config pit = {
      .flags = 0,
  };
  CHECK(ioctl(vmfd, KVM_CREATE_PIT2, &pit));

  printf("[init] allocate memory for VM\n");
  const size_t mem_size = 1 << 30;  // 1 GiB.
  char *mem_page = mmap(NULL, mem_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mem_page == 0) {
    printf("[init] failed to allocate memory for VM\n");
  }

  printf("[init] set VM memory\n");
  struct kvm_userspace_memory_region mem_region = {
      .slot = 0,
      .flags = 0,
      .guest_phys_addr = 0,
      .memory_size = mem_size,
      .userspace_addr = (uint64_t)mem_page,
  };
  CHECK(ioctl(vmfd, KVM_SET_USER_MEMORY_REGION, &mem_region));

  printf("[init] create vcpu\n");
  int vcpufd;
  CHECK(vcpufd = ioctl(vmfd, KVM_CREATE_VCPU, 0));
  printf("[init] vcpu created (fd %d)\n", vcpufd);

  printf("[init] init kvm regs\n");
  struct kvm_regs regs = {
      .rip = 0x100000,
      .rsi = 0x10000,
      .rflags = 0x2,
  };
  CHECK(ioctl(vcpufd, KVM_SET_REGS, &regs));

  printf("[init] init kvm sregs\n");
  struct kvm_sregs sregs;
  CHECK(ioctl(vcpufd, KVM_GET_SREGS, &sregs));

  struct kvm_segment *segs[] = {&sregs.cs, &sregs.ds, &sregs.es,
                                &sregs.ss, &sregs.gs, &sregs.fs};
  for (int i = 0; i < sizeof(segs) / sizeof(*segs); i++) {
    segs[i]->base = 0;
    segs[i]->limit = 0xFFFFFFFF;
    segs[i]->g = 1;
  }
  sregs.cs.db = 1;
  sregs.ss.db = 1;
  sregs.cr0 |= 1;
  CHECK(ioctl(vcpufd, KVM_SET_SREGS, &sregs));

  printf("[init] init cpuid\n");
  struct {
    uint32_t nent;
    uint32_t padding;
    struct kvm_cpuid_entry2 entries[100];
  } kvm_cpuid;
  kvm_cpuid.nent = sizeof(kvm_cpuid.entries) / sizeof(kvm_cpuid.entries[0]);
  CHECK(ioctl(kvmfd, KVM_GET_SUPPORTED_CPUID, &kvm_cpuid));
  CHECK(ioctl(vcpufd, KVM_SET_CPUID2, &kvm_cpuid));

  printf("[init] open kernel image\n");
  int imgfd;
  CHECK(imgfd = open(argv[1], O_RDONLY));

  printf("[init] stat kernel image\n");
  struct stat imgst;
  CHECK(fstat(imgfd, &imgst));

  printf("[init] mmap kernel image\n");
  void *data =
      mmap(NULL, imgst.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, imgfd, 0);
  CHECK(close(imgfd));

  printf("[init] initialise boot params\n");
  struct boot_params *boot = (struct boot_params *)(mem_page + 0x10000);
  void *cmdline = (void *)(mem_page + 0x20000);
  void *kernel = (void *)(mem_page + 0x100000);

  memset(boot, 0, sizeof(struct boot_params));
  memmove(boot, data, sizeof(struct boot_params));
  size_t setup_sectors = boot->hdr.setup_sects;
  size_t setupsz = (setup_sectors + 1) * 512;
  boot->hdr.vid_mode = 0xFFFF;
  boot->hdr.type_of_loader = 0xFF;
  boot->hdr.ramdisk_image = 0x0;
  boot->hdr.ramdisk_size = 0x0;
  boot->hdr.loadflags |= CAN_USE_HEAP | 0x01 | KEEP_SEGMENTS;
  boot->hdr.heap_end_ptr = 0xFE00;
  boot->hdr.ext_loader_ver = 0x0;
  boot->hdr.cmd_line_ptr = 0x20000;
  memset(cmdline, 0, boot->hdr.cmdline_size);
  memcpy(cmdline, "console=ttyS0", 14);
  memmove(kernel, (char *)data + setupsz, imgst.st_size - setupsz);

  printf("[init] allocate kvm run\n");
  int run_size = ioctl(kvmfd, KVM_GET_VCPU_MMAP_SIZE, 0);
  struct kvm_run *run =
      mmap(0, run_size, PROT_READ | PROT_WRITE, MAP_SHARED, vcpufd, 0);
  printf("[init] entering main loop\n");
  while (1) {
    CHECK(ioctl(vcpufd, KVM_RUN, NULL));
    switch (run->exit_reason) {
      case KVM_EXIT_HLT:
      case KVM_EXIT_SHUTDOWN:
        printf("[loop] clean exit (%d)\n", run->exit_reason);
        return 0;
      case KVM_EXIT_IO:
        if (run->io.direction == KVM_EXIT_IO_OUT && run->io.port == 0x3f8) {
          uint32_t size = run->io.size;
          uint64_t offset = run->io.data_offset;
          printf("%.*s", size * run->io.count, (char *)run + offset);
        } else if (run->io.port == 0x3f8 + 5 &&
                   run->io.direction == KVM_EXIT_IO_IN) {
          char *value = (char *)run + run->io.data_offset;
          *value = 0x20;
        }
        break;
      default:
        printf("[loop] exit reason: %d\n", run->exit_reason);
    }
  }
}
