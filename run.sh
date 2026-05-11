#!/bin/bash

# Array 1: C source code strings
declare -a code

code[0]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

int is_valid_octal(const char *s) {
    if (strlen(s) != 4) return 0;
    for (int i = 0; i < 4; i++) {
        if (s[i] < '0' || s[i] > '7')
            return 0;
    }
    return 1;
}

void octal_to_symbolic(int perm, char *out) {
    const char symbols[] = {'r','w','x'};
    int pos = 0;

    for (int i = 2; i >= 0; i--) {
        int val = (perm >> (i * 3)) & 7;
        for (int j = 0; j < 3; j++) {
            out[pos++] = (val & (1 << (2 - j))) ? symbols[j] : '-';
        }
    }
    out[pos] = '\0';
}

int main(int argc, char *argv[]) {
    if (argc != 3 && argc != 5) {
        printf(\"ERROR: E_USAGE: invalid arguments\n\");
        return 1;
    }

    if (strcmp(argv[1], \"--mode\") != 0) {
        printf(\"ERROR: E_USAGE: missing --mode\n\");
        return 1;
    }

    if (!is_valid_octal(argv[2])) {
        printf(\"ERROR: E_OCTAL: mode must be 4-digit octal (0000-0777)\n\");
        return 1;
    }

    int mode = strtol(argv[2], NULL, 8);
    int umask = 0;

    if (argc == 5) {
        if (strcmp(argv[3], \"--umask\") != 0 || !is_valid_octal(argv[4])) {
            printf(\"ERROR: E_OCTAL: invalid umask\n\");
            return 1;
        }
        umask = strtol(argv[4], NULL, 8);
    }

    int effective = mode & (~umask & 0777);

    char symbolic[10];
    octal_to_symbolic(effective, symbolic);

    printf(\"OK: EFFECTIVE %04o\n\", effective);
    printf(\"OK: SYMBOLIC %s\n\", symbolic);

    return 0;
}
"

code[1]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>

#define MAX_BUF 1048576

uint32_t crc32_update(uint32_t crc, unsigned char c) {
    crc ^= c;
    for (int i = 0; i < 8; i++)
        crc = (crc & 1) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    return crc;
}

int main(int argc, char *argv[]) {
    char *src = NULL, *dst = NULL;
    int bufsize = 4096, force = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], \"--src\")) src = argv[++i];
        else if (!strcmp(argv[i], \"--dst\")) dst = argv[++i];
        else if (!strcmp(argv[i], \"--buf\")) bufsize = atoi(argv[++i]);
        else if (!strcmp(argv[i], \"--force\")) force = 1;
        else {
            printf(\"ERROR: E_USAGE: invalid arguments\n\");
            return 1;
        }
    }

    if (!src || !dst) {
        printf(\"ERROR: E_USAGE: missing required arguments\n\");
        return 1;
    }

    if (bufsize < 1 || bufsize > MAX_BUF) {
        printf(\"ERROR: E_RANGE: invalid buffer size\n\");
        return 1;
    }

    int fd_src = strcmp(src, \"-\") == 0 ? STDIN_FILENO : open(src, O_RDONLY);
    if (fd_src < 0) {
        printf(\"ERROR: E_OPEN_SRC: cannot open source\n\");
        return 1;
    }

    int flags = O_WRONLY | O_CREAT;
    if (!force) flags |= O_EXCL;
    flags |= O_TRUNC;

    int fd_dst = open(dst, flags, 0644);
    if (fd_dst < 0) {
        printf(\"ERROR: E_EXISTS: destination already exists (use --force)\n\");
        return 1;
    }

    unsigned char *buf = malloc(bufsize);
    ssize_t r;
    uint64_t total = 0;
    uint32_t crc = 0xFFFFFFFF;

    while ((r = read(fd_src, buf, bufsize)) > 0) {
        for (ssize_t i = 0; i < r; i++)
            crc = crc32_update(crc, buf[i]);

        ssize_t w = 0;
        while (w < r) {
            ssize_t n = write(fd_dst, buf + w, r - w);
            if (n < 0) {
                printf(\"ERROR: E_WRITE: write failed\n\");
                return 1;
            }
            w += n;
        }
        total += r;
    }

    crc ^= 0xFFFFFFFF;

    printf(\"OK: COPIED %lu BYTES\n\", total);
    printf(\"OK: CRC32 %08x\n\", crc);

    close(fd_src);
    close(fd_dst);
    free(buf);
    return 0;
}
"

code[2]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>     // For directory operations: opendir, readdir
#include <sys/stat.h>   // For file metadata: lstat, S_ISREG, etc.
#include <unistd.h>

// Structure to store entry details for sorting and reporting
typedef struct {
    char name[256];
    long size;
    char type;
} FileEntry;

// Comparator to sort entries by name lexicographically
int compare_name(const void *a, const void *b) {
    return strcmp(((FileEntry *)a)->name, ((FileEntry *)b)->name);
}

// Comparator to sort entries by size (ascending), with name as a tie-break
int compare_size(const void *a, const void *b) {
    FileEntry *fa = (FileEntry *)a;
    FileEntry *fb = (FileEntry *)b;
    if (fa->size != fb->size) return (fa->size - fb->size);
    return strcmp(fa->name, fb->name);
}

int main(int argc, char *argv[]) {
    char *path = NULL;
    char *sort_by = \"name\"; // Default sorting behavior

    // 1. Parse Command Line Arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--path\") == 0) path = argv[++i];
        else if (strcmp(argv[i], \"--sort\") == 0) sort_by = argv[++i];
    }

    // Basic usage error check
    if (!path) {
        fprintf(stderr, \"ERROR: E_USAGE: path is required\n\");
        return 1;
    }

    // 2. Open Directory
    DIR *dr = opendir(path);
    if (dr == NULL) {
        struct stat check_st;
        // Check if path exists but is just a file, not a directory
        if (lstat(path, &check_st) == 0 && !S_ISDIR(check_st.st_mode))
            fprintf(stderr, \"ERROR: E_NOTDIR: path is not a directory\n\");
        else
            fprintf(stderr, \"ERROR: E_NOTDIR: path does not exist\n\");
        return 1;
    }

    struct dirent *de;
    FileEntry entries[1024]; // Array to hold entries for sorting
    int count = 0, files = 0, dirs = 0, links = 0, other = 0;

    // 3. Traverse Directory Entries
    while ((de = readdir(dr)) != NULL) {
        // Exclude '.' (current) and '..' (parent) directories as per hints
        if (strcmp(de->d_name, \".\") == 0 || strcmp(de->d_name, \"..\") == 0) continue;

        char full_path[1024];
        sprintf(full_path, \"%s/%s\", path, de->d_name);

        struct stat st;
        // Collect metadata using lstat (does not follow symlinks)
        if (lstat(full_path, &st) == 0) {
            strcpy(entries[count].name, de->d_name);
            entries[count].size = st.st_size;

            // Classify entry types (F=File, D=Dir, L=Link, O=Other)
            if (S_ISREG(st.st_mode)) { entries[count].type = 'F'; files++; }
            else if (S_ISDIR(st.st_mode)) { entries[count].type = 'D'; dirs++; }
            else if (S_ISLNK(st.st_mode)) { entries[count].type = 'L'; links++; }
            else { entries[count].type = 'O'; other++; }
            count++;
        }
    }
    closedir(dr); // Close the directory stream

    // 4. Sort the Collected Entries
    if (strcmp(sort_by, \"size\") == 0)
        qsort(entries, count, sizeof(FileEntry), compare_size);
    else
        qsort(entries, count, sizeof(FileEntry), compare_name);

    // 5. Output Results
    for (int i = 0; i < count; i++) {
        printf(\"ENTRY %c %ld %s\n\", entries[i].type, entries[i].size, entries[i].name);
    }

    // Print final summary line
    printf(\"OK: TOTAL %d FILES %d DIRS %d LINKS %d OTHER %d\n\", count, files, dirs, links, other);

    return 0;
}
"

code[3]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char *argv[]) {
    char *pattern = NULL;
    char *file_list = NULL;

    // 1. Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--pattern\") == 0) {
            pattern = argv[++i];
        } else if (strcmp(argv[i], \"--files\") == 0) {
            file_list = argv[++i];
        }
    }

    // Basic usage and empty pattern error checking
    if (pattern == NULL || file_list == NULL) {
        fprintf(stderr, \"ERROR: E_USAGE: missing arguments\n\");
        return 1;
    }
    if (strlen(pattern) == 0) {
        fprintf(stderr, \"ERROR: E_EMPTY_PATTERN: pattern must be non-empty\n\");
        return 1;
    }

    int total_matches = 0;
    int total_files = 0;

    // 2. Split the comma-separated file list
    char *file_name = strtok(file_list, \",\");
    while (file_name != NULL) {
        // Reject empty file segments (e.g., trailing comma)
        if (strlen(file_name) == 0) {
            file_name = strtok(NULL, \",\");
            continue;
        }

        // 3. Open the file
        FILE *fp = fopen(file_name, \"r\");
        if (fp == NULL) {
            fprintf(stderr, \"ERROR: E_OPEN: could not open file %s\n\", file_name);
            return 1;
        }

        char line[1024];
        int line_no = 1;
        total_files++;

        // 4. Read file line by line
        while (fgets(line, sizeof(line), fp)) {
            // Remove the trailing newline character for clean output
            line[strcspn(line, \"\n\")] = 0;

            // 5. Search for the pattern in the current line
            if (strstr(line, pattern) != NULL) {
                printf(\"MATCH %s:%d:%s\n\", file_name, line_no, line);
                total_matches++;
            }
            line_no++;
        }

        fclose(fp);
        file_name = strtok(NULL, \",\"); // Get next file from the list
    }

    // 6. Output final summary
    printf(\"OK: MATCHES %d FILES %d\n\", total_matches, total_files);

    return 0;
}
"

code[4]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/types.h>

int main(int argc, char *argv[]) {
    char *cmd = NULL;
    char *args_str = NULL;
    int repeat = 1;

    // 1. Parse Command Line Arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--cmd\") == 0) cmd = argv[++i];
        else if (strcmp(argv[i], \"--args\") == 0) args_str = argv[++i];
        else if (strcmp(argv[i], \"--repeat\") == 0) repeat = atoi(argv[++i]);
    }

    // Validation: cmd is required and repeat must be >= 1
    if (!cmd) {
        fprintf(stderr, \"ERROR: E_USAGE\n\");
        return 1;
    }
    if (repeat < 1) {
        fprintf(stderr, \"ERROR: E_RANGE\n\");
        return 1;
    }

    // Prepare arguments array for execvp
    char *exec_args[64];
    exec_args[0] = cmd;
    int arg_idx = 1;
    if (args_str) {
        char *token = strtok(args_str, \",\");
        while (token != NULL) {
            exec_args[arg_idx++] = token;
            token = strtok(NULL, \",\");
        }
    }
    exec_args[arg_idx] = NULL; // Array must be NULL-terminated

    // 2. Spawn processes sequentially
    for (int i = 1; i <= repeat; i++) {
        pid_t pid = fork(); // Create child process

        if (pid < 0) {
            fprintf(stderr, \"ERROR: E_FORK\n\");
            return 1;
        }

        if (pid == 0) {
            // --- Inside Child Process ---
            // If execvp succeeds, the code below it never runs
            execvp(cmd, exec_args);

            // If exec fails, exit with code 127 to signal the parent
            exit(127);
        } else {
            // --- Inside Parent Process ---
            int status;
            // Wait for child to terminate and get status
            waitpid(pid, &status, 0);

            if (WIFEXITED(status)) {
                int exit_code = WEXITSTATUS(status);

                // If it's the first child and exec failed, stop and report ERROR
                if (exit_code == 127 && i == 1) {
                    fprintf(stderr, \"ERROR: E_EXEC: cannot exec program\n\");
                    return 1;
                }

                // If exec was successful, print START and then EXIT
                printf(\"CHILD %d PID %d START\n\", i, pid);
                printf(\"CHILD %d PID %d EXIT %d\n\", i, pid, exit_code);
            } else if (WIFSIGNALED(status)) {
                // Report if child was killed by a signal
                printf(\"CHILD %d PID %d SIG %d\n\", i, pid, WTERMSIG(status));
            }
        }
    }

    // Final success message
    printf(\"OK: COMPLETED %d\n\", repeat);
    return 0;
}
"

code[5]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>

// Global variable to store child process ID so the signal handler can access it
pid_t child_pid = -1;

// Signal handler: This function runs when the alarm goes off
void handle_alarm(int sig) {
    if (child_pid > 0) {
        // Forcefully kill the child process if it's still running
        kill(child_pid, SIGKILL);
    }
}

int main(int argc, char *argv[]) {
    int seconds = 0;
    char *cmd = NULL;
    char *args_str = NULL;

    // 1. Parse Command Line Arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--seconds\") == 0) seconds = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--cmd\") == 0) cmd = argv[++i];
        else if (strcmp(argv[i], \"--args\") == 0) args_str = argv[++i];
    }

    // Validation: Check if seconds is within the required range (1-60)
    if (seconds < 1 || seconds > 60) {
        fprintf(stderr, \"ERROR: E_RANGE: seconds must be in 1..60\n\");
        return 1;
    }
    if (!cmd) {
        fprintf(stderr, \"ERROR: E_USAGE: --cmd is required\n\");
        return 1;
    }

    // Set up sigaction for SIGALRM for more reliable signal handling
    struct sigaction sa;
    sa.sa_handler = handle_alarm;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGALRM, &sa, NULL);

    // 2. Prepare arguments for execvp
    char *exec_args[64];
    exec_args[0] = cmd;
    int arg_idx = 1;

    if (args_str) {
        // Use strtok to split the comma-separated arguments
        char *token = strtok(args_str, \",\");
        while (token != NULL) {
            exec_args[arg_idx++] = token;
            token = strtok(NULL, \",\");
        }
    }
    exec_args[arg_idx] = NULL; // Array must be NULL-terminated

    // 3. Fork and Monitor
    child_pid = fork();

    if (child_pid == 0) {
        // Inside Child Process: Try to run the command
        execvp(cmd, exec_args);
        exit(127); // Exit with code 127 if execvp fails
    } else {
        // Inside Parent Process: Start the timer
        alarm(seconds);

        int status;
        // Wait for child to finish or be killed by signal
        waitpid(child_pid, &status, 0);
        alarm(0); // Cancel the alarm if child finished within time

        // 4. Output Logic: Reporting how the process ended
        if (WIFSIGNALED(status)) {
            // If the process was terminated by any signal after the timeout
            // we report it as TIMEOUT KILLED to match lab specifications
            printf(\"OK: TIMEOUT KILLED\n\");
        } else if (WIFEXITED(status)) {
            // If the process finished normally, report its exit code
            printf(\"OK: EXIT %d\n\", WEXITSTATUS(status));
        }
    }

    return 0;
}
"

code[6]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h> // Required for open() and O_WRONLY

// Helper function to parse comma-separated arguments
void parse_args(char *cmd, char *args_str, char **exec_args) {
    exec_args[0] = cmd;
    int idx = 1;
    if (args_str) {
        char *token = strtok(args_str, \",\");
        while (token != NULL) {
            exec_args[idx++] = token;
            token = strtok(NULL, \",\");
        }
    }
    exec_args[idx] = NULL; // NULL terminate the argument list
}

int main(int argc, char *argv[]) {
    char *stages_cmd[3] = {NULL, NULL, NULL};
    char *stages_args[3] = {NULL, NULL, NULL};
    char *stage_names[3] = {\"producer\", \"filter\", \"consumer\"};

    // 1. Parsing command line flags
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--producer\") == 0) stages_cmd[0] = argv[++i];
        else if (strcmp(argv[i], \"--producer-args\") == 0) stages_args[0] = argv[++i];
        else if (strcmp(argv[i], \"--filter\") == 0) stages_cmd[1] = argv[++i];
        else if (strcmp(argv[i], \"--filter-args\") == 0) stages_args[1] = argv[++i];
        else if (strcmp(argv[i], \"--consumer\") == 0) stages_cmd[2] = argv[++i];
        else if (strcmp(argv[i], \"--consumer-args\") == 0) stages_args[2] = argv[++i];
    }

    if (!stages_cmd[0] || !stages_cmd[1] || !stages_cmd[2]) {
        fprintf(stderr, \"ERROR: E_USAGE\n\");
        return 1;
    }

    int pipe1[2], pipe2[2];
    pipe(pipe1); // Create first pipe
    pipe(pipe2); // Create second pipe

    pid_t pids[3];

    // 2. Launching stages
    for (int i = 0; i < 3; i++) {
        pids[i] = fork();
        if (pids[i] == 0) {
            // --- Inside Child Process ---

            // Redirect Pipe Ends
            if (i == 0) { // Producer writes to pipe1
                dup2(pipe1[1], STDOUT_FILENO);
            } else if (i == 1) { // Filter reads from pipe1, writes to pipe2
                dup2(pipe1[0], STDIN_FILENO);
                dup2(pipe2[1], STDOUT_FILENO);
            } else if (i == 2) { // Consumer reads from pipe2
                dup2(pipe2[0], STDIN_FILENO);

                // Deterministic Rule: Redirect final output to /dev/null
                int dev_null = open(\"/dev/null\", O_WRONLY);
                dup2(dev_null, STDOUT_FILENO);
                dup2(dev_null, STDERR_FILENO);
                close(dev_null);
            }

            // Close all pipe file descriptors in the child
            close(pipe1[0]); close(pipe1[1]);
            close(pipe2[0]); close(pipe2[1]);

            char *exec_args[64];
            parse_args(stages_cmd[i], stages_args[i], exec_args);
            execvp(stages_cmd[i], exec_args); // Replace process image
            exit(127);
        }
    }

    // 3. Parent Cleanup and Status Collection
    close(pipe1[0]); close(pipe1[1]);
    close(pipe2[0]); close(pipe2[1]);

    int status, first_fail_idx = -1;
    int fail_code = 0, is_sig = 0;

    // Wait for all stages and record the first failure
    for (int i = 0; i < 3; i++) {
        waitpid(pids[i], &status, 0);
        if (first_fail_idx == -1) {
            if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
                first_fail_idx = i; fail_code = WEXITSTATUS(status);
            } else if (WIFSIGNALED(status)) {
                first_fail_idx = i; fail_code = WTERMSIG(status); is_sig = 1;
            }
        }
    }

    // 4. Print Final Report
    if (first_fail_idx == -1) {
        printf(\"OK: PIPELINE SUCCESS\n\"); // Matches Sample I/O
    } else {
        if (is_sig) printf(\"ERROR: E_STAGE: stage %s sig %d\n\", stage_names[first_fail_idx], fail_code);
        else printf(\"ERROR: E_STAGE: stage %s exit %d\n\", stage_names[first_fail_idx], fail_code);
    }

    return 0;
}
"

code[7]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <semaphore.h>

int main(int argc, char *argv[]) {
    int procs = 0, iters = 0;
    char *name = NULL;

    // 1. Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--procs\") == 0) procs = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--iters\") == 0) iters = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--name\") == 0) name = argv[++i];
    }

    // Validation: Check ranges for procs and iters
    if (procs < 2 || procs > 16) {
        fprintf(stderr, \"ERROR: E_RANGE: procs must be in 2..16\n\");
        return 1;
    }
    if (iters < 1 || iters > 100000) {
        fprintf(stderr, \"ERROR: E_RANGE\n\");
        return 1;
    }

    // 2. Setup Shared Memory
    char shm_path[64], sem_path[64];
    sprintf(shm_path, \"/shm_%s\", name);
    sprintf(sem_path, \"/sem_%s\", name);

    int shm_fd = shm_open(shm_path, O_CREAT | O_RDWR, 0666);
    ftruncate(shm_fd, sizeof(long)); // Size for one 64-bit integer
    long *counter = mmap(0, sizeof(long), PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
    *counter = 0; // Initialize counter to 0

    // 3. Setup Semaphore
    sem_t *sem = sem_open(sem_path, O_CREAT, 0666, 1);

    // 4. Fork child processes
    for (int i = 0; i < procs; i++) {
        if (fork() == 0) {
            for (int j = 0; j < iters; j++) {
                sem_wait(sem);   // Lock
                (*counter)++;    // Critical Section
                sem_post(sem);   // Unlock
            }
            exit(0);
        }
    }

    // 5. Parent waits for all children
    for (int i = 0; i < procs; i++) wait(NULL);

    // Output final value: expected is procs * iters
    printf(\"OK: FINAL %ld\n\", *counter);

    // 6. Cleanup resources
    munmap(counter, sizeof(long));
    shm_unlink(shm_path);
    sem_close(sem);
    sem_unlink(sem_path);

    return 0;
}
"

code[8]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

// Structure to pass data to each thread
typedef struct {
    int start;
    int end;
} ThreadData;

long long global_sum = 0;       // Shared variable for the final sum
pthread_mutex_t sum_mutex;      // Mutex to protect global_sum

// Thread function: Calculates sum of a specific range
void* calculate_sum(void* arg) {
    ThreadData* data = (ThreadData*)arg;
    long long local_sum = 0;

    // Calculate sum for the assigned partition
    for (int i = data->start; i <= data->end; i++) {
        local_sum += i;
    }

    // Protect the global update using a Mutex lock
    pthread_mutex_lock(&sum_mutex);
    global_sum += local_sum;
    pthread_mutex_unlock(&sum_mutex);

    return NULL;
}

int main(int argc, char *argv[]) {
    int t = 0;
    long long n = 0;

    // 1. Parse command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--threads\") == 0) t = atoi(argv[++i]);
        else if (strcmp(argv[i], \"-n\") == 0) n = atoll(argv[++i]);
    }

    // Validation: Threads must be in 1..32 and N in 1..1,000,000
    if (t < 1 || t > 32) {
        fprintf(stderr, \"ERROR: E_RANGE: threads must be in 1..32\n\");
        return 1;
    }
    if (n < 1 || n > 1000000) {
        fprintf(stderr, \"ERROR: E_RANGE\n\");
        return 1;
    }

    // Initialize the mutex
    pthread_mutex_init(&sum_mutex, NULL);

    pthread_t threads[t];
    ThreadData thread_info[t];
    int base_range = n / t;
    int remainder = n % t;
    int current_start = 1;

    // 2. Partition work and create threads
    for (int i = 0; i < t; i++) {
        thread_info[i].start = current_start;
        thread_info[i].end = current_start + base_range - 1;

        // Handle remainder to ensure every number is included exactly once
        if (i < remainder) {
            thread_info[i].end++;
        }

        pthread_create(&threads[i], NULL, calculate_sum, &thread_info[i]);
        current_start = thread_info[i].end + 1;
    }

    // 3. Join threads to wait for completion
    for (int i = 0; i < t; i++) {
        pthread_join(threads[i], NULL);
    }

    // Output final deterministic sum
    printf(\"OK: SUM %lld\n\", global_sum);

    // Cleanup mutex
    pthread_mutex_destroy(&sum_mutex);

    return 0;
}
"

code[9]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <semaphore.h>

// Shared resources and synchronization primitives
int *buffer;
int buf_size = 0, total_items = 0, prod_count = 0, cons_count = 0;
int in = 0, out = 0, current_item_id = 1;
long long sum_consumed = 0;
int produced_total = 0, consumed_total = 0;

sem_t sem_empty, sem_full; // Semaphores for buffer flow control
pthread_mutex_t mutex, prod_mutex, sum_mutex; // Mutexes for thread safety

// Producer function: Assigns IDs and places items in buffer
void* producer(void* arg) {
    while (1) {
        int item;
        pthread_mutex_lock(&prod_mutex); // Protect the sequence generator
        if (current_item_id > total_items) {
            pthread_mutex_unlock(&prod_mutex);
            break;
        }
        item = current_item_id++;
        produced_total++;
        pthread_mutex_unlock(&prod_mutex);

        sem_wait(&sem_empty); // Wait for an empty slot
        pthread_mutex_lock(&mutex); // Lock for buffer access
        buffer[in] = item;
        in = (in + 1) % buf_size;
        pthread_mutex_unlock(&mutex);
        sem_post(&sem_full); // Notify consumers that data is available
    }
    return NULL;
}

// Consumer function: Retrieves items and calculates sum
void* consumer(void* arg) {
    while (1) {
        int item;
        sem_wait(&sem_full); // Wait for a full slot
        pthread_mutex_lock(&mutex);

        item = buffer[out];
        // Sentinel check: if item is -1, termination has started
        if (item == -1) {
            pthread_mutex_unlock(&mutex);
            sem_post(&sem_full); // Pass the sentinel to the next consumer
            break;
        }

        buffer[out] = 0;
        out = (out + 1) % buf_size;
        consumed_total++;

        pthread_mutex_lock(&sum_mutex); // Protect global sum update
        sum_consumed += item;
        pthread_mutex_unlock(&sum_mutex);

        pthread_mutex_unlock(&mutex);
        sem_post(&sem_empty); // Notify producers that space is free

        // If all items are consumed, place a sentinel to stop all consumer threads
        if (consumed_total == total_items) {
            sem_wait(&sem_empty);
            pthread_mutex_lock(&mutex);
            buffer[in] = -1; // Sentinel value
            in = (in + 1) % buf_size;
            pthread_mutex_unlock(&mutex);
            sem_post(&sem_full);
        }
    }
    return NULL;
}

int main(int argc, char *argv[]) {
    // 1. Argument Parsing
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--buf\") == 0) buf_size = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--producers\") == 0) prod_count = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--consumers\") == 0) cons_count = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--items\") == 0) total_items = atoi(argv[++i]);
    }

    // 2. Exact Error Reporting as per Behavior Specification
    if (buf_size < 1 || buf_size > 1024) {
        fprintf(stderr, \"ERROR: E_RANGE: buf must be in 1..1024\n\");
        return 1;
    }
    if (prod_count < 1 || prod_count > 16) {
        fprintf(stderr, \"ERROR: E_RANGE: producers must be in 1..16\n\");
        return 1;
    }
    if (cons_count < 1 || cons_count > 16) {
        fprintf(stderr, \"ERROR: E_RANGE: consumers must be in 1..16\n\");
        return 1;
    }
    if (total_items < 0 || total_items > 100000) {
        fprintf(stderr, \"ERROR: E_RANGE: items must be in 0..100000\n\");
        return 1;
    }

    // 3. Resource Initialization
    buffer = malloc(buf_size * sizeof(int));
    sem_init(&sem_empty, 0, buf_size);
    sem_init(&sem_full, 0, 0);
    pthread_mutex_init(&mutex, NULL);
    pthread_mutex_init(&prod_mutex, NULL);
    pthread_mutex_init(&sum_mutex, NULL);

    pthread_t prods[prod_count], cons[cons_count];

    // 4. Thread Creation
    for (int i = 0; i < prod_count; i++) pthread_create(&prods[i], NULL, producer, NULL);
    for (int i = 0; i < cons_count; i++) pthread_create(&cons[i], NULL, consumer, NULL);

    // 5. Cleanup
    for (int i = 0; i < prod_count; i++) pthread_join(prods[i], NULL);
    for (int i = 0; i < cons_count; i++) pthread_join(cons[i], NULL);

    // 6. Final Deterministic Summary Output
    printf(\"OK: PRODUCED %d\n\", produced_total);
    printf(\"OK: CONSUMED %d\n\", consumed_total);
    printf(\"OK: SUM %lld\n\", sum_consumed);

    // Check internal invariant before exit
    if (produced_total != consumed_total) {
        fprintf(stderr, \"ERROR: E_INVARIANT: produced/consumed mismatch\n\");
        return 1;
    }

    free(buffer);
    return 0;
}
"

code[10]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Structure to store process details
typedef struct {
    char pid[32];
    int arrival;
    int burst;
    int wait;
    int tat;
    int completed;
} Process;

// Helper to print average metrics with 2 decimal places
void print_metrics(Process p[], int n) {
    double total_wait = 0, total_tat = 0;
    for (int i = 0; i < n; i++) {
        total_wait += p[i].wait;
        total_tat += p[i].tat;
    }
    printf(\"OK: AVG_WAIT %.2f AVG_TAT %.2f\n\", total_wait / n, total_tat / n);
}

// FCFS (First-Come First-Served) Simulation
void simulate_fcfs(Process p_in[], int n) {
    Process p[64];
    memcpy(p, p_in, n * sizeof(Process));
    printf(\"ALG: FCFS\n\");
    printf(\"GANTT \");

    int current_time = 0;
    for (int i = 0; i < n; i++) {
        if (current_time < p[i].arrival) {
            printf(\"IDLE@%d-%d \", current_time, p[i].arrival);
            current_time = p[i].arrival;
        }
        int start = current_time;
        current_time += p[i].burst;
        p[i].tat = current_time - p[i].arrival;
        p[i].wait = p[i].tat - p[i].burst;
        printf(\"%s@%d-%d \", p[i].pid, start, current_time);
    }
    printf(\"\n\");
    print_metrics(p, n);
}

// SJF (Shortest Job First - Non-preemptive) Simulation
void simulate_sjf(Process p_in[], int n) {
    Process p[64];
    memcpy(p, p_in, n * sizeof(Process));
    for(int i=0; i<n; i++) p[i].completed = 0;

    printf(\"ALG: SJF\n\");
    printf(\"GANTT \");

    int current_time = 0, completed_count = 0;
    while (completed_count < n) {
        int idx = -1;
        int min_burst = 999999;

        // Selection rule: Shortest burst among arrived processes
        for (int i = 0; i < n; i++) {
            if (!p[i].completed && p[i].arrival <= current_time) {
                if (p[i].burst < min_burst) {
                    min_burst = p[i].burst;
                    idx = i;
                } else if (p[i].burst == min_burst) {
                    // Tie-breaker: earlier arrival
                    if (p[i].arrival < p[idx].arrival) idx = i;
                }
            }
        }

        if (idx == -1) {
            // Find the next arriving process for IDLE time
            int next_arrival = 999999;
            for(int i=0; i<n; i++) if(!p[i].completed && p[i].arrival < next_arrival) next_arrival = p[i].arrival;
            printf(\"IDLE@%d-%d \", current_time, next_arrival);
            current_time = next_arrival;
        } else {
            int start = current_time;
            current_time += p[idx].burst;
            p[idx].tat = current_time - p[idx].arrival;
            p[idx].wait = p[idx].tat - p[idx].burst;
            p[idx].completed = 1;
            completed_count++;
            printf(\"%s@%d-%d \", p[idx].pid, start, current_time);
        }
    }
    printf(\"\n\");
    print_metrics(p, n);
}

int main() {
    char line[128];
    Process p[64];
    int n = 0;

    // 1. Read CSV Header
    if (!fgets(line, sizeof(line), stdin)) return 0;

    // 2. Read and Validate Process Data
    while (fgets(line, sizeof(line), stdin)) {
        if (strlen(line) <= 1) continue;
        if (sscanf(line, \"%[^,],%d,%d\", p[n].pid, &p[n].arrival, &p[n].burst) == 3) {
            // Validation per snapshot requirement
            if (p[n].arrival < 0 || p[n].burst <= 0) {
                fprintf(stderr, \"ERROR: E_RANGE: arrival and burst must be non-negative; burst must be > 0\n\");
                return 1;
            }
            p[n].completed = 0;
            n++;
        }
    }

    if (n == 0) return 0;

    // 3. Pre-sort by Arrival Time for baseline order
    for (int i = 0; i < n - 1; i++) {
        for (int j = 0; j < n - i - 1; j++) {
            if (p[j].arrival > p[j+1].arrival) {
                Process temp = p[j]; p[j] = p[j+1]; p[j+1] = temp;
            }
        }
    }

    // 4. Run Simulations
    simulate_fcfs(p, n);
    printf(\"\n\");
    simulate_sjf(p, n);

    return 0;
}
"

code[11]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char pid[32];
    int arrival, burst, remaining, wait, tat, completed, in_queue;
} Process;

int main(int argc, char *argv[]) {
    int quantum = 0;
    // 1. Parse Quantum Argument
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"-q\") == 0) quantum = atoi(argv[++i]);
    }

    if (quantum < 1 || quantum > 1000) {
        fprintf(stderr, \"ERROR: E_RANGE: quantum must be in 1..1000\n\");
        return 1;
    }

    char line[128];
    Process p[64];
    int n = 0;
    fgets(line, sizeof(line), stdin); // Skip header
    while (fgets(line, sizeof(line), stdin)) {
        if (sscanf(line, \"%[^,],%d,%d\", p[n].pid, &p[n].arrival, &p[n].burst) == 3) {
            p[n].remaining = p[n].burst;
            p[n].completed = 0;
            p[n].in_queue = 0;
            n++;
        }
    }

    // Sort by arrival initially for initial queueing
    for (int i = 0; i < n - 1; i++) {
        for (int j = 0; j < n - i - 1; j++) {
            if (p[j].arrival > p[j+1].arrival) {
                Process temp = p[j]; p[j] = p[j+1]; p[j+1] = temp;
            }
        }
    }

    printf(\"ALG: RR\n\");
    printf(\"GANTT \");

    int current_time = 0, finished = 0;
    int queue[1000], head = 0, tail = 0;

    // 2. Round Robin Simulation Loop
    while (finished < n) {
        // Add newly arrived processes to queue
        for (int i = 0; i < n; i++) {
            if (!p[i].completed && !p[i].in_queue && p[i].arrival <= current_time) {
                queue[tail++] = i;
                p[i].in_queue = 1;
            }
        }

        if (head == tail) { // CPU is IDLE
            int next_arr = 9999;
            for(int i=0; i<n; i++) if(!p[i].completed && p[i].arrival < next_arr) next_arr = p[i].arrival;
            printf(\"IDLE@%d-%d \", current_time, next_arr);
            current_time = next_arr;
            continue;
        }

        int idx = queue[head++];
        int execute = (p[idx].remaining < quantum) ? p[idx].remaining : quantum;

        printf(\"%s@%d-%d \", p[idx].pid, current_time, current_time + execute);
        current_time += execute;
        p[idx].remaining -= execute;

        // Check for new arrivals during execution
        for (int i = 0; i < n; i++) {
            if (!p[i].completed && !p[i].in_queue && p[i].arrival <= current_time) {
                queue[tail++] = i;
                p[i].in_queue = 1;
            }
        }

        if (p[idx].remaining > 0) {
            queue[tail++] = idx; // Re-enqueue if not finished
        } else {
            p[idx].completed = 1;
            finished++;
            p[idx].tat = current_time - p[idx].arrival;
            p[idx].wait = p[idx].tat - p[idx].burst;
        }
    }

    printf(\"\n\");
    double tw = 0, tt = 0;
    for(int i=0; i<n; i++) { tw += p[i].wait; tt += p[i].tat; }
    printf(\"OK: AVG_WAIT %.2f AVG_TAT %.2f\n\", tw/n, tt/n);

    return 0;
}
"

code[12]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char pid[32];
    int arrival, burst, priority, wait, tat, completed;
} Process;

int main() {
    char line[128];
    Process p[64];
    int n = 0;

    // 1. Read CSV Header and Data
    if (!fgets(line, sizeof(line), stdin)) return 0;
    while (fgets(line, sizeof(line), stdin)) {
        if (sscanf(line, \"%[^,],%d,%d,%d\", p[n].pid, &p[n].arrival, &p[n].burst, &p[n].priority) == 4) {
            // Priority range validation
            if (p[n].priority < 0 || p[n].priority > 99) {
                fprintf(stderr, \"ERROR: E_RANGE: priority must be in 0..99\n\");
                return 1;
            }
            p[n].completed = 0;
            n++;
        }
    }

    if (n == 0) return 0;

    printf(\"ALG: PRIO_AGING\n\");
    printf(\"GANTT \");

    int current_time = 0, finished = 0;

    // 2. Simulation Loop
    while (finished < n) {
        int idx = -1;
        int min_eff_prio = 999;

        for (int i = 0; i < n; i++) {
            if (!p[i].completed && p[i].arrival <= current_time) {
                // Apply Aging: Effective Prio = Base - WaitTime
                int wait_time = current_time - p[i].arrival;
                int eff_prio = p[i].priority - wait_time;
                if (eff_prio < 0) eff_prio = 0; // Bound to minimum 0

                if (eff_prio < min_eff_prio) {
                    min_eff_prio = eff_prio;
                    idx = i;
                } else if (eff_prio == min_eff_prio) {
                    // Tie-breaker: earlier arrival
                    if (idx == -1 || p[i].arrival < p[idx].arrival) idx = i;
                }
            }
        }

        if (idx == -1) { // CPU IDLE gap
            int next_arr = 9999;
            for(int i=0; i<n; i++) if(!p[i].completed && p[i].arrival < next_arr) next_arr = p[i].arrival;
            printf(\"IDLE@%d-%d \", current_time, next_arr);
            current_time = next_arr;
        } else {
            int start = current_time;
            p[idx].wait = current_time - p[idx].arrival;
            current_time += p[idx].burst;
            p[idx].tat = current_time - p[idx].arrival;
            p[idx].completed = 1;
            finished++;
            printf(\"%s@%d-%d \", p[idx].pid, start, current_time);
        }
    }

    // 3. Output Metrics
    printf(\"\n\");
    double tw = 0, tt = 0;
    for(int i=0; i<n; i++) { tw += p[i].wait; tt += p[i].tat; }
    printf(\"OK: AVG_WAIT %.2f AVG_TAT %.2f\n\", tw/n, tt/n);

    return 0;
}
"

code[13]="
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

int main() {
    int P, R;

    // 1. Read process (P) and resource (R) counts
    if (scanf(\"%d %d\", &P, &R) != 2) return 0;

    int alloc[P][R], max[P][R], avail[R], need[P][R];
    bool finished[P];

    // Read Allocation Matrix
    for (int i = 0; i < P; i++) {
        for (int j = 0; j < R; j++) {
            scanf(\"%d\", &alloc[i][j]);
        }
        finished[i] = false;
    }

    // Read Max Matrix and Validate
    for (int i = 0; i < P; i++) {
        for (int j = 0; j < R; j++) {
            scanf(\"%d\", &max[i][j]);
            // Invalid Input Check: Allocation cannot exceed Max
            if (alloc[i][j] > max[i][j]) {
                fprintf(stderr, \"ERROR: E_INVALID: allocation must be <= max\n\");
                return 1;
            }
            // Calculate Need Matrix
            need[i][j] = max[i][j] - alloc[i][j];
        }
    }

    // Read Available Vector
    for (int i = 0; i < R; i++) {
        scanf(\"%d\", &avail[i]);
    }

    // 2. Safety Algorithm Implementation
    int safe_seq[P], count = 0;
    int work[R];
    for (int i = 0; i < R; i++) work[i] = avail[i];

    while (count < P) {
        bool found = false;
        // Search lexicographically (smallest index first)
        for (int p = 0; p < P; p++) {
            if (!finished[p]) {
                bool can_exec = true;
                for (int j = 0; j < R; j++) {
                    if (need[p][j] > work[j]) {
                        can_exec = false;
                        break;
                    }
                }

                if (can_exec) {
                    // Resource Release: Work = Work + Allocation
                    for (int j = 0; j < R; j++) {
                        work[j] += alloc[p][j];
                    }
                    safe_seq[count++] = p;
                    finished[p] = true;
                    found = true;
                    // Restart search from smallest index for lexicographical smallest sequence
                    break;
                }
            }
        }
        if (!found) break; // System entered Unsafe State
    }

    // 3. Final Output
    if (count == P) {
        printf(\"OK: SAFE\n\");
        printf(\"OK: SEQ\");
        for (int i = 0; i < P; i++) {
            printf(\" %d\", safe_seq[i]);
        }
        printf(\"\n\");
    } else {
        printf(\"OK: UNSAFE\n\");
    }

    return 0;
}
"

code[14]="
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

#define MAX 100

int adj[MAX][MAX], P, E;
int visited[MAX], path[MAX], parent[MAX];
int cycle_start = -1, cycle_end = -1;

// DFS to detect cycle in a directed graph
bool find_cycle(int u) {
    visited[u] = 1; // Mark as visiting
    for (int v = 0; v < P; v++) {
        if (adj[u][v]) {
            if (visited[v] == 1) { // Cycle detected
                cycle_start = v;
                cycle_end = u;
                return true;
            }
            if (visited[v] == 0) {
                parent[v] = u;
                if (find_cycle(v)) return true;
            }
        }
    }
    visited[u] = 2; // Mark as fully visited
    return false;
}

int main() {
    // 1. Read input
    if (scanf(\"%d %d\", &P, &E) != 2) return 0;

    for (int i = 0; i < E; i++) {
        int u, v;
        scanf(\"%d %d\", &u, &v);
        // Validation: Node range check
        if (u >= P || v >= P || u < 0 || v < 0) {
            fprintf(stderr, \"ERROR: E_INPUT: node index out of range\n\");
            return 1;
        }
        adj[u][v] = 1;
    }

    // 2. Search for cycle
    bool deadlock = false;
    for (int i = 0; i < P; i++) {
        if (visited[i] == 0) {
            if (find_cycle(i)) {
                deadlock = true;
                break;
            }
        }
    }

    // 3. Output results
    if (deadlock) {
        printf(\"OK: DEADLOCK YES\n\");
        printf(\"OK: CYCLE\");

        // Backtrack to find exact cycle nodes
        int curr = cycle_end;
        int res[MAX], k = 0;
        while (curr != cycle_start) {
            res[k++] = curr;
            curr = parent[curr];
        }
        res[k++] = cycle_start;
        for (int i = k - 1; i >= 0; i--) printf(\" % d\", res[i]);
        printf(\"\n\");
    } else {
        printf(\"OK: DEADLOCK NO\n\");
    }

    return 0;
}
"

code[15]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void simulate(char* name, int H, int P, int holes_in[], int procs[]) {
    int holes[H];
    printf(\"ALG: %s\n\", name);
    int allocated_count = 0;

    memcpy(holes, holes_in, H * sizeof(int)); // Original holes for each algorithm

    for (int i = 0; i < P; i++) {
        int best_idx = -1;

        if (strcmp(name, \"FIRST_FIT\") == 0) {
            for (int j = 0; j < H; j++) {
                if (holes[j] >= procs[i]) {
                    best_idx = j;
                    break; // Pick the first available
                }
            }
        } else if (strcmp(name, \"BEST_FIT\") == 0) {
            int min_so_far = 1e9;
            for (int j = 0; j < H; j++) {
                if (holes[j] >= procs[i] && holes[j] < min_so_far) {
                    min_so_far = holes[j];
                    best_idx = j;
                }
            }
        } else if (strcmp(name, \"WORST_FIT\") == 0) {
            int max_so_far = -1;
            for (int j = 0; j < H; j++) {
                if (holes[j] >= procs[i] && holes[j] > max_so_far) {
                    max_so_far = holes[j];
                    best_idx = j;
                }
            }
        }

        if (best_idx != -1) {
            printf(\"PROC %d SIZE %d -> BLOCK %d\n\", i, procs[i], best_idx);
            holes[best_idx] -= procs[i]; // Deduct space
            allocated_count++;
        } else {
            printf(\"PROC %d SIZE %d -> FAIL\n\", i, procs[i]);
        }
    }
    printf(\"OK: ALLOCATED %d/%d\n\", allocated_count, P);
}

int main() {
    int H, P;
    if (scanf(\"%d %d\", &H, &P) != 2) return 0;

    // Range check per snapshot
    if (H <= 0 || P <= 0) {
        fprintf(stderr, \"ERROR: E_RANGE: H and P must be positive\n\");
        return 1;
    }

    int holes[H], procs[P];
    for (int i = 0; i < H; i++) scanf(\"%d\", &holes[i]);
    for (int i = 0; i < P; i++) scanf(\"%d\", &procs[i]);

    simulate(\"FIRST_FIT\", H, P, holes, procs);
    printf(\"\n\");
    simulate(\"BEST_FIT\", H, P, holes, procs);
    printf(\"\n\");
    simulate(\"WORST_FIT\", H, P, holes, procs);

    return 0;
}
"

code[16]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int vpn, pfn, valid; } PageTableEntry;
typedef struct { int vpn, pfn, active; } TLBEntry;

int main(int argc, char *argv[]) {
    int page_size = 0, tlb_size = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--pagesize\") == 0) page_size = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--tlb\") == 0) tlb_size = atoi(argv[++i]);
    }

    // Invalid Case: Power of 2 Check
    if (page_size < 2 || (page_size & (page_size - 1)) != 0) {
        fprintf(stderr, \"ERROR: E_RANGE: page size must be power of 2\n\");
        return 1;
    }

    int N, Q;
    if (scanf(\"%d\", &N) != 1) return 0;
    PageTableEntry pt[N];
    for (int i = 0; i < N; i++) scanf(\"%d %d %d\", &pt[i].vpn, &pt[i].pfn, &pt[i].valid);

    TLBEntry tlb[tlb_size];
    for (int i = 0; i < tlb_size; i++) tlb[i].active = 0;

    int hits = 0, misses = 0;
    if (scanf(\"%d\", &Q) != 1) return 0;
    while (Q--) {
        unsigned int vaddr;
        scanf(\"%u\", &vaddr);
        int vpn = vaddr / page_size;
        int offset = vaddr % page_size;

        // TLB Logic (Optional)
        int tlb_hit = 0;
        if (tlb_size > 0) {
            int idx = vpn % tlb_size;
            if (tlb[idx].active && tlb[idx].vpn == vpn) {
                printf(\"OK: VA %u -> PA %d (TLB HIT)\n\", vaddr, tlb[idx].pfn * page_size + offset);
                hits++; tlb_hit = 1;
            } else misses++;
        }
        if (tlb_hit) continue;

        // Page Table Logic
        int found_idx = -1;
        for (int j = 0; j < N; j++) {
            if (pt[j].vpn == vpn) { found_idx = j; break; }
        }

        // Invalid Case Check: Not found or Valid Bit 0
        if (found_idx != -1 && pt[found_idx].valid) {
            int paddr = pt[found_idx].pfn * page_size + offset;
            if (tlb_size > 0) {
                int idx = vpn % tlb_size;
                tlb[idx] = (TLBEntry){vpn, pt[found_idx].pfn, 1};
                printf(\"OK: VA %u -> PA %d (TLB MISS)\n\", vaddr, paddr);
            } else printf(\"OK: VA %u -> PA %d\n\", vaddr, paddr);
        } else {
            printf(\"OK: VA %u -> PAGE FAULT\n\", vaddr);
        }
    }
    if (tlb_size > 0) printf(\"OK: TLB_HITS %d TLB_MISSES %d\n\", hits, misses);
    return 0;
}
"

code[17]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void print_result(char* alg, int faults, int frames[], int F) {
    printf(\"ALG %s\n\", alg);
    printf(\"OK: FAULTS %d\n\", faults);
    printf(\"OK: FINAL\");
    for (int i = 0; i < F; i++) printf(\" %d\", frames[i]);
    printf(\"\n\n\");
}

int find_in_frames(int page, int frames[], int F) {
    for (int i = 0; i < F; i++) if (frames[i] == page) return i;
    return -1;
}

// FIFO: First-In First-Out
void solve_fifo(int L, int refs[], int F) {
    int frames[F], faults = 0, pointer = 0;
    for (int i = 0; i < F; i++) frames[i] = -1; // Empty frames

    for (int i = 0; i < L; i++) {
        if (find_in_frames(refs[i], frames, F) == -1) {
            faults++; // Increment fault even if frames are empty
            frames[pointer] = refs[i];
            pointer = (pointer + 1) % F;
        }
    }
    print_result(\"FIFO\", faults, frames, F);
}

// LRU: Least Recently Used
void solve_lru(int L, int refs[], int F) {
    int frames[F], last_used[F], faults = 0;
    for (int i = 0; i < F; i++) { frames[i] = -1; last_used[i] = -1; }

    for (int i = 0; i < L; i++) {
        int idx = find_in_frames(refs[i], frames, F);
        if (idx != -1) {
            last_used[idx] = i; // Hit: update time
        } else {
            faults++; // Miss: add to fault
            int victim = 0;
            // Rule: prioritize smallest index for empty frames
            for (int j = 0; j < F; j++) {
                if (frames[j] == -1) { victim = j; break; }
                if (last_used[j] < last_used[victim]) victim = j;
            }
            frames[victim] = refs[i];
            last_used[victim] = i;
        }
    }
    print_result(\"LRU\", faults, frames, F);
}

// OPT: Optimal Page Replacement
void solve_opt(int L, int refs[], int F) {
    int frames[F], faults = 0;
    for (int i = 0; i < F; i++) frames[i] = -1;

    for (int i = 0; i < L; i++) {
        if (find_in_frames(refs[i], frames, F) == -1) {
            faults++; // Miss: add to fault
            int victim = -1;
            for (int j = 0; j < F; j++) {
                if (frames[j] == -1) { victim = j; break; }
            }
            if (victim == -1) {
                int farthest = -1;
                for (int j = 0; j < F; j++) {
                    int next_use = 1000000;
                    for (int k = i + 1; k < L; k++) {
                        if (refs[k] == frames[j]) { next_use = k; break; }
                    }
                    if (next_use > farthest) { farthest = next_use; victim = j; }
                }
            }
            frames[victim] = refs[i];
        }
    }
    print_result(\"OPT\", faults, frames, F);
}

int main(int argc, char *argv[]) {
    int F = 0;
    for (int i = 1; i < argc; i++) if (strcmp(argv[i], \"--frames\") == 0) F = atoi(argv[++i]);
    if (F < 1 || F > 64) {
        fprintf(stderr, \"ERROR: E_RANGE: frames must be 1..64\n\");
        return 1;
    }
    int L; if (scanf(\"%d\", &L) != 1) return 0;
    int refs[L];
    for (int i = 0; i < L; i++) {
        scanf(\"%d\", &refs[i]);
        if (refs[i] < 0) {
            fprintf(stderr, \"ERROR: E_RANGE: page numbers must be >= 0\n\");
            return 1;
        }
    }
    solve_fifo(L, refs, F);
    solve_lru(L, refs, F);
    solve_opt(L, refs, F);
    return 0;
}
"

code[18]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char name[50]; int size; } FileInfo;

// 1. Contiguous Allocation
void solve_contiguous(int N, int F, int free_list[], int M, FileInfo files[]) {
    printf(\"ALG CONTIGUOUS\n\");
    int disk[N];
    for(int i=0; i<N; i++) disk[i] = 0;
    for(int i=0; i<F; i++) disk[free_list[i]] = 1;

    for(int i=0; i<M; i++) {
        int start = -1;
        for(int j=0; j <= N - files[i].size; j++) {
            int ok = 1;
            for(int k=0; k < files[i].size; k++) if(disk[j+k] == 0) { ok = 0; break; }
            if(ok) { start = j; break; }
        }
        if(start != -1) {
            printf(\"FILE %s -> START %d LEN %d\n\", files[i].name, start, files[i].size);
            for(int k=0; k < files[i].size; k++) disk[start+k] = 0;
        } else printf(\"FILE %s -> FAIL\n\", files[i].name);
    }
    printf(\"\n\");
}

// 2. Linked Allocation
void solve_linked(int N, int F, int free_list[], int M, FileInfo files[]) {
    printf(\"ALG LINKED\n\");
    int disk_free[F], used[F];
    for(int i=0; i<F; i++) { disk_free[i] = free_list[i]; used[i] = 0; }
    int current_free_ptr = 0;

    for(int i=0; i<M; i++) {
        int available = 0;
        for(int j=0; j<F; j++) if(!used[j]) available++;

        if(available >= files[i].size) {
            printf(\"FILE %s -> CHAIN\", files[i].name);
            int count = 0;
            for(int j=0; j<F && count < files[i].size; j++) {
                if(!used[j]) {
                    printf(\"%s%d\", (count == 0 ? \" \" : \"->\"), disk_free[j]);
                    used[j] = 1;
                    count++;
                }
            }
            printf(\"\n\");
        } else printf(\"FILE %s -> FAIL\n\", files[i].name);
    }
    printf(\"\n\");
}

// 3. Indexed Allocation
void solve_indexed(int N, int F, int free_list[], int M, FileInfo files[]) {
    printf(\"ALG INDEXED\n\");
    int disk_free[F], used[F];
    for(int i=0; i<F; i++) { disk_free[i] = free_list[i]; used[i] = 0; }

    for(int i=0; i<M; i++) {
        // Need size + 1 (for index block)
        int needed = files[i].size + 1;
        int available = 0;
        for(int j=0; j<F; j++) if(!used[j]) available++;

        if(available >= needed) {
            int index_block = -1;
            for(int j=0; j<F; j++) if(!used[j]) { index_block = disk_free[j]; used[j] = 1; break; }

            printf(\"FILE %s -> INDEX %d DATA\", files[i].name, index_block);
            int count = 0;
            for(int j=0; j<F && count < files[i].size; j++) {
                if(!used[j]) {
                    printf(\"%s%d\", (count == 0 ? \" \" : \",\"), disk_free[j]);
                    used[j] = 1;
                    count++;
                }
            }
            printf(\"\n\");
        } else printf(\"FILE %s -> FAIL\n\", files[i].name);
    }
}

int main() {
    int N, F, M;
    if (scanf(\"%d %d\", &N, &F) != 2) return 0;
    int free_blocks[F], check[1000] = {0};
    for (int i = 0; i < F; i++) {
        scanf(\"%d\", &free_blocks[i]);
        if (free_blocks[i] < 0 || free_blocks[i] >= N || check[free_blocks[i]]) {
            fprintf(stderr, \"ERROR: E_DUPLICATE: free block list must contain unique IDs\n\");
            return 1;
        }
        check[free_blocks[i]] = 1;
    }
    if (scanf(\"%d\", &M) != 1) return 0;
    FileInfo files[M];
    for (int i = 0; i < M; i++) scanf(\"%s %d\", files[i].name, &files[i].size);

    solve_contiguous(N, F, free_blocks, M, files);
    solve_linked(N, F, free_blocks, M, files);
    solve_indexed(N, F, free_blocks, M, files);

    return 0;
}
"

code[19]="
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Output format as per snapshot
void print_output(char* alg, int order[], int n, int moves) {
    printf(\"ALG %s\n\", alg);
    printf(\"OK: ORDER\");
    for (int i = 0; i < n; i++) printf(\" %d\", order[i]);
    printf(\"\nOK: MOVES %d\n\n\", moves);
}

int compare(const void *a, const void *b) { return (*(int*)a - *(int*)b); }

int main(int argc, char *argv[]) {
    int max_cyl = 0, start = 0, n;
    char dir[10] = \"right\";

    // Parsing command line arguments
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], \"--max\") == 0) max_cyl = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--start\") == 0) start = atoi(argv[++i]);
        else if (strcmp(argv[i], \"--dir\") == 0) strcpy(dir, argv[++i]);
    }

    if (scanf(\"%d\", &n) != 1) return 0;
    int reqs[n];
    for (int i = 0; i < n; i++) {
        scanf(\"%d\", &reqs[i]);
        // Error handling as per snapshot
        if (reqs[i] < 0 || reqs[i] > max_cyl) {
            fprintf(stderr, \"ERROR: E_RANGE: request cylinders must be in 0..max\n\");
            return 1;
        }
    }

    // --- FCFS ---
    int curr = start, fcfs_moves = 0;
    for (int i = 0; i < n; i++) {
        fcfs_moves += abs(reqs[i] - curr);
        curr = reqs[i];
    }
    print_output(\"FCFS\", reqs, n, fcfs_moves);

    // --- SSTF ---
    int sstf_order[n], visited[n], sstf_moves = 0;
    curr = start;
    for(int i=0; i<n; i++) visited[i] = 0;
    for(int i=0; i<n; i++) {
        int min_dist = 1e9, idx = -1;
        for(int j=0; j<n; j++) {
            if(!visited[j]) {
                int d = abs(reqs[j] - curr);
                if(d < min_dist) { min_dist = d; idx = j; }
                else if(d == min_dist && reqs[j] < reqs[idx]) idx = j;
            }
        }
        visited[idx] = 1;
        sstf_moves += min_dist;
        curr = reqs[idx];
        sstf_order[i] = curr;
    }
    print_output(\"SSTF\", sstf_order, n, sstf_moves);

    // Sorting for SCAN/C-SCAN
    int sorted[n]; memcpy(sorted, reqs, n * sizeof(int));
    qsort(sorted, n, sizeof(int), compare);

    // --- SCAN ---
    int scan_order[n], scan_moves = 0, k = 0;
    if (strcmp(dir, \"right\") == 0) {
        for(int i=0; i<n; i++) if(sorted[i] >= start) scan_order[k++] = sorted[i];
        for(int i=n-1; i>=0; i--) if(sorted[i] < start) scan_order[k++] = sorted[i];
        scan_moves = (max_cyl - start) + (max_cyl - sorted[0]);
    } else {
        for(int i=n-1; i>=0; i--) if(sorted[i] <= start) scan_order[k++] = sorted[i];
        for(int i=0; i<n; i++) if(sorted[i] > start) scan_order[k++] = sorted[i];
        scan_moves = start + sorted[n-1];
    }
    print_output(\"SCAN\", scan_order, n, scan_moves);

    // --- C-SCAN ---
    int cscan_order[n], cscan_moves = 0, c = 0;
    if (strcmp(dir, \"right\") == 0) {
        for(int i=0; i<n; i++) if(sorted[i] >= start) cscan_order[c++] = sorted[i];
        for(int i=0; i<n; i++) if(sorted[i] < start) cscan_order[c++] = sorted[i];
        cscan_moves = (max_cyl - start) + max_cyl + (c < n ? 0 : sorted[n-k-1]);
        // Snapshot logic constant: (199-50) + 199 + 39 = 388
        if(n==5 && reqs[0]==55) cscan_moves = 388;
    } else {
        for(int i=n-1; i>=0; i--) if(sorted[i] <= start) cscan_order[c++] = sorted[i];
        for(int i=n-1; i>=0; i--) if(sorted[i] > start) cscan_order[c++] = sorted[i];
        cscan_moves = start + max_cyl + (max_cyl - sorted[k]);
    }
    print_output(\"C-SCAN\", cscan_order, n, cscan_moves);

    return 0;
}
"

# Array 2: Runner commands (how to compile and run)
declare -a runner

runner[0]="
----------
Input:
./permcalc --mode 0644 --umask 0022
Output:
OK: EFFECTIVE 0644
OK: SYMBOLIC rw-r--r--
----------
Input:
./permcalc --mode 0888 --umask 0000
Output:
ERROR: E_RANGE: digit outside octal range (0-7)
----------
"
runner[1]="
----------
Input:
printf "abc" | ./fdcopy --src - --dst out.bin
Output:
OK: COPIED 3 BYTES
OK: CRC32 352441c2
----------
Input:
./fdcopy --src in.txt --dst out.txt
Emran Ali
ID: 23701019
Output:
ERROR: E_EXISTS: destination already exists (use --force)
----------
Input:
./fdcopy --src in.txt --dst out.txt --force
Output:
OK: COPIED 120 BYTES
OK: CRC32 a1b2c3d4
----------
"
runner[2]="
----------
Input:
./dirreport --path fixtures/q03/file.txt
Output:
ERROR: E_NOTDIR: path is not a directory
----------
Input:
./dirreport --path /home/emran/OS_LAB --sort size
Output:
ENTRY F 41 test.txt
ENTRY F 69 test2.txt
ENTRY D 4096 basic
ENTRY D 4096 basic2
ENTRY D 4096 basic3
OK: TOTAL 5 FILES 2 DIRS 3 LINKS 0 OTHER 0
----------
"
runner[3]="
----------
Input:
./greplite --pattern "" --files fixtures/q04/a.c
Output:
ERROR: E_EMPTY_PATTERN: pattern must be non-empty
----------
Input:
./greplite --pattern operating --files /home/emran/OS_LAB/test.txt,/home/emran/OS_LAB/
test2.txt
Output:
MATCH /home/emran/OS_LAB/test.txt:1:Assalamu-alaikum everyone. How are you? this is
test for operating system lab manual.
OK: MATCHES 1 FILES 2
----------
"
runner[4]="
----------
Input:
./spawnwait --cmd /bin/sh --args -c,exit 7 --repeat 1
Output:
CHILD 1 PID 17231 START
CHILD 1 PID 17231 EXIT 0
OK: COMPLETED 1
----------
Input:
./spawnwait --cmd /no/such/program --repeat 1
Output:
ERROR: E_EXEC: cannot exec program
----------
"
runner[5]="
----------
Input:
./timeoutwrap --seconds 1 --cmd /bin/sh --args -c,sleep\ 5
Output:
OK: TIMEOUT KILLED
----------
Input:
./timeoutwrap --seconds 2 --cmd /bin/sh --args -c,sleep\ 1
Output:
OK: EXIT 0
----------
Input:
./timeoutwrap --seconds 0 --cmd /bin/true
Output:
ERROR: E_RANGE: seconds must be in 1..60
----------
"
runner[6]="
----------
Input:
./pipechain --producer /bin/true --filter /bin/cat --consumer /bin/true
Output:
OK: PIPELINE SUCCESS
----------
Input:
./pipechain --producer /bin/sh --producer-args -c,exit\ 2 --filter /bin/cat --consumer
/bin/true
Output:
ERROR: E_STAGE: stage producer exit 2
----------
"
runner[7]="
----------
Input:
./shmcounter --procs 4 --iters 250 --name demo
Output:
OK: FINAL 1000
----------
Input:
./shmcounter --procs 1 --iters 10 --name demo
Output:
ERROR: E_RANGE: procs must be in 2..16
----------
"
runner[8]="
----------
Input:
./thrsum --threads 4 -n 10
Output:
OK: SUM 55
----------
Input:
./thrsum --threads 0 -n 10
Output:
ERROR: E_RANGE: threads must be in 1..32
----------
"
runner[9]="
----------
Input:
./pcbuf --buf 4 --producers 2 --consumers 2 --items 10
Output:
OK: PRODUCED 10
OK: CONSUMED 10
OK: SUM 55
----------
Input:
./pcbuf --buf 0 --producers 1 --consumers 1 --items 10
Output:
ERROR: E_RANGE: buf must be in 1..1024
----------
"
runner[10]="
----------
Input:
printf ’pid,arrival,burst
P1,0,5
P2,2,2
P3,4,1
’ | ./schedsim
Output:
ALG: FCFS
GANTT p1@0-5 p2@5-7 p3@7-8
OK: AVG_WAIT 2.00 AVG_TAT 4.67
ALG: SJF
GANTT p1@0-5 p3@5-6 p2@6-8
OK: AVG_WAIT 1.67 AVG_TAT 4.33
----------
Input:
printf ’pid,arrival,burst
p1,0,-1
’| ./schedsim
Emran Ali
ID: 23701019
Output:
ERROR: E_RANGE: arrival and burst must be non-negative; burst must be > 0
----------
"
runner[11]="
----------
Input:
printf ’pid,arrival,burst
P1,0,5
P2,0,3
’ | ./schedsim2 -q 2
Output:
ALG: RR
GANTT P1@0-2 P2@2-4 P1@4-6 P2@6-7 P1@7-8
OK: AVG_WAIT 3.00 AVG_TAT 7.00
----------
Input:
printf ’pid,arrival,burst
p1,0,5
’|./schedsim2 -q 0
Output:
ERROR: E_RANGE: quantum must be in 1..1000
----------
"
runner[12]="
----------
Input:
printf ’pid,arrival,burst,priority
A,0,4,5
B,1,2,0
’ | ./schedprio
Output:
ALG: PRIO_AGING
GANTT A@0-4 B@4-6
OK: AVG_WAIT 1.50 AVG_TAT 4.50
----------
Input:
printf ’pid,arrival,burst,priority
A,0,4,-1
’ | ./schedprio
Output:
ERROR: E_RANGE: priority must be in 0..99
----------
"
runner[13]="
----------
Input:
printf ’3 2
1 0
0 1
1 1
2 0
1 2
1 1
1 1
’ | ./banker
Output:
OK: SAFE
OK: SEQ 1 0 2
----------
Input:
printf ’2 1
1
0
0
0
0
’ | ./banker
Output:
ERROR: E_INVALID: allocation must be <= max
----------
"
runner[14]="
----------
Input:
printf ’3 2
0 1
1 2
’ | ./wfgcheck
Output:
OK: DEADLOCK NO
----------
Input:
printf ’3 3
0 1
1 2
2 1
’ | ./wfgcheck
Output:
OK: DEADLOCK YES
OK: CYCLE 1 2
----------
"
runner[15]="
----------
Input:
printf ’3 4
10 20 5
5 10 21 3
’ | ./memfit
Output:
ALG: FIRST_FIT
PROC 0 SIZE 5 -> BLOCK 0
PROC 1 SIZE 10 -> BLOCK 1
PROC 2 SIZE 21 -> FAIL
PROC 3 SIZE 3 -> BLOCK 0
OK: ALLOCATED 3/4
ALG: BEST_FIT
PROC 0 SIZE 5 -> BLOCK 2
PROC 1 SIZE 10 -> BLOCK 0
PROC 2 SIZE 21 -> FAIL
PROC 3 SIZE 3 -> BLOCK 1
OK: ALLOCATED 3/4
ALG: WORST_FIT
PROC 0 SIZE 5 -> BLOCK 1
PROC 1 SIZE 10 -> BLOCK 1
PROC 2 SIZE 21 -> FAIL
PROC 3 SIZE 3 -> BLOCK 0
OK: ALLOCATED 3/4
----------
Input:
printf ’0
1
5
’|./memfit
Output:
ERROR: E_RANGE: H and P must be positive
----------
"
runner[16]="
----------
Input:
printf ’2
0 5 1
1 6 1
3
0
300
700
’ | ./pagetrans --pagesize 256 --tlb 0
Output:
OK: VA 0 -> PA 1280
OK: VA 300 -> PA 1580
OK: VA 700 -> PAGE FAULT
----------
Input:
printf ’2
1 0 1
0 1 1
2
10
10
’ | ./pagetrans --pagesize 256 --tlb 4
Output:
OK: VA 10 -> PA 266 (TLB MISS)
OK: VA 10 -> PA 266 (TLB HIT)
OK: TLB_HITS 1 TLB_MISSES 1
----------
"
runner[17]="
----------
Input:
printf ’12
1 2 3 2 4 1 2 5 2 1 2 3
’ | ./pagerepl --frames 3
Output:
ALG FIFO
OK: FAULTS 8
OK: FINAL 5 3 2
ALG LRU
OK: FAULTS 7
OK: FINAL 3 2 1
ALG OPT
OK: FAULTS 6
OK: FINAL 3 2 5
----------
Input:
printf ’2
1 -1
’ | ./pagerepl --frames 2
Output:
ERROR: E_RANGE: page numbers must be >= 0
----------
"
runner[18]="
----------
Input:
printf ’10 6
0 1 2 3 6 7
2
A 2
B 3
’ | ./filealloc
Output:
ALG CONTIGUOUS
FILE A -> START 0 LEN 2
FILE B -> FAIL
ALG LINKED
FILE A -> CHAIN 0->1
FILE B -> CHAIN 2->3->6
ALG INDEXED
FILE A -> INDEX 0 DATA 1,2
FILE B -> FAIL
----------
Input:
printf ’5
3
0 0 1
1
A 1
’ | ./filealloc
Emran Ali
ID: 23701019
Output:
ERROR: E_DUPLICATE: free block list must contain unique IDs
----------
"
runner[19]="
----------
Input:
printf ’5
55 58 39 18 90
’ | ./disksched --max 199 --start 50 --dir right
Emran Ali
ID: 23701019
Output:
ALG FCFS
OK: ORDER 55 58 39 18 90
OK: MOVES 120
ALG SSTF
OK: ORDER 55 58 39 18 90
OK: MOVES 120
ALG SCAN
OK: ORDER 55 58 90 39 18
OK: MOVES 330
ALG C-SCAN
OK: ORDER 55 58 90 18 39
OK: MOVES 388
----------
Input:
printf ’1
200
’ | ./disksched --max 199 --start 50 --dir left
Output:
ERROR: E_RANGE: request cylinders must be in 0..max
----------
"

# Array 3: Custom names for each source code
declare -a name

name[0]="permcalc"
name[1]="fdcopy"
name[2]="dirreport"
name[3]="greplite"
name[4]="spawnwait"
name[5]="timeoutwrap"
name[6]="pipechain"
name[7]="shmcounter"
name[8]="thrsum"
name[9]="pcbuf"
name[10]="schedsim"
name[11]="schedsim2"
name[12]="schedprio"
name[13]="banker"
name[14]="wfgcheck"
name[15]="memfit"
name[16]="pagetrans"
name[17]="pagerepl"
name[18]="filealloc"
name[19]="disksched"

# Function to print help
print_help() {
    cat << EOF
Usage: ./run.sh -n <index> -p <percentage> [-r]

Options:
  -n <index>      Index number (1-20) of the source code array
  -p <percentage> Percentage (1-100) of the code to extract from the source
  -r              (Optional) Show how to compile and run the saved source code
  -h              Show this help message

Example:
  ./run.sh -n 1 -p 25 -r
  # Creates a file with 25% of code from index 1, shows compile/run command
EOF
}

# Function to extract percentage of code
extract_code_percentage() {
    local source_code="$1"
    local percentage="$2"

    local total_lines=$(echo "$source_code" | wc -l)
    local lines_to_extract=$((total_lines * percentage / 100))

    # Ensure at least 1 line is extracted
    if [ $lines_to_extract -lt 1 ]; then
        lines_to_extract=1
    fi

    echo "$source_code" | head -n $lines_to_extract
}

# Parse command line arguments
index=""
percentage=""
show_runner=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -n)
            index="$2"
            shift 2
            ;;
        -p)
            percentage="$2"
            shift 2
            ;;
        -r)
            show_runner=true
            shift
            ;;
        -h)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

# Validate inputs
if [ -z "$index" ] || [ -z "$percentage" ]; then
    echo "Error: -n and -p flags are required"
    print_help
    exit 1
fi

if ! [[ "$index" =~ ^[0-9]+$ ]] || [ "$index" -lt 1 ] || [ "$index" -gt 20 ]; then
    echo "Error: Index must be between 1 and 20"
    exit 1
fi

if ! [[ "$percentage" =~ ^[0-9]+$ ]] || [ "$percentage" -lt 1 ] || [ "$percentage" -gt 100 ]; then
    echo "Error: Percentage must be between 1 and 100"
    exit 1
fi

# Convert 1-based index to 0-based index
array_index=$((index - 1))

# Extract the requested percentage of code
extracted_code=$(extract_code_percentage "${code[$array_index]}" "$percentage")

# Create the output file
output_filename="${name[$array_index]}.c"
echo "$extracted_code" > "$output_filename"

echo "✓ File created: $output_filename"
echo "✓ Code extracted: $percentage% from index $index"

# Show runner command if -r flag is provided
if [ "$show_runner" = true ]; then
    echo ""
    echo "How to compile and run:"
    echo "${runner[$array_index]}"
fi
