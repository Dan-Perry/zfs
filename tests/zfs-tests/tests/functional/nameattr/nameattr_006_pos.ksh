#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#

#
# Copyright (c) 2026, Amazon.com, Inc. or its affiliates.
#

. $STF_SUITE/tests/functional/nameattr/nameattr.kshlib

#
# DESCRIPTION:
# The ZPL_NAME reader returns the right name, a stale ZPL_NAME is never
# returned, and the namelookups and namelookup_misses dataset kstats account
# for which path was taken.
#
# The reader only runs when the kernel has to rebuild a directory's path
# without a cached name for it: Linux get_name() while reconnecting a file
# handle, FreeBSD VOP_VPTOCNP while resolving a vnode's path.  Each check
# opens a directory through a file handle with a cold name cache and
# compares the path the kernel rebuilt with the real one.  The kstat deltas
# across the open tell whether the cached name was used or the directory
# was scanned.
#
# STRATEGY:
# 1. Directory created with nameattr=on (fast path hit, no miss).
# 2. Directory created with nameattr=off (every level misses).
# 3. Directory renamed while nameattr=off, so its cached name is
#    stale; the slow path must win and report the new name, and exactly
#    one level misses.  Same again for a stale ancestor, where the
#    fallback has to work mid-walk while the leaf's own cached name is
#    still good.
# 4. Directories with 255-byte names (the longest that is cached), nested
#    several levels deep so several lookups are needed for one path, all
#    of them hits.
#

verify_runnable "both"

TESTFS_DS=$TESTPOOL/$TESTFS
WORKDIR=$TESTDIR/workdir

function cleanup
{
	log_must rm -rf $WORKDIR
	log_must zfs inherit nameattr $TESTFS_DS
}

#
# Open $path through a file handle with a cold name cache and check the
# kernel rebuilds exactly $path.  Between encoding the handle and opening
# it the name cache is evicted: on Linux by dropping the dentry and inode
# caches, on FreeBSD by remounting the dataset, since its namecache cannot
# be dropped from userland.  The walk goes from $path up to $TESTDIR,
# calling the reader once per level, so namelookups must grow by the number
# of levels and namelookup_misses by $misses.
#
function verify_reconnect # path misses
{
	typeset path=$1 misses=$2 got rel
	typeset fh=$TEST_BASE_DIR/nameattr.handle.$$
	typeset -i levels calls0 miss0 calls1 miss1

	rel=${path#$TESTDIR/}
	levels=$(echo "$rel" | tr -cd / | wc -c)
	levels=$((levels + 1))

	log_must eval "open_by_handle -e $path > $fh"
	if is_linux; then
		log_must eval "echo 2 > /proc/sys/vm/drop_caches"
	else
		# The remount recreates the dataset kstats, so the baseline
		# below is read after it.
		log_must zfs unmount $TESTFS_DS
		log_must zfs mount $TESTFS_DS
	fi
	calls0=$(kstat_dataset $TESTFS_DS namelookups)
	miss0=$(kstat_dataset $TESTFS_DS namelookup_misses)

	got=$(open_by_handle -o $TESTDIR < $fh) ||
	    log_fail "open_by_handle failed for $path"
	rm -f $fh
	[[ "$got" == "$path" ]] ||
	    log_fail "rebuilt '$path' as '$got'"

	calls1=$(kstat_dataset $TESTFS_DS namelookups)
	miss1=$(kstat_dataset $TESTFS_DS namelookup_misses)
	[[ $((calls1 - calls0)) -eq $levels ]] ||
	    log_fail "$path: namelookups grew by $((calls1 - calls0))," \
	    "expected $levels"
	[[ $((miss1 - miss0)) -eq $misses ]] ||
	    log_fail "$path: namelookup_misses grew by $((miss1 - miss0))," \
	    "expected $misses"
	log_note "rebuilt $path ($levels calls, $misses misses)"
}

log_assert "ZPL_NAME reader is correct, never stale, and counted"
log_onexit cleanup

# Every reconnect walks through $WORKDIR, so give it a cached name too.
log_must zfs set nameattr=on $TESTFS_DS
log_must mkdir $WORKDIR

# 1. Fast path.
log_must mkdir -p $WORKDIR/on/level2/level3
verify_name $TESTFS_DS $WORKDIR/on/level2/level3 level3
verify_reconnect $WORKDIR/on/level2/level3 0

# 2. Slow path only.
log_must zfs set nameattr=off $TESTFS_DS
log_must mkdir -p $WORKDIR/off/level2
verify_no_name $TESTFS_DS $WORKDIR/off/level2
verify_reconnect $WORKDIR/off/level2 2

# 3. Stale cached name must lose to the ZAP.
log_must zfs set nameattr=on $TESTFS_DS
log_must mkdir $WORKDIR/stale.old
log_must zfs set nameattr=off $TESTFS_DS
log_must mv $WORKDIR/stale.old $WORKDIR/stale.new
verify_name $TESTFS_DS $WORKDIR/stale.new stale.old
verify_reconnect $WORKDIR/stale.new 1

# A new directory reusing the stale name must not be confused with it.
log_must mkdir $WORKDIR/stale.old
verify_reconnect $WORKDIR/stale.new 1
verify_reconnect $WORKDIR/stale.old 1

# A stale name on an ancestor: rebuilding the leaf's path needs the reader
# for every level, so the fallback has to work mid-walk.  Rename an intermediate
# directory with the property off, then reconnect a leaf two levels below
# whose own name is still cached and correct.
log_must zfs set nameattr=on $TESTFS_DS
log_must mkdir -p $WORKDIR/anc.old/mid/leaf
log_must zfs set nameattr=off $TESTFS_DS
log_must mv $WORKDIR/anc.old $WORKDIR/anc.new
verify_name $TESTFS_DS $WORKDIR/anc.new anc.old
verify_name $TESTFS_DS $WORKDIR/anc.new/mid/leaf leaf
verify_reconnect $WORKDIR/anc.new/mid/leaf 1
log_must mkdir $WORKDIR/anc.old
verify_reconnect $WORKDIR/anc.new/mid/leaf 1

# 4. Longest cached name, nested so one path needs several lookups.
log_must zfs set nameattr=on $TESTFS_DS
NAME_255=$(printf 'a%.0s' {1..255})
NAME_254=$(printf 'b%.0s' {1..254})
log_must mkdir -p $WORKDIR/$NAME_255/$NAME_254/$NAME_255
verify_name $TESTFS_DS $WORKDIR/$NAME_255 $NAME_255
verify_name $TESTFS_DS $WORKDIR/$NAME_255/$NAME_254 $NAME_254
verify_reconnect $WORKDIR/$NAME_255/$NAME_254/$NAME_255 0

log_pass "ZPL_NAME reader is correct, never stale, and counted"
