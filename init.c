#define _GNU_SOURCE

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <sys/mman.h>
#include <sys/wait.h>

#ifndef PROGRAM_SIZE
#error You need to define PROGRAM_SIZE when compiling
#endif
#ifndef BUSYBOX_SIZE
#error You need to define BUSYBOX_SIZE when compiling
#endif
#ifndef SCRIPT_SIZE
#error You need to define SCRIPT_SIZE when compiling
#endif
#ifndef UTILS_SIZE
#error You need to define UTILS_SIZE when compiling
#endif

// Bubblewrap can handle up to 9000 arguments
// And we reserve 1000 for internal use in Conty
#define MAX_ARGS_NUMBER 8000

// Same as setenv but convert value from int to char first
int setenv_int(const char* name, const int value, int overwrite) {
	char str[128];
	sprintf(str, "%d", value);
	return setenv(name, str, overwrite);
}

int main(int argc, char* argv[]) {
    if (argc > MAX_ARGS_NUMBER) {
		fprintf(stderr, "Too many arguments\n");
        return 1;
    }

    char program_path[PATH_MAX] = { 0 };
    readlink("/proc/self/exe", program_path, sizeof(char) * PATH_MAX);
	FILE* current_program = fopen(program_path, "rb");
	fseek(current_program, PROGRAM_SIZE, 0);

	char busybox_content[BUSYBOX_SIZE + 1] = { 0 };
	int busybox_binary = memfd_create("busybox", 0);
	fread(busybox_content, 1, BUSYBOX_SIZE, current_program);
	write(busybox_binary, busybox_content, BUSYBOX_SIZE);

	char script_content[SCRIPT_SIZE + 1] = { 0 };
	fread(script_content, 1, SCRIPT_SIZE, current_program);
	fclose(current_program);

#define ARGN 6
	char* busybox_args[MAX_ARGS_NUMBER + ARGN] =
		{"sh", "-c", "--", script_content, argv[0], program_path};
	char** arg = &busybox_args[ARGN];
    for (size_t i = 1; i < argc; i++) *arg++ = argv[i];
	*arg++ = NULL;
	setenv_int("CONTY_PROGRAM_SIZE", PROGRAM_SIZE, 1);
	setenv_int("CONTY_BUSYBOX_SIZE", BUSYBOX_SIZE, 1);
	setenv_int("CONTY_SCRIPT_SIZE", SCRIPT_SIZE, 1);
	setenv_int("CONTY_UTILS_SIZE", UTILS_SIZE, 1);
	return fexecve(busybox_binary, busybox_args, environ);
	fprintf(stderr, "Failed to execute builtin busybox");
	return EXIT_FAILURE;
}
