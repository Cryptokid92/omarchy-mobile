// SPDX-License-Identifier: MIT
// devmem: read or write one 32-bit hardware register through /dev/mem.
// Usage: devmem <address> [value]
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: devmem <address> [value]\n");
		return 1;
	}
	uint64_t addr = strtoull(argv[1], NULL, 0);
	long page = sysconf(_SC_PAGESIZE);
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		perror("/dev/mem");
		return 1;
	}
	volatile uint8_t *map = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED,
				     fd, addr & ~(uint64_t)(page - 1));
	if (map == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	volatile uint32_t *reg = (volatile uint32_t *)(map + (addr & (page - 1)));
	if (argc > 2)
		*reg = (uint32_t)strtoul(argv[2], NULL, 0);
	printf("0x%08x\n", *reg);
	return 0;
}
