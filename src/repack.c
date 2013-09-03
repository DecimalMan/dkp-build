/* repack.c -- anykernel, without the anykernel
 * Instead of using a bunch of standard tools, use a single purpose-built tool
 * to inject a new zImage into an existing boot.img.
 *
 * To compile (assuming a musl cross-compiler):
 * arm-linux-musleabi-gcc -Os -s -static -Wall -o repack repack.c
 *
 * To use in an updater-script:
 * package_extract_dir("path/to/repack+zimage", "/cache/somewhere");
 * set_perm(0, 0, 0755, "/cache/somewhere/repack");
 * run_program("/cache/somewhere/repack",
 * 	"/dev/block/kernel_dev",
 * 	"/cache/somewhere/zImage");
 * delete_recursive("/cache/somewhere");
 */
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <string.h>

#include "bootimg.h"

#define RDOFF (0x1500000)
#define PGSZ (2048)
#define SZLIM (8<<20)

/* Calculate pagesize-padded file offset */
static inline void pad_section_offset(int *pos, int len, int pagesize) {
	int rem;
	*pos += len;
	rem = *pos % pagesize;
	if (rem)
		*pos = *pos - rem + pagesize;
}

// Write a section from buffer, seek to start of next section
#define write_section(buf, sz) { \
	for (i = 0; i < sz; ) { \
		int bw = write(kf, buf + i, sz - i); \
		if (bw < 0) \
			return 1; \
		i += bw; \
	} \
	pad_section_offset(&kp, sz, PGSZ); \
	if (lseek(kf, kp, SEEK_SET) < 0) \
		return 1; \
}

int main(int argc, char **argv) {
	struct boot_img_hdr old_hdr;
	struct boot_img_hdr new_hdr = {
		.magic		= BOOT_MAGIC,
		.kernel_addr	= 0x80208000,
		.tags_addr	= 0x80200100,
		.page_size	= PGSZ,
	};
	int kf, zf;
	int kp;

	int i;
	char *rd, *zimg;

	// repack kbdev zimage
	if (argc != 3)
		return 1;

	kf = open(argv[1], O_RDWR);
	if (kf < 0)
		return 1;
	zf = open(argv[2], O_RDONLY);
	if (zf < 0)
		return 1;

	// Pretty sure tools haven't done this in ages, but support it anyway.
	for (i = 0; i <= 512; i++) {
		kp = lseek(kf, i, SEEK_SET);
		read(kf, &old_hdr, sizeof(struct boot_img_hdr));
		if (!memcmp(old_hdr.magic, BOOT_MAGIC, BOOT_MAGIC_SIZE))
			break;
	}
	if (i > 512)
		return 1;
	
	// Set up new boot.img params
	memcpy(new_hdr.name, old_hdr.name, BOOT_NAME_SIZE);
	memcpy(new_hdr.cmdline, old_hdr.cmdline, BOOT_ARGS_SIZE);
	new_hdr.ramdisk_size = old_hdr.ramdisk_size;
	new_hdr.ramdisk_addr = new_hdr.kernel_addr + RDOFF - 0x8000;
	new_hdr.kernel_size = lseek(zf, 0, SEEK_END);
	if (new_hdr.kernel_size < 0)
		return 1;

	// Verify size constraint -- should never be an issue
	i = PGSZ;
	pad_section_offset(&i, new_hdr.kernel_size, PGSZ);
	pad_section_offset(&i, new_hdr.ramdisk_size, PGSZ);
	if (i > SZLIM)
		return 1;

	// Locate & read in old ramdisk
	rd = malloc(old_hdr.ramdisk_size);
	if (!rd)
		return 1;
	pad_section_offset(&kp, sizeof(struct boot_img_hdr), old_hdr.page_size);
	pad_section_offset(&kp, old_hdr.kernel_size, old_hdr.page_size);
	if (lseek(kf, kp, SEEK_SET) < 0)
		return 1;
	for (i = 0; i < old_hdr.ramdisk_size; ) {
		int br = read(kf, rd + i, old_hdr.ramdisk_size - i);
		if (br < 0)
			return 1;
		i += br;
	}

	// Read in new zImage
	zimg = malloc(new_hdr.kernel_size);
	if (!zimg)
		return 1;
	if (lseek(zf, 0, SEEK_SET) < 0)
		return 1;
	for (i = 0; i < new_hdr.kernel_size; ) {
		int br = read(zf, zimg + i, new_hdr.kernel_size - i);
		if (br < 0)
			return 1;
		i += br;
	}

	// Write the new kernel
	kp = lseek(zf, 0, SEEK_SET);
	if (kp)
		return 1;
	write_section(&new_hdr, sizeof(struct boot_img_hdr));
	write_section(zimg, new_hdr.kernel_size);
	write_section(rd, new_hdr.ramdisk_size);

	return 0;
}
