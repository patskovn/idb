/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include "IDBVideoShm.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int idbv_shm_create(const char *name, unsigned long size) {
  int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
  if (fd < 0) {
    return -1;
  }
  if (ftruncate(fd, (off_t)size) != 0) {
    int saved = errno;
    close(fd);
    shm_unlink(name);
    errno = saved;
    return -1;
  }
  return fd;
}
