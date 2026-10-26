/*
 * The guest side of scripts/measure-vsock-buffer.swift: a static aarch64 Linux program that
 * opens vsock connections from the guest to the host. scripts/measure-vsock-buffer.sh compiles
 * it with the Static Linux SDK's musl, and the measurement copies it into the guest's /run
 * through the agent. It is a development tool and not part of maw or of the initramfs.
 *
 * Usage:
 *   write <port> <bytes> <tag>
 *       Connects to the host's <port>, writes <bytes> zero bytes, and closes. Whenever a write
 *       has waited 100 ms, writes "vsock-count <tag> <bytes written>" to /dev/hvc0, and once
 *       more at the end.
 *   accept-write <guest port> <bytes> <tag>
 *       Listens on <guest port>, accepts one connection from the host, and writes to it as
 *       write does: the same program on a host-initiated connection.
 *   ping <port> <interval ms>
 *       Detaches, then connects to the host's <port> every <interval> ms, writes an 8-byte
 *       sequence number, and closes. Runs until the machine stops.
 *   serve <guest port> <host port>
 *       Detaches and listens on <guest port>. For each 16 bytes read from an accepted
 *       connection, binds a source port below 1024, connects to the host's <host port>,
 *       writes the 16 bytes, and closes: a stand-in for an agent that dials back.
 *   ports <host port>
 *       Reports which source ports root and an unprivileged user (65534) may bind, and the
 *       port an unbound connection to the host's <host port> receives. Prints one line per
 *       check to standard output.
 */

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <linux/vm_sockets.h>

static void fail(const char *what) {
    fprintf(stderr, "measure-vsock-guest: %s: %s\n", what, strerror(errno));
    exit(1);
}

static int open_socket(void) {
    int descriptor = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (descriptor < 0) fail("socket");
    return descriptor;
}

/* 0 or the errno of bind(<port>). */
static int bind_port(int descriptor, unsigned port) {
    struct sockaddr_vm address = {.svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_ANY,
                                  .svm_port = port};
    return bind(descriptor, (struct sockaddr *)&address, sizeof address) == 0 ? 0 : errno;
}

/* 0 or the errno of connect() to the host's <port>. */
static int connect_host(int descriptor, unsigned port) {
    struct sockaddr_vm address = {.svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_HOST,
                                  .svm_port = port};
    return connect(descriptor, (struct sockaddr *)&address, sizeof address) == 0 ? 0 : errno;
}

static unsigned local_port(int descriptor) {
    struct sockaddr_vm address = {0};
    socklen_t length = sizeof address;
    if (getsockname(descriptor, (struct sockaddr *)&address, &length) != 0) return 0;
    return address.svm_port;
}

static int write_all(int descriptor, const void *bytes, size_t count) {
    const char *next = bytes;
    while (count > 0) {
        ssize_t written = write(descriptor, next, count);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        next += written;
        count -= (size_t)written;
    }
    return 0;
}

static int read_all(int descriptor, void *bytes, size_t count) {
    char *next = bytes;
    while (count > 0) {
        ssize_t got = read(descriptor, next, count);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return -1;
        next += got;
        count -= (size_t)got;
    }
    return 0;
}

static void report_count(int console, const char *tag, unsigned long long count) {
    char line[128];
    int length = snprintf(line, sizeof line, "vsock-count %s %llu\n", tag, count);
    write_all(console, line, (size_t)length);
}

/* Writes <total> zero bytes to <descriptor>, reporting on the console as `write` describes. */
static int write_stream(int descriptor, unsigned long long total, const char *tag) {
    int console = open("/dev/hvc0", O_WRONLY | O_CLOEXEC);
    if (console < 0) fail("open /dev/hvc0");
    fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK);
    static char chunk[8192];
    unsigned long long written = 0, reported = ~0ULL;
    while (written < total) {
        size_t size = total - written < sizeof chunk ? (size_t)(total - written) : sizeof chunk;
        ssize_t count = write(descriptor, chunk, size);
        if (count > 0) {
            written += (unsigned long long)count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && errno != EAGAIN) fail("write");
        struct pollfd request = {.fd = descriptor, .events = POLLOUT};
        if (poll(&request, 1, 100) == 0 && reported != written) {
            report_count(console, tag, written);
            reported = written;
        }
    }
    report_count(console, tag, written);
    close(descriptor);
    return 0;
}

static int write_command(unsigned port, unsigned long long total, const char *tag) {
    int descriptor = open_socket();
    int error = connect_host(descriptor, port);
    if (error != 0) {
        errno = error;
        fail("connect");
    }
    return write_stream(descriptor, total, tag);
}

