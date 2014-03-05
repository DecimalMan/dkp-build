/* tiny-vmin.c: adjust dkp's minimum voltage, without edify
 *
 * Google's update-binary compresses to a little more than 120 KiB.  A minimal
 * binary to remove the vmin initscript compresses to less than 5 KiB, and a
 * fancier binary will only be slightly larger.
 *
 * Fanciness: renaming the flashed zip can be used to change the new minimum
 * voltage.  A filename of "dkp-vmin-NNN.zip" will result in a NNN mV minimum
 * voltage.
 *
 * To build:
 * arm-linux-musleabi-gcc -Os -s -static -Wall -o tiny-vmin tiny-vmin.c
 */
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mount.h>

#define FNTOK "dkp-vmin-"
#define INITPATH "/system/etc/init.d/00dkp-vmin"

// Lazy write to file
#define iwrite(f, s) write(f, s, strlen(s))
// Print to recovery console
#define rprint(s) iwrite(cmdfd, "ui_print " s "\nui_print\n")

int main(int argc, char **argv) {
	int cmdfd, ffd;
	int ret = 0;
	char *msg = calloc(80, 1);
	char *s = strstr(argv[3], FNTOK);
	char *e = NULL;
	int vmin_i;
	int do_umount = 1;

	if (argc != 4)
		return 1;

	cmdfd = atoi(argv[2]);

	if (s) {
		s += strlen(FNTOK);
		for (e = s; *e >= '0' && *e <= '9'; e++);
		if (*e == '.')
			*e = 0;
		else
			e = NULL;
	}
	if (!e) {
		rprint("Rename me to something like \"dkp-vmin-700.zip\"!");
		return 2;
	}
	vmin_i = atoi(s);
	if (vmin_i > 1500) {
		rprint("Explosion mode engaged.");
		rprint("Have a nice day.");
		return 2;
	}
	if (vmin_i > 1150 || vmin_i < 600) {
		strncat(msg, "ui_print ", 80);
		strncat(msg, s, 80);
		strncat(msg, " mV?  That seems excessive.\nui_print\n", 80);
		iwrite(cmdfd, msg);
		rprint("600 to 1150 mV would be reasonable");
		return 2;
	}


	if (ret = mount("/dev/block/mmcblk0p14", "/system", "ext4",
		MS_NOATIME | MS_NODEV | MS_NODIRATIME, "")) {
		rprint("Can't mount /system!");
		if (errno != EBUSY)
			return errno;
		do_umount = 0;
	}

	rprint("Adjusting minimum voltage...");
	unlink(INITPATH);
	ffd = open(INITPATH, O_WRONLY | O_CREAT | O_EXCL, 0755);
	if (ffd) {
		strncat(msg, "ui_print New minimum voltage is ", 80);
		strncat(msg, s, 80);
		strncat(msg, " mV.\nui_print\n", 80);
		iwrite(cmdfd, msg);

		iwrite(ffd, "#!/system/bin/sh\necho ");
		iwrite(ffd, s);
		iwrite(ffd, " >/sys/devices/system/cpu/cpufreq/dkp/vmin\n");
		close(ffd);
	} else {
		rprint("Adjustment failed!");
		ret = 4;
	}

bail:
	if (do_umount) {
		if (umount("/system")) {
			rprint("Couldn't unmount /system!");
			return -ret;
		}
	}

	return ret;
}
