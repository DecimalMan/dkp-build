/* extractrd.c -- extract the ramdisk from an existing boot.img
 *
 * To compile (assuming a musl cross-compiler):
 * arm-linux-musleabi-gcc -Os -s -static -Wall -o extractrd extractrd.c
 *
 * To use:
 * extractrd boot.img >ramdisk.gz
 * extractrd boot.img | gunzip -c | cpio -i
 */
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/user.h>

#include "bootimg.h"

#define puts(s) write(1, s "\n", strlen(s "\n"))

int main(int argc, char **argv) {
	struct boot_img_hdr *hdr;
	int inf, inp;
	void *buf;
	int i;

	if (argc != 2) {
		puts("Usage: extractrd boot.img > ramdisk.gz");
		return 1;
	}

	inf = open(argv[1], O_RDONLY);
	if (inf < 0) {
		puts("Unable to open boot.img!");
		return 2;
	}

	buf = mmap(NULL, PAGE_SIZE, PROT_READ, MAP_PRIVATE | MAP_POPULATE, inf, 0);
	if (buf == MAP_FAILED) {
		puts("mmap() failed!");
		return 3;
	}
	for (i = 0; i < 512; i++) {
		hdr = (struct boot_img_hdr *)(buf + i);
		if (!memcmp(&hdr->magic, BOOT_MAGIC, BOOT_MAGIC_SIZE))
			break;
	}
	if (i > 512) {
		puts("Invalid boot.img!");
		return 4;
	}

	inp = hdr->page_size + hdr->kernel_size;
	if (inp & (hdr->page_size - 1))
		inp = (inp & ~(hdr->page_size - 1)) + hdr->page_size;
	i = inp & (PAGE_SIZE - 1);
	buf = mmap(NULL, hdr->ramdisk_size + PAGE_SIZE, PROT_READ,
		MAP_PRIVATE, inf, inp & ~(PAGE_SIZE - 1));
	if (buf == MAP_FAILED) {
		puts("mmap() failed!");
		return 5;
	}
	buf += i;

	madvise(buf, hdr->ramdisk_size, MADV_WILLNEED);
	for (i = 0; i < hdr->ramdisk_size; ) {
		int wr = write(1, buf + i, hdr->ramdisk_size - i);
		if (wr < 0) {
			puts("write() failed!");
			return 6;
		}
		i += wr;
	}

	return 0;
}
