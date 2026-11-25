/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#pragma once

/// Creates a new POSIX shared memory object readable and writable by this user only, sized to
/// `size` bytes, and returns its descriptor, or -1 with errno set. Swift cannot call the variadic
/// shm_open directly.
int idbv_shm_create(const char *name, unsigned long size);
