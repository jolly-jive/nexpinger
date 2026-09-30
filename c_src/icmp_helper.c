/*
 * icmp_helper.exe - Windows ICMP helper for NexPinger
 *
 * Sends ICMP Echo via IcmpSendEcho2 / Icmp6SendEcho2 (no admin rights needed).
 * Unlike ping.exe, output does not depend on the display language.
 *
 * Reads one request per line from stdin and handles each in its own thread.
 * Writes one reply per line to stdout, in completion order. On stdin close,
 * replies to pending requests, then exits.
 *
 *   Request: <id> <address> <timeout_ms>
 *   Reply:   <id> ok <rtt_ms>
 *            <id> error <reason>
 *
 * Build (WSL / Linux / macOS):
 *   zig cc -target x86_64-windows-gnu -O2 -o priv/bin/icmp_helper.exe \
 *     c_src/icmp_helper.c -liphlpapi -lws2_32
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <icmpapi.h>

#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PAYLOAD_SIZE 32
#define REPLY_BUFFER_SIZE 1024
#define ID_SIZE 32
#define ADDRESS_SIZE 256

struct request {
    char id[ID_SIZE];
    char address[ADDRESS_SIZE];
    DWORD timeout_ms;
};

static CRITICAL_SECTION output_lock;
static LARGE_INTEGER qpc_frequency;
static volatile LONG active_requests = 0;

static void reply_ok(const char *id, double rtt_ms)
{
    EnterCriticalSection(&output_lock);
    printf("%s ok %.3f\n", id, rtt_ms);
    fflush(stdout);
    LeaveCriticalSection(&output_lock);
}

static void reply_error(const char *id, const char *reason)
{
    EnterCriticalSection(&output_lock);
    printf("%s error %s\n", id, reason);
    fflush(stdout);
    LeaveCriticalSection(&output_lock);
}

static void reply_status(const char *id, DWORD status)
{
    char reason[64];

    switch (status) {
    case IP_REQ_TIMED_OUT:
        reply_error(id, "timeout");
        return;
    case IP_DEST_NET_UNREACHABLE:
    case IP_DEST_HOST_UNREACHABLE:
    case IP_DEST_PROT_UNREACHABLE:
    case IP_DEST_PORT_UNREACHABLE:
        reply_error(id, "unreachable");
        return;
    case IP_TTL_EXPIRED_TRANSIT:
        reply_error(id, "ttl expired");
        return;
    default:
        snprintf(reason, sizeof(reason), "icmp status %lu", (unsigned long)status);
        reply_error(id, reason);
        return;
    }
}

static double elapsed_ms(LARGE_INTEGER started, LARGE_INTEGER finished)
{
    return (double)(finished.QuadPart - started.QuadPart) * 1000.0 / (double)qpc_frequency.QuadPart;
}

static void ping_v4(const struct request *req, const struct sockaddr_in *dest)
{
    char data[PAYLOAD_SIZE];
    unsigned char reply[REPLY_BUFFER_SIZE];
    LARGE_INTEGER started, finished;
    HANDLE icmp = IcmpCreateFile();

    if (icmp == INVALID_HANDLE_VALUE) {
        reply_error(req->id, "IcmpCreateFile failed");
        return;
    }

    memset(data, 'E', sizeof(data));

    QueryPerformanceCounter(&started);
    DWORD count = IcmpSendEcho2(icmp, NULL, NULL, NULL, dest->sin_addr.S_un.S_addr, data,
                                sizeof(data), NULL, reply, sizeof(reply), req->timeout_ms);
    QueryPerformanceCounter(&finished);

    if (count == 0) {
        reply_status(req->id, GetLastError());
    } else {
        PICMP_ECHO_REPLY echo = (PICMP_ECHO_REPLY)reply;
        if (echo->Status == IP_SUCCESS)
            reply_ok(req->id, elapsed_ms(started, finished));
        else
            reply_status(req->id, echo->Status);
    }

    IcmpCloseHandle(icmp);
}

static void ping_v6(const struct request *req, struct sockaddr_in6 *dest)
{
    char data[PAYLOAD_SIZE];
    unsigned char reply[REPLY_BUFFER_SIZE];
    struct sockaddr_in6 source;
    LARGE_INTEGER started, finished;
    HANDLE icmp = Icmp6CreateFile();

    if (icmp == INVALID_HANDLE_VALUE) {
        reply_error(req->id, "Icmp6CreateFile failed");
        return;
    }

    memset(data, 'E', sizeof(data));
    memset(&source, 0, sizeof(source));
    source.sin6_family = AF_INET6;

    QueryPerformanceCounter(&started);
    DWORD count = Icmp6SendEcho2(icmp, NULL, NULL, NULL, &source, dest, data, sizeof(data),
                                 NULL, reply, sizeof(reply), req->timeout_ms);
    QueryPerformanceCounter(&finished);

    if (count == 0) {
        reply_status(req->id, GetLastError());
    } else {
        PICMPV6_ECHO_REPLY echo = (PICMPV6_ECHO_REPLY)reply;
        if (echo->Status == IP_SUCCESS)
            reply_ok(req->id, elapsed_ms(started, finished));
        else
            reply_status(req->id, echo->Status);
    }

    IcmpCloseHandle(icmp);
}

/* Resolve IPv4 first, then IPv6 (same order as IcmpSocket on Linux) */
static void ping(const struct request *req)
{
    struct addrinfo hints;
    struct addrinfo *result = NULL;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    if (getaddrinfo(req->address, NULL, &hints, &result) == 0 && result != NULL) {
        ping_v4(req, (const struct sockaddr_in *)result->ai_addr);
        freeaddrinfo(result);
        return;
    }

    hints.ai_family = AF_INET6;
    if (getaddrinfo(req->address, NULL, &hints, &result) == 0 && result != NULL) {
        ping_v6(req, (struct sockaddr_in6 *)result->ai_addr);
        freeaddrinfo(result);
        return;
    }

    reply_error(req->id, "unknown host");
}

static DWORD WINAPI ping_thread(LPVOID arg)
{
    struct request *req = (struct request *)arg;
    ping(req);
    free(req);
    InterlockedDecrement(&active_requests);
    return 0;
}

int main(void)
{
    WSADATA wsa;
    char line[512];

    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);

    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        fprintf(stderr, "WSAStartup failed\n");
        return 1;
    }

    InitializeCriticalSection(&output_lock);
    QueryPerformanceFrequency(&qpc_frequency);

    while (fgets(line, sizeof(line), stdin) != NULL) {
        struct request *req = (struct request *)calloc(1, sizeof(struct request));
        unsigned long timeout_ms = 0;

        if (req == NULL)
            continue;

        line[strcspn(line, "\r\n")] = '\0';

        int fields = sscanf(line, "%31s %255s %lu", req->id, req->address, &timeout_ms);
        if (fields != 3) {
            if (fields >= 1)
                reply_error(req->id, "bad request");
            free(req);
            continue;
        }

        req->timeout_ms = timeout_ms > 0 ? (DWORD)timeout_ms : 1;

        InterlockedIncrement(&active_requests);
        HANDLE thread = CreateThread(NULL, 0, ping_thread, req, 0, NULL);
        if (thread == NULL)
            ping_thread(req);
        else
            CloseHandle(thread);
    }

    /* stdin closed: reply to pending requests (up to their timeout), then exit */
    while (InterlockedCompareExchange(&active_requests, 0, 0) > 0)
        Sleep(10);

    return 0;
}
