// SPDX-License-Identifier: CDDL-1.0
/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or https://opensource.org/licenses/CDDL-1.0.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * Copyright (c) 2026, Amazon.com, Inc. or its affiliates.
 */

/*
 * File handle encode and open.
 *
 *   open_by_handle -e PATH          write the file handle of PATH to stdout
 *   open_by_handle -o MOUNTPOINT    open the file handle read from stdin
 *                                   and print the path the kernel gives
 *                                   the open file
 *
 * The handle is the raw kernel structure, so it only means something on
 * the host that produced it.  MOUNTPOINT is the mount the handle belongs
 * to; FreeBSD finds the mount from the handle itself and ignores it.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef __FreeBSD__
#include <sys/param.h>
#include <sys/mount.h>
#endif

static void
die(const char *what)
{
	fprintf(stderr, "open_by_handle: %s: %s\n", what, strerror(errno));
	exit(1);
}

static void
usage(void)
{
	fprintf(stderr, "usage: open_by_handle -e PATH\n"
	    "       open_by_handle -o MOUNTPOINT\n");
	exit(2);
}

#ifdef __FreeBSD__

static void
encode(const char *path)
{
	fhandle_t fh;

	if (getfh(path, &fh) != 0)
		die("getfh");
	if (fwrite(&fh, sizeof (fh), 1, stdout) != 1)
		die("write handle");
}

static int
open_handle(const char *mountpoint)
{
	fhandle_t fh;
	int fd;

	(void) mountpoint;
	if (fread(&fh, sizeof (fh), 1, stdin) != 1)
		die("read handle");
	fd = fhopen(&fh, O_RDONLY);
	if (fd < 0)
		die("fhopen");
	return (fd);
}

static void
print_path(int fd)
{
	char cwd[PATH_MAX];

	if (fchdir(fd) != 0)
		die("fchdir");
	if (getcwd(cwd, sizeof (cwd)) == NULL)
		die("getcwd");
	printf("%s\n", cwd);
}

#else /* Linux */

#define	MAX_HANDLE_BYTES	128

static void
encode(const char *path)
{
	struct file_handle *fh;
	int mount_id;

	fh = calloc(1, sizeof (*fh) + MAX_HANDLE_BYTES);
	if (fh == NULL)
		die("calloc");
	fh->handle_bytes = MAX_HANDLE_BYTES;
	if (name_to_handle_at(AT_FDCWD, path, fh, &mount_id, 0) != 0)
		die("name_to_handle_at");
	if (fwrite(fh, sizeof (*fh) + fh->handle_bytes, 1, stdout) != 1)
		die("write handle");
	free(fh);
}

static int
open_handle(const char *mountpoint)
{
	struct file_handle *fh;
	int mfd, fd;

	fh = calloc(1, sizeof (*fh) + MAX_HANDLE_BYTES);
	if (fh == NULL)
		die("calloc");
	if (fread(fh, sizeof (*fh), 1, stdin) != 1 ||
	    fh->handle_bytes > MAX_HANDLE_BYTES ||
	    fread(fh->f_handle, fh->handle_bytes, 1, stdin) != 1)
		die("read handle");

	mfd = open(mountpoint, O_RDONLY | O_DIRECTORY);
	if (mfd < 0)
		die("open mountpoint");
	fd = open_by_handle_at(mfd, fh, O_RDONLY);
	if (fd < 0)
		die("open_by_handle_at");
	(void) close(mfd);
	free(fh);
	return (fd);
}

static void
print_path(int fd)
{
	char linkpath[64], resolved[PATH_MAX];
	ssize_t n;

	(void) snprintf(linkpath, sizeof (linkpath), "/proc/self/fd/%d", fd);
	n = readlink(linkpath, resolved, sizeof (resolved) - 1);
	if (n < 0)
		die("readlink");
	resolved[n] = '\0';
	printf("%s\n", resolved);
}

#endif

int
main(int argc, char *argv[])
{
	int fd;

	if (argc != 3 || argv[1][0] != '-' || argv[1][2] != '\0')
		usage();
	switch (argv[1][1]) {
	case 'e':
		encode(argv[2]);
		break;
	case 'o':
		fd = open_handle(argv[2]);
		print_path(fd);
		(void) close(fd);
		break;
	default:
		usage();
	}
	return (0);
}
