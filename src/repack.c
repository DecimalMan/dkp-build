#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>

#include "bootimg.h"

int main(int argc, char **argv) {
	struct boot_img_hdr old_hdr;
	struct boot_img_hdr new_hdr = {
		.magic		= BOOT_MAGIC,
		.kernel_addr	= 0x80208000,
		.tags_addr	= 0x80200100,
		.page_size	= 2048,
	};
	int inf, zf, outf;
	int inp;

	long tmp;
	char *p;

	int i;
	char *rd, zimg;

	// repack infile zimage outfile rdoff cmdline
	if (argc != 6)
		return 1;

	strncpy(new_hdr.cmdline, argv[5], BOOT_ARGS_SIZE);
	tmp = strtol(argv[4], &p, 16);
	if (*p != 0)
		return 1;
	new_hdr.ramdisk_addr = new_hdr.kernel_addr + tmp - 0x8000;

	inf = open(argv[1], O_RDONLY);
	if (inf < 0)
		return 1;
	zf = open(argv[2], O_RDONLY);
	if (zf < 0)
		return 1;
	outf = open(argv[3], O_WRONLY | O_TRUNC | O_CREAT, 0600);
	if (outf < 0)
		return 1;

	for (i = 0; i <= 512; i++) {
		inp = lseek(inf, i, SEEK_SET);
		read(inf, &old_hdr, sizeof(struct boot_img_hdr));
		if (!memcmp(old_hdr.magic, BOOT_MAGIC, BOOT_MAGIC_SIZE))
			break;
	}
	if (i > 512)
		return 1;
	
	new_hdr.kernel_size = lseek(zf, 0, SEEK_END);
	if (new_hdr.kernel_size < 0)
		return 1;
	
	memcpy(new_hdr.name, old_hdr.name, BOOT_NAME_SIZE);
	new_hdr.ramdisk_size = old_hdr.ramdisk_size;

	inp += sizeof(struct boot_img_hdr);
	inp = (inp & ~(old_hdr.page_size - 1)) +
		((inp & (old_hdr.page_size - 1)) ? old_hdr.page_size : 0);
	inp += old_hdr.kernel_size;
	inp = (inp & ~(old_hdr.page_size - 1)) +
		((inp & (old_hdr.page_size - 1)) ? old_hdr.page_size : 0);
	
	rd = malloc(old_hdr.ramdisk_size);
	if (!rd)
		return 1;
	if (lseek(inf, inp, SEEK_SET) < 0)
		return 1;
	for (i = 0; i < old_hdr.ramdisk_size; ) {
		int br = read(inf, rd + i, old_hdr.ramdisk_size - i);
		if (br < 0)
			return 1;
		i += br;
	}

	p = calloc(1, new_hdr.page_size);
	if (!p)
		return 1;
	for (i = 0; i < sizeof(struct boot_img_hdr); ) {
		int bw = write(outf, &new_hdr + i, sizeof(struct boot_img_hdr) - i);
		if (bw < 0)
			return 1;
		i += bw;
	}
	for (; i & (new_hdr.page_size - 1); ) {
		int bw = write(outf, p, new_hdr.page_size - (i & (new_hdr.page_size - 1)));
		if (bw < 0)
			return 1;
		i += bw;
	}
	if (lseek(zf, 0, SEEK_SET) < 0)
		return 1;
	for (int j = 0, br = 0; j < new_hdr.kernel_size; ) {
		if (!br) {
			br = read(zf, p, new_hdr.page_size);
			if (br < 0)
				return 1;
		}
		int bw = write(outf, p, br);
		if (bw < 0)
			return 1;
		br -= bw;
		i += bw;
		j += bw;
	}
	memset(p, 0, new_hdr.page_size);
	for (; i & (new_hdr.page_size - 1); ) {
		int bw = write(outf, p, new_hdr.page_size - (i & (new_hdr.page_size - 1)));
		if (bw < 0)
			return 1;
		i += bw;
	}
	for (int j = 0; j < old_hdr.ramdisk_size; ) {
		int bw = write(outf, rd + j, old_hdr.ramdisk_size - j);
		if (bw < 0)
			return 1;
		i += bw;
		j += bw;
	}
	for (; i & (new_hdr.page_size - 1); ) {
		int bw = write(outf, p, new_hdr.page_size - (i & (new_hdr.page_size - 1)));
		if (bw < 0)
			return 1;
		i += bw;
	}

	return 0;
}
