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

#define FNTOK "dkp-vmin-"
#define INITPATH "/system/etc/init.d/00dkp-vmin"

// Lazy write to file
#define iwrite(f, s) write(f, s, strlen(s))
// Print to recovery console
#define rprint(s) iwrite(cmdfd, "ui_print " s "\n")

int main(int argc, char **argv) {
	int cmdfd, ffd;
	int ret = 0;
	if (argc != 4)
		return 1;

	cmdfd = atoi(argv[2]);

	rprint("Mounting /system...");
	if (system("mount /system") == -1) {
		rprint("Mount failed!");
		return 1;
	}

	rprint("Adjusting vmin...");
	unlink(INITPATH);
	ffd = open(INITPATH, O_WRONLY | O_CREAT | O_EXCL, 0755);
	if (ffd) {
		char *msg = calloc(80, 1);
		char *vmin = "1150";
		char *s = strstr(argv[3], FNTOK);
		char *e = NULL;
		if (s) {
			s += strlen(FNTOK);
			for (e = s; *e >= '0' && *e <= '9'; e++);
			if (*e == '.')
				*e = 0;
		}
		if (!e)
			s = vmin;

		strncat(msg, "ui_print New vmin is ", 80);
		strncat(msg, s, 80);
		strncat(msg, " mV.\n", 80);
		iwrite(cmdfd, msg);

		iwrite(ffd, "#!/system/bin/sh\necho ");
		iwrite(ffd, s);
		iwrite(ffd, " >/sys/devices/system/cpu/cpufreq/dkp/vmin\n");
		close(ffd);
	} else {
		rprint("Adjustment failed!");
		ret = 1;
	}

	rprint("Unmounting /system...");
	if (system("umount /system") == -1) {
		rprint("Unmount failed!");
		ret = 1;
	}

	return ret;
}
