// A guarded allocator for libzt, for finding heap corruption (enabled with the memory_guard user define).
//
// libzt's lwIP is built with MEM_LIBC_MALLOC and MEMP_MEM_MALLOC, so every packet buffer and protocol
// segment is a separate malloc() in the process heap, next to the app's own allocations. An overrun or
// a write after free there damages whatever lies next to it and only shows later, as an unrelated crash.
//
// The linker sends libzt's malloc/calloc/realloc/free/... here (-Wl,--wrap). Each allocation gets its
// own pages and ends exactly at a PROT_NONE guard page; a write past the end faults at once, inside
// libzt. Freed memory is released and made PROT_NONE, and the last kQuarantine frees stay that way, so a
// late write or a second free faults too. Pointers libzt did not get from here (memory allocated by libc
// itself) go to the real allocator; so does everything once kMaxMapped bytes are guarded or mmap fails.
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

void *__real_malloc(size_t size);
void *__real_calloc(size_t n, size_t size);
void *__real_realloc(void *p, size_t size);
void __real_free(void *p);
int __real_posix_memalign(void **out, size_t align, size_t size);
void *__real_memalign(size_t align, size_t size);
void *__real_aligned_alloc(size_t align, size_t size);
size_t __real_malloc_usable_size(const void *p);

#define kMagic 0x5a7447756172644bULL
#define kBuckets 65536
#define kQuarantine 4096
#define kMaxMapped ((size_t)256 << 20)

typedef struct Header {
  uint64_t magic;
  struct Header *next; // registry chain
  void *user;
  size_t size;
  char *base;
  size_t len;
} Header;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static size_t page;
static Header *buckets[kBuckets];
static void *quarantine_user[kQuarantine];
static char *quarantine_base[kQuarantine];
static size_t quarantine_len[kQuarantine];
static size_t quarantine_next;

// live, live bytes (asked for), mapped bytes, allocations, fallbacks, in quarantine
static uint64_t stats[6];

static size_t bucket(const void *p) { return ((uintptr_t)p >> 4) * 2654435761u % kBuckets; }

static Header *take(void *p) { // removes p from the registry; caller holds mu
  Header **link = &buckets[bucket(p)];
  for (Header *h = *link; h; link = &h->next, h = h->next) {
    if (h->user == p) {
      *link = h->next;
      return h;
    }
  }
  return NULL;
}

static Header *find(const void *p) { // caller holds mu
  for (Header *h = buckets[bucket(p)]; h; h = h->next) {
    if (h->user == p) return h;
  }
  return NULL;
}

static int quarantined(const void *p) { // caller holds mu
  for (size_t i = 0; i < kQuarantine; i++) {
    if (quarantine_user[i] == p) return 1;
  }
  return 0;
}

static void *guarded(size_t size, size_t align) {
  if (!page) page = (size_t)sysconf(_SC_PAGESIZE);
  if (align < 16) align = 16;
  if (align > page || (align & (align - 1)) || size > kMaxMapped) return NULL;
  size_t user = size ? (size + align - 1) & ~(align - 1) : align;
  size_t data_pages = (user + sizeof(Header) + align + page - 1) / page;
  size_t len = (data_pages + 1) * page;
  if (stats[2] + len > kMaxMapped) return NULL; // racy read, only a soft cap
  char *base = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (base == MAP_FAILED) return NULL;
  char *guard = base + data_pages * page;
  if (mprotect(guard, page, PROT_NONE) != 0) {
    munmap(base, len);
    return NULL;
  }
  // The buffer ends where the guard page starts: one byte too far faults.
  char *p = guard - user;
  Header *h = (Header *)((uintptr_t)(p - sizeof(Header)) & ~(uintptr_t)15);
  h->magic = kMagic;
  h->user = p;
  h->size = size;
  h->base = base;
  h->len = len;
  pthread_mutex_lock(&mu);
  size_t b = bucket(p);
  h->next = buckets[b];
  buckets[b] = h;
  stats[0]++;
  stats[1] += size;
  stats[2] += len;
  stats[3]++;
  pthread_mutex_unlock(&mu);
  return p;
}

