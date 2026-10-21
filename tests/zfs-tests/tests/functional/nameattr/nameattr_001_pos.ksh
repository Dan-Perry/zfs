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
# The nameattr property gates whether ZPL_NAME is written.
#
# STRATEGY:
# 1. The property defaults to off, accepts only on|off, and is inherited.
# 2. With nameattr=off, newly created objects carry no ZPL_NAME.
# 3. With nameattr=on, files, directories, symlinks and FIFOs all carry
#    ZPL_NAME equal to their directory entry name.
# 4. Objects created while the property was off are left alone when it is
#    turned on; coverage only grows as objects are created/linked/renamed.
#

verify_runnable "both"

TESTFS_DS=$TESTPOOL/$TESTFS
CHILD_DS=$TESTFS_DS/child
WORKDIR=$TESTDIR/workdir

function cleanup
{
	datasetexists $CHILD_DS && destroy_dataset $CHILD_DS
	log_must rm -rf $WORKDIR
	log_must zfs inherit nameattr $TESTFS_DS
}

log_assert "nameattr property gates ZPL_NAME on create"
log_onexit cleanup

# 1. Property semantics.
log_must eval "[[ \$(get_prop nameattr $TESTFS_DS) == off ]]"
log_mustnot zfs set nameattr=sa $TESTFS_DS
log_mustnot zfs set nameattr=1 $TESTFS_DS
log_must zfs set nameattr=on $TESTFS_DS
log_must eval "[[ \$(get_prop nameattr $TESTFS_DS) == on ]]"
log_must zfs create $CHILD_DS
log_must eval "[[ \$(get_prop nameattr $CHILD_DS) == on ]]"
log_must eval \
    "[[ \$(zfs get -H -o source nameattr $CHILD_DS) == inherited* ]]"
log_must zfs set nameattr=off $TESTFS_DS
log_must eval "[[ \$(get_prop nameattr $CHILD_DS) == off ]]"

log_must mkdir $WORKDIR

# 2. Nothing is written while off.
log_must touch $WORKDIR/off.file
log_must mkdir $WORKDIR/off.dir
verify_no_name $TESTFS_DS $WORKDIR/off.file
verify_no_name $TESTFS_DS $WORKDIR/off.dir

# 3. Every create path writes the entry name while on.
log_must zfs set nameattr=on $TESTFS_DS
log_must touch $WORKDIR/on.file
log_must mkdir $WORKDIR/on.dir
log_must ln -s on.file $WORKDIR/on.symlink
log_must mkfifo $WORKDIR/on.fifo
verify_name $TESTFS_DS $WORKDIR/on.file on.file
verify_name $TESTFS_DS $WORKDIR/on.dir on.dir
verify_name $TESTFS_DS $WORKDIR/on.symlink on.symlink
verify_name $TESTFS_DS $WORKDIR/on.fifo on.fifo
verify_zdb_path $TESTFS_DS $WORKDIR/on.file

# A 255-byte name is the longest that is cached.
NAME_255=$(printf 'a%.0s' {1..255})
log_must touch $WORKDIR/$NAME_255
verify_name $TESTFS_DS $WORKDIR/$NAME_255 $NAME_255

# 4. Pre-existing objects are not retro-fitted.
verify_no_name $TESTFS_DS $WORKDIR/off.file
verify_no_name $TESTFS_DS $WORKDIR/off.dir

log_pass "nameattr property gates ZPL_NAME on create"
