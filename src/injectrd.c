/* injectrd.c -- inject a new ramdisk into an existing kernel
 *
 * To compile (assuming a musl cross-compiler):
 * arm-linux-musleabi-gcc -Os -s -static -Wall -o injectrd injectrd.c
 *
 * To use:
 * injectrd boot.img <ramdisk.gz
 * mkbootimg | gzip -c | injectrd boot.img
 */
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/user.h>

#include "bootimg.h"

#define CHUNK (16*PAGE_SIZE)
#define puts(s) write(1, s "\n", strlen(s "\n"))

int main(int argc, char **argv) {
	struct boot_img_hdr *hdr;
	int inf, inp, rd_start;
	void *buf;
	int i, rd;

	if (argc != 2) {
		puts("Usage: injectrd boot.img < ramdisk.gz");
		return 1;
	}

	inf = open(argv[1], O_RDWR);
	if (inf < 0) {
		puts("Unable to open boot.img!");
		return 2;
	}

	buf = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE,
		MAP_SHARED | MAP_POPULATE, inf, 0);
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
	rd_start = inp;
	do {
		int wbase = inp & ~(PAGE_SIZE - 1);
		if (posix_fallocate(inf, wbase, CHUNK))
			goto fail;
		buf = mmap(NULL, CHUNK, PROT_READ | PROT_WRITE,
			MAP_SHARED | MAP_POPULATE, inf, wbase);
		if (buf == MAP_FAILED)
			goto fail;
		rd = read(0, buf + (inp - wbase), CHUNK - (inp - wbase));
		if (rd < 0)
			goto fail;
		inp += rd;
		continue;
fail:
		puts("Writing ramdisk failed!");
		return 5;
	} while (rd > 0);

	ftruncate(inf, inp);
	hdr->ramdisk_size = inp - rd_start;
	return 0;
}
