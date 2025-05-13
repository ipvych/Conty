#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <time.h>
#include <limits.h>
#include <utime.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/wait.h>

#ifndef PROGRAM_SIZE
#error You need to define PROGRAM_SIZE when compiling
#endif

// Bubblewrap can handle up to 9000 arguments
// And we reserve 1000 for internal use in Conty
#define MAX_ARGS_NUMBER 8000

struct content_marker {
    mode_t mode;
    off_t size;
    char name[PATH_MAX];
};

// printf to stderr
#define eprintf(...) fprintf (stderr, __VA_ARGS__)

// Execute program with provided arguments.
// Returns exit code of program on completion or -1 on error
int exec_prog(char* const argv[]) {
    int status;
    pid_t pid;
    if ((pid = fork()) == 0) {
        if (execve(argv[0], argv, NULL) == -1) return -1;
    }
    if (pid == -1) return -1;
    if (waitpid(pid, &status, 0) == -1) return -1;
    return WEXITSTATUS(status);
}

// Set access and modification time of file at path dst to that of src
int touch_r(const char* src, const char* dst) {
    struct stat st;
    struct utimbuf new_times;
    if (stat(src, &st) == -1) return -1;
    new_times.actime = st.st_atime;
    new_times.modtime = st.st_mtime;
    if (utime(dst, &new_times) == -1) return -1;
    return 0;
}


// Create directory if it does not already exist
// Return nonzero status when path exists but is not a directory
int mkdir_maybe(const char* path, mode_t mode) {
    struct stat st;
    if (stat(path, &st) == 0) return !S_ISDIR(st.st_mode);
    return mkdir(path, mode);
}

// Adapted from https://gist.github.com/JonathonReinhart/8c0d90191c38af2dcadb102c4e202950
// Recursively create directory dir
int mkdir_p(char* dir) {
    const mode_t mode = 0755;
    for (char* p = &dir[1]; *p; p++) {
        if (*p == '/') {
            // Temporarily truncate
            *p = '\0';
            if (mkdir_maybe(dir, mode) != 0) return -1;
            *p = '/';
        }
    }
    if (mkdir_maybe(dir, mode) != 0) return -1;
    return 0;
}

// Replace all occurences of / in p with !
// Returns nonzero if p is empty or consists of only ".." or "."
int sanitize_path(char* p) {
    size_t len = strlen(p);
    for (size_t i = 0; i < len; i++) {
        if (p[i] == '/') p[i] = '!';
    }
    return !strncmp(p, "..", len);
}

// Convert str which is an octal representation of file mode to mode_t structure
// Taken from https://stackoverflow.com/questions/73016549
int string_to_filemode(const char* str, mode_t* mode) {
    char* end = NULL;
    *mode = (mode_t)strtol(str, &end, 8);
    return !end;
}

// Catenate dst with src ensuring slash between them is present.  Returns dst
char* join_path(char* dst, const char* src) {
    size_t len;
    len = strlen(dst);
    if (dst[len - 1] != '/' && src[0] != '/') {
        stpcpy(dst + len, "/");
        len++;
        dst[len] = '\0';
    }
    stpcpy(dst + len, src);
    return dst;
}

// Write num bytes from src to dst
// Return number of bytes written which should be equal to num on success
off_t copy_bytes(FILE* src, FILE* dst, off_t num) {
    if (num < 0) return 0;
    off_t bytes_written = 0;
    off_t block_size = 16364;
    void* buf[block_size];
    while (num > 0) {
        if (block_size > num) {
            block_size = num;
        }
        fread(buf, 1, block_size, src);
        bytes_written += fwrite(buf, 1, block_size, dst);
        num -= block_size;
    }
    return bytes_written;
}

// Return path to file relative to conty directory
char* get_conty_file(const char* file) {
    char* rv = malloc(PATH_MAX * sizeof(char));
    char* xdg_data_home = getenv("XDG_DATA_HOME");
    if (xdg_data_home != NULL) {
        strcpy(rv, xdg_data_home);
    }
    else {
        char* home = getenv("HOME");
        if (home == NULL) return NULL;
        strcpy(rv, home);
        join_path(rv, "/.local/share");
    }
    join_path(rv, "/conty");
    return join_path(rv, file);
}

// Prepend path to environment variable var separating two with :
int prepend_env_path(const char* var, const char* path) {
    char* v = getenv(var);
    if (v == NULL || strcmp(v, "") == 0) {
        return setenv(var, path, 1);
    }
    size_t path_len = strlen(path);
    char tmp[(sizeof(char) * (strlen(v) + path_len)) + 2];
    strcpy(tmp, path);
    char* p = stpcpy(tmp + path_len, ":");
    stpcpy(p, v);
    return setenv(var, tmp, 1);
}

