// SPDX-License-Identifier: MIT
/*
 * One keyboard on /dev/uinput. One byte on stdin writes one EV_KEY,
 * then SYN_REPORT, because evdev holds the key until the sync.
 * The process stays up until stdin closes, so the event node stays.
 * SEAT_DRY_RUN prints that event and does not open a device.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifdef SEAT_DRY_RUN

int main(void)
{
	printf("struct input_event { type = EV_KEY, code = KEY_A, value = 1 }\n");
	return 0;
}

#else

#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/uinput.h>

/* Linux keycodes follow the keyboard, not the alphabet. KEY_A is 30. */
static const unsigned short letter_code[26] = {
	KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G,
	KEY_H, KEY_I, KEY_J, KEY_K, KEY_L, KEY_M, KEY_N,
	KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T,
	KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z
};

static const unsigned short digit_code[10] = {
	KEY_0, KEY_1, KEY_2, KEY_3, KEY_4,
	KEY_5, KEY_6, KEY_7, KEY_8, KEY_9
};

static int code_for_byte(unsigned char b, unsigned short *code)
{
	if (b >= 'a' && b <= 'z') {
		*code = letter_code[b - 'a'];
		return 0;
	}
	if (b >= 'A' && b <= 'Z') {
		*code = letter_code[b - 'A'];
		return 0;
	}
	if (b >= '0' && b <= '9') {
		*code = digit_code[b - '0'];
		return 0;
	}
	return -1;
}

static int enable(int fd, unsigned long req, unsigned int bit)
{
	if (ioctl(fd, req, bit) < 0) {
		perror("ioctl");
		return -1;
	}
	return 0;
}

static int write_event(int fd, unsigned short type, unsigned short code, int value)
{
	struct input_event ev;

	memset(&ev, 0, sizeof(ev));
	ev.type = type;
	ev.code = code;
	ev.value = value;
	if (write(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev)) {
		perror("write");
		return -1;
	}
	return 0;
}

int main(void)
{
	int fd;
	int i;
	unsigned char byte;
	unsigned short code;
	struct uinput_setup setup;
	ssize_t n;

	fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (fd < 0) {
		perror("/dev/uinput");
		return 1;
	}

	if (enable(fd, UI_SET_EVBIT, EV_KEY) < 0)
		return 1;
	for (i = 0; i < 26; i++) {
		if (enable(fd, UI_SET_KEYBIT, letter_code[i]) < 0)
			return 1;
	}
	for (i = 0; i < 10; i++) {
		if (enable(fd, UI_SET_KEYBIT, digit_code[i]) < 0)
			return 1;
	}

	memset(&setup, 0, sizeof(setup));
	setup.id.bustype = BUS_VIRTUAL;
	snprintf(setup.name, sizeof(setup.name), "husky-seat");
	if (ioctl(fd, UI_DEV_SETUP, &setup) < 0) {
		perror("UI_DEV_SETUP");
		return 1;
	}
	if (ioctl(fd, UI_DEV_CREATE) < 0) {
		perror("UI_DEV_CREATE");
		return 1;
	}

	n = read(STDIN_FILENO, &byte, 1);
	if (n != 1) {
		fprintf(stderr, "bridge: expected one byte on stdin\n");
		return 1;
	}
	if (code_for_byte(byte, &code) < 0) {
		fprintf(stderr, "bridge: byte is not a letter or a digit\n");
		return 1;
	}
	if (write_event(fd, EV_KEY, code, 1) < 0)
		return 1;
	if (write_event(fd, EV_SYN, SYN_REPORT, 0) < 0)
		return 1;

	for (;;) {
		n = read(STDIN_FILENO, &byte, 1);
		if (n <= 0)
			break;
	}
	return 0;
}

#endif