static void retire(Header *h) { // caller holds mu; h is out of the registry
  // Read everything before the pages (the header with them) become inaccessible.
  char *base = h->base;
  size_t len = h->len;
  void *user = h->user;
  stats[0]--;
  stats[1] -= h->size;
  stats[2] -= len;
  // Give the pages back, keep the range inaccessible for a while.
  madvise(base, len, MADV_DONTNEED);
  mprotect(base, len, PROT_NONE);
  size_t slot = quarantine_next++ % kQuarantine;
  if (quarantine_base[slot]) {
    munmap(quarantine_base[slot], quarantine_len[slot]);
  } else {
    stats[5]++;
  }
  quarantine_user[slot] = user;
  quarantine_base[slot] = base;
  quarantine_len[slot] = len;
}

void *__wrap_malloc(size_t size) {
  void *p = guarded(size, 16);
  if (p) return p;
  __atomic_add_fetch(&stats[4], 1, __ATOMIC_RELAXED);
  return __real_malloc(size);
}

void *__wrap_calloc(size_t n, size_t size) {
  size_t total;
  if (__builtin_mul_overflow(n, size, &total)) {
    errno = ENOMEM;
    return NULL;
  }
  void *p = guarded(total, 16); // fresh mappings are zeroed
  if (p) return p;
  __atomic_add_fetch(&stats[4], 1, __ATOMIC_RELAXED);
  return __real_calloc(n, size);
}

void __wrap_free(void *p) {
  if (!p) return;
  pthread_mutex_lock(&mu);
  Header *h = take(p);
  if (h) {
    retire(h);
    pthread_mutex_unlock(&mu);
    return;
  }
  if (quarantined(p)) {
    // Freed twice: stop here, with libzt's call in the crash report.
    pthread_mutex_unlock(&mu);
    __builtin_trap();
  }
  pthread_mutex_unlock(&mu);
  __real_free(p);
}

void *__wrap_realloc(void *p, size_t size) {
  if (!p) return __wrap_malloc(size);
  pthread_mutex_lock(&mu);
  Header *h = find(p);
  size_t old = h ? h->size : 0;
  int was_quarantined = h ? 0 : quarantined(p);
  pthread_mutex_unlock(&mu);
  if (was_quarantined) __builtin_trap(); // resized after free
  if (!h) return __real_realloc(p, size);
  if (size == 0) {
    __wrap_free(p);
    return NULL;
  }
  void *q = __wrap_malloc(size);
  if (!q) return NULL;
  memcpy(q, p, old < size ? old : size);
  __wrap_free(p);
  return q;
}

int __wrap_posix_memalign(void **out, size_t align, size_t size) {
  void *p = guarded(size, align);
  if (p) {
    *out = p;
    return 0;
  }
  __atomic_add_fetch(&stats[4], 1, __ATOMIC_RELAXED);
  return __real_posix_memalign(out, align, size);
}

void *__wrap_memalign(size_t align, size_t size) {
  void *p = guarded(size, align);
  if (p) return p;
  __atomic_add_fetch(&stats[4], 1, __ATOMIC_RELAXED);
  return __real_memalign(align, size);
}

void *__wrap_aligned_alloc(size_t align, size_t size) {
  void *p = guarded(size, align);
  if (p) return p;
  __atomic_add_fetch(&stats[4], 1, __ATOMIC_RELAXED);
  return __real_aligned_alloc(align, size);
}

size_t __wrap_malloc_usable_size(const void *p) {
  pthread_mutex_lock(&mu);
  Header *h = p ? find(p) : NULL;
  size_t size = h ? h->size : 0;
  pthread_mutex_unlock(&mu);
  return h ? size : __real_malloc_usable_size(p);
}

/// Fills out[6]: live allocations, their bytes, guarded bytes mapped, allocations so far, fallbacks to the
/// real allocator, frees held in quarantine. Returns 1 (the guard is built in).
__attribute__((visibility("default"))) int zts_guard_stats(uint64_t *out) {
  pthread_mutex_lock(&mu);
  for (int i = 0; i < 6; i++) out[i] = stats[i];
  pthread_mutex_unlock(&mu);
  return 1;
}

/// For tests: misuses a guarded allocation the way a bug would (1 overrun, 2 write after free,
/// 3 double free). The process should die at once.
__attribute__((visibility("default"))) void zts_guard_selftest(int kind) {
  volatile char *p = (volatile char *)__wrap_malloc(16);
  switch (kind) {
    case 1:
      p[16] = 1;
      break;
    case 2:
      __wrap_free((void *)p);
      p[0] = 1;
      break;
    case 3:
      __wrap_free((void *)p);
      __wrap_free((void *)p);
      break;
  }
}