int main(int argc, char* argv[]) {
    if (argc > MAX_ARGS_NUMBER) {
        eprintf("Too many arguments\n");
        return 1;
    }

    char* content_path = get_conty_file("/content");
    char* utils_path = get_conty_file("/utils");
    char* extraction_marker_path = get_conty_file("/extraction_marker");

    if (!content_path || !utils_path || !extraction_marker_path) {
        eprintf("Unable to determine base directory for conty to store files in."
                " Ensure either XDG_DATA_HOME or HOME environment variables are set\n");
        return 1;
    }

    char program_path[PATH_MAX] = { 0 };
    readlink("/proc/self/exe", program_path, sizeof(char) * PATH_MAX);
    struct stat st;
    stat(program_path, &st);
    time_t current_program_mtime = st.st_mtime;
    if (stat(extraction_marker_path, &st) == 0 && st.st_mtime >= current_program_mtime) {
        goto exec;
    }

    eprintf("Extracting conty...\n");
    FILE* current_program = fopen(program_path, "r");
    struct content_marker markers[64];
    size_t markers_len = 0;
    const char* marker_end = "@CONTY_MARKER_END@\n";
    char* line = NULL;
    size_t nread, size;
    fseek(current_program, PROGRAM_SIZE, 0);
    for (;;) {
        if ((nread = getline(&line, &size, current_program)) == -1) {
            eprintf("Encountered error while reading conty header\n");
            return 1;
        }
        if (strncmp(line, marker_end, nread) == 0) break;

        char *end = NULL;
        struct content_marker m;
        m.mode = (mode_t)strtol(strtok(line, "@"), &end, 8);
        if (!end) {
            perror("Invalid file mode found in conty header. Defaulting to 0644\n");
            m.mode = (mode_t)0644;
        }
        m.size = strtoll(strtok(NULL, "@"), &end, 10);
        if (!end) {
            perror("Invalid file size found in conty header");
            return 1;
        }
        strcpy(m.name, strtok(NULL, "\n"));
        if (sanitize_path(m.name) != 0) {
            eprintf("Invalid name found in conty header\n");
            return 1;
        }
        markers[markers_len++] = m;
    }
    if (markers_len == 0) {
        eprintf("Did not found any files to extract\n");
        return 1;
    }

    mkdir_p(content_path);
    char out_path[PATH_MAX];
    for (size_t i = 0; i < markers_len; i++) {
        strcpy(out_path, content_path);
        join_path(out_path, markers[i].name);
        FILE* out = fopen(out_path, "wb");
        if (out == NULL) {
            eprintf("Unable to open %s for writing: ", out_path);
            perror("");
            return 1;
        }
        off_t written = copy_bytes(current_program, out, markers[i].size);
        if (written != markers[i].size) {
            eprintf("Unexpected error occurred when trying to extract %s\n", markers[i].name);
            return 1;
        }
        if (chmod(out_path, markers[i].mode) == -1) {
            perror("Error setting up permissions");
            return 1;
        }
        fclose(out);
    }
    fclose(current_program);

    eprintf("Extracting conty utilities...\n");
    char* busybox_path = get_conty_file("/content/busybox");
    char* utils_archive_path = get_conty_file("/content/utils.tar.xz");
    mkdir_p(utils_path);
    char* const extract_cmd[] = {busybox_path, "tar", "x", "-J", "-C", utils_path, "-f", utils_archive_path, NULL};
    if (exec_prog(extract_cmd) != 0) {
        perror("Error when trying to extract utilities");
        return 1;
    }

    eprintf("Installing busybox utilities...\n");
    char* busybox_install_path = get_conty_file("/utils/busybox");
    mkdir_p(busybox_install_path);
    char* const install_cmd[] = {busybox_path, "--install", "-s", busybox_install_path, NULL};
    if (exec_prog(install_cmd) != 0) {
        perror("Error when trying to install busybox utilities");
        return 1;
    }

    FILE* extraction_marker = fopen(extraction_marker_path, "w");
    char* marker_text =
        "This file is used by conty to determine whether it should extract"
        " files on startup. If the file is missing or it's modification date is"
        " older than that of conty then conty will perform extraction again.\n";
    fwrite(marker_text, strlen(marker_text) - 1, 1, extraction_marker);
    fclose(extraction_marker);
    if (touch_r(program_path, extraction_marker_path) != 0) {
        perror("Unable to set extraction marker modification time");
        return 1;
    }

exec:
    char* use_sys_utils = getenv("USE_SYS_UTILS");
    if (use_sys_utils == NULL || strcmp(use_sys_utils, "") == 0) {
        prepend_env_path("PATH", get_conty_file("/utils/bin"));
        prepend_env_path("PATH", get_conty_file("/utils/busybox"));
        prepend_env_path("LD_PRELOAD_PATH", get_conty_file("/utils/lib"));
    }

    char* conty_start = get_conty_file("/content/conty-start.sh");
    char *bash_args[MAX_ARGS_NUMBER + 4] = {"-c", "--", conty_start, argv[0]};
    int k = 4;
    for (int i = 1; i < argc; i++, k++) {
    	bash_args[k] = argv[i];
    }
    bash_args[k] = NULL;
    return execvp("bash", bash_args);
}
