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
# ZFS never looks up the name of these objects, so they do not get a
# ZPL_NAME even with nameattr=on.
#
# STRATEGY:
# 1. Names longer than 255 bytes (longname=on) are not cached.  A rename
#    to a long name leaves the old name in place, and a rename back to a
#    short name replaces it.  Linux only: the FreeBSD VFS rejects names
#    over NAME_MAX before ZFS sees them.
# 2. Directory-based extended attributes (xattr=dir) live in a hidden
#    xattr directory.  Neither the xattr directory nor the entries inside
#    it carry ZPL_NAME; the owning file still does.
#

verify_runnable "both"

TESTFS_DS=$TESTPOOL/$TESTFS
WORKDIR=$TESTDIR/workdir

function cleanup
{
	log_must rm -rf $WORKDIR
	log_must zfs inherit nameattr $TESTFS_DS
	log_must zfs inherit longname $TESTFS_DS
	log_must zfs inherit xattr $TESTFS_DS
}

log_assert "longname entries and xattr directory contents are never cached"
log_onexit cleanup

if [[ $(get_pool_prop feature@longname $TESTPOOL) == disabled ]]; then
	log_unsupported "longname feature is not enabled on $TESTPOOL"
fi

log_must zfs set nameattr=on $TESTFS_DS
log_must mkdir $WORKDIR

# 1. Long names.
if is_linux; then
	log_must zfs set longname=on $TESTFS_DS
	NAME_255=$(printf 'a%.0s' {1..255})
	NAME_256=${NAME_255}b
	NAME_1023=$(printf 'c%.0s' {1..1023})

	log_must touch $WORKDIR/$NAME_256
	verify_no_name $TESTFS_DS $WORKDIR/$NAME_256
	log_must mkdir $WORKDIR/$NAME_1023
	verify_no_name $TESTFS_DS $WORKDIR/$NAME_1023

	# A 1023 byte name is the longest longname allows.  Use a distinct
	# one.  A rename to a long name writes nothing and removes nothing,
	# so the old name stays behind as a stale value until a rename to a
	# short name.
	NAME_1023B=d${NAME_1023#c}

	log_must touch $WORKDIR/short
	log_must mv $WORKDIR/short $WORKDIR/$NAME_1023B
	verify_name $TESTFS_DS $WORKDIR/$NAME_1023B short
	log_must mv $WORKDIR/$NAME_1023B $WORKDIR/$NAME_255
	verify_name $TESTFS_DS $WORKDIR/$NAME_255 $NAME_255
fi

# 2. Directory-based xattrs.
log_must zfs set xattr=dir $TESTFS_DS
log_must touch $WORKDIR/xfile
log_must set_xattr foo bar $WORKDIR/xfile
verify_name $TESTFS_DS $WORKDIR/xfile xfile

# The owning znode names its hidden xattr directory; that directory's
# ZAP names the xattr entry object.  Dump both.
sync_pool $TESTPOOL
xobj=$(get_objnum $WORKDIR/xfile)
xdir=$(zdb -dddd $TESTFS_DS $xobj | awk -F'\t' '$2 == "xattr" {print $3}')
[[ -n "$xdir" ]] || log_fail "no xattr directory recorded for xfile"
# The entry is "user.foo" with zfs_xattr_compat=0 (the Linux default) and
# "foo" with zfs_xattr_compat=1 (the FreeBSD default).
xent=$(zdb -dddd $TESTFS_DS $xdir |
    awk '($1 == "user.foo" || $1 == "foo") && $2 == "=" {print $3}')
[[ -n "$xent" ]] || log_fail "no foo entry found in xattr dir $xdir"

[[ -z $(zdb_obj_field $TESTFS_DS $xdir name) ]] ||
    log_fail "xattr directory $xdir has a name attribute"
[[ -z $(zdb_obj_field $TESTFS_DS $xent name) ]] ||
    log_fail "xattr entry $xent has a name attribute"
log_must eval "[[ \$(get_xattr foo $WORKDIR/xfile) == bar ]]"

log_pass "longname entries and xattr directory contents are never cached"