static int accept_write_command(unsigned port, unsigned long long total, const char *tag) {
    int listener = open_socket();
    int error = bind_port(listener, port);
    if (error != 0) {
        errno = error;
        fail("bind");
    }
    if (listen(listener, 1) != 0) fail("listen");
    int descriptor = accept(listener, NULL, NULL);
    if (descriptor < 0) fail("accept");
    close(listener);
    return write_stream(descriptor, total, tag);
}

/* Detaches from the agent's session: a new session, standard descriptors on /dev/null. */
static void detach(void) {
    pid_t child = fork();
    if (child < 0) fail("fork");
    if (child > 0) exit(0);
    setsid();
    int null = open("/dev/null", O_RDWR);
    dup2(null, 0);
    dup2(null, 1);
    dup2(null, 2);
    if (null > 2) close(null);
}

static int ping_command(unsigned port, unsigned interval) {
    detach();
    for (uint64_t sequence = 0;; sequence++) {
        int descriptor = open_socket();
        if (connect_host(descriptor, port) == 0) {
            unsigned char bytes[8];
            for (int index = 0; index < 8; index++) bytes[index] = (unsigned char)(sequence >> (56 - 8 * index));
            write_all(descriptor, bytes, sizeof bytes);
        }
        close(descriptor);
        struct timespec pause = {.tv_sec = interval / 1000, .tv_nsec = (long)(interval % 1000) * 1000000};
        nanosleep(&pause, NULL);
    }
}

static int serve_command(unsigned guest_port, unsigned host_port) {
    int listener = open_socket();
    int error = bind_port(listener, guest_port);
    if (error != 0) {
        errno = error;
        fail("bind");
    }
    if (listen(listener, 4) != 0) fail("listen");
    detach();
    unsigned next_port = 1023;
    for (;;) {
        int control = accept(listener, NULL, NULL);
        if (control < 0) {
            if (errno == EINTR) continue;
            fail("accept");
        }
        unsigned char nonce[16];
        while (read_all(control, nonce, sizeof nonce) == 0) {
            int descriptor = -1;
            /* A port the host has not released yet is in use; try the next. */
            for (int attempt = 0; attempt < 512; attempt++) {
                descriptor = open_socket();
                unsigned port = next_port;
                next_port = next_port == 512 ? 1023 : next_port - 1;
                if (bind_port(descriptor, port) == 0 && connect_host(descriptor, host_port) == 0) break;
                close(descriptor);
                descriptor = -1;
            }
            if (descriptor < 0) break;
            write_all(descriptor, nonce, sizeof nonce);
            close(descriptor);
        }
        close(control);
    }
}

/* One line: "<who> bind <port>: ok" or the error. */
static void check_bind(const char *who, unsigned port) {
    int descriptor = open_socket();
    int error = bind_port(descriptor, port);
    printf("%s bind %u: %s\n", who, port, error == 0 ? "ok" : strerror(error));
    close(descriptor);
}

static int ports_command(unsigned host_port) {
    check_bind("root (uid 0)", 1000);
    check_bind("root (uid 0)", 1023);
    fflush(stdout);
    pid_t child = fork();
    if (child < 0) fail("fork");
    if (child == 0) {
        if (setgroups(0, NULL) != 0 || setgid(65534) != 0 || setuid(65534) != 0) fail("setuid");
        check_bind("uid 65534", 1);
        check_bind("uid 65534", 1000);
        check_bind("uid 65534", 1023);
        check_bind("uid 65534", 1024);
        int descriptor = open_socket();
        int error = connect_host(descriptor, host_port);
        if (error == 0) {
            printf("uid 65534 unbound connection: source port %u\n", local_port(descriptor));
        } else {
            printf("uid 65534 unbound connection: %s\n", strerror(error));
        }
        close(descriptor);
        fflush(stdout);
        _exit(0);
    }
    int status = 0;
    waitpid(child, &status, 0);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 5 && strcmp(argv[1], "write") == 0) {
        return write_command((unsigned)atoi(argv[2]), strtoull(argv[3], NULL, 10), argv[4]);
    }
    if (argc == 5 && strcmp(argv[1], "accept-write") == 0) {
        return accept_write_command((unsigned)atoi(argv[2]), strtoull(argv[3], NULL, 10), argv[4]);
    }
    if (argc == 4 && strcmp(argv[1], "ping") == 0) {
        return ping_command((unsigned)atoi(argv[2]), (unsigned)atoi(argv[3]));
    }
    if (argc == 4 && strcmp(argv[1], "serve") == 0) {
        return serve_command((unsigned)atoi(argv[2]), (unsigned)atoi(argv[3]));
    }
    if (argc == 3 && strcmp(argv[1], "ports") == 0) {
        return ports_command((unsigned)atoi(argv[2]));
    }
    fprintf(stderr, "usage: measure-vsock-guest write <port> <bytes> <tag> | "
                    "accept-write <guest port> <bytes> <tag> | ping <port> <ms> | "
                    "serve <guest port> <host port> | ports <host port>\n");
    return 64;
}
