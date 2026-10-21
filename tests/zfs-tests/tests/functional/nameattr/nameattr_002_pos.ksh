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
# ZPL_NAME follows the same lifecycle as ZPL_PARENT: it is rewritten
# by link and rename, and left alone by unlink.
#
# STRATEGY:
# 1. Rename within a directory, across directories, and over an existing
#    target; the attribute always reflects the new entry name.
# 2. A hard link rewrites the attribute to the new link's name
#    (last-writer-wins), including a link in another directory.
# 3. Removing the link that the attribute names leaves it stale.  The file
#    is still reachable by its remaining name and that name resolves to
#    the same object, so the ZAP is the source of truth.
#

verify_runnable "both"

TESTFS_DS=$TESTPOOL/$TESTFS
WORKDIR=$TESTDIR/workdir
OTHERDIR=$TESTDIR/otherdir

function cleanup
{
	log_must rm -rf $WORKDIR $OTHERDIR
	log_must zfs inherit nameattr $TESTFS_DS
}

log_assert "ZPL_NAME is rewritten by link/rename, untouched by unlink"
log_onexit cleanup

log_must zfs set nameattr=on $TESTFS_DS
log_must mkdir $WORKDIR $OTHERDIR

# 1. Renames.
log_must touch $WORKDIR/a
verify_name $TESTFS_DS $WORKDIR/a a

log_must mv $WORKDIR/a $WORKDIR/b
verify_name $TESTFS_DS $WORKDIR/b b

log_must mv $WORKDIR/b $OTHERDIR/c
verify_name $TESTFS_DS $OTHERDIR/c c
verify_zdb_path $TESTFS_DS $OTHERDIR/c

log_must touch $OTHERDIR/target
log_must mv $OTHERDIR/c $OTHERDIR/target
verify_name $TESTFS_DS $OTHERDIR/target target

log_must mkdir $WORKDIR/d1
log_must mv $WORKDIR/d1 $OTHERDIR/d2
verify_name $TESTFS_DS $OTHERDIR/d2 d2

# 2. Hard links are last-writer-wins.
log_must touch $WORKDIR/orig
log_must ln $WORKDIR/orig $WORKDIR/link1
verify_name $TESTFS_DS $WORKDIR/orig link1
log_must ln $WORKDIR/orig $OTHERDIR/link2
verify_name $TESTFS_DS $WORKDIR/orig link2

# 3. Unlink leaves the attribute stale but the ZAP is authoritative.  The
# only remaining entry still resolves to the same object.
obj=$(get_objnum $WORKDIR/orig)
log_must rm $OTHERDIR/link2
verify_name $TESTFS_DS $WORKDIR/orig link2
log_must rm $WORKDIR/link1
verify_name $TESTFS_DS $WORKDIR/orig link2
log_must test -f $WORKDIR/orig
log_must eval "[[ \$(get_objnum $WORKDIR/orig) == $obj ]]"

# A later rename heals the stale value.
log_must mv $WORKDIR/orig $WORKDIR/healed
verify_name $TESTFS_DS $WORKDIR/healed healed

log_pass "ZPL_NAME is rewritten by link/rename, untouched by unlink"
