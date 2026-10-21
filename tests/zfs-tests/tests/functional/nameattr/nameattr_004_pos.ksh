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
# ZPL_NAME is plain on-disk SA data with no feature flag.  It must
# survive, go stale, and heal across property toggles, send/receive, and
# ZPL version upgrades without ever affecting the file's reachability.
#
# STRATEGY:
# 1. Toggle: create with on, rename with off (attribute stays stale, ZAP
#    path is correct), rename again with on (attribute heals).
# 2. send/receive: the attribute travels with the stream and is preserved
#    on a receiver that has nameattr=off; the receiver leaves it alone
#    on rename and heals it once nameattr is turned on there.  An
#    incremental stream carries a rename's rewritten attribute as well.
# 3. Legacy znodes: a version=4 dataset (pre-SA znode_phys objects) never
#    gets the attribute and never fails.  After `zfs upgrade`, an object
#    converts to SA format on its first SA update with the ACL cached, and
#    link/rename add the attribute once it is in SA format.
#

verify_runnable "both"

TESTFS_DS=$TESTPOOL/$TESTFS
RECV_DS=$TESTPOOL/recv
LEGACY_DS=$TESTPOOL/legacy
WORKDIR=$TESTDIR/workdir

function cleanup
{
	datasetexists $RECV_DS && destroy_dataset $RECV_DS -r
	datasetexists $LEGACY_DS && destroy_dataset $LEGACY_DS -r
	datasetexists $TESTFS_DS@snap2 && destroy_dataset $TESTFS_DS@snap2
	datasetexists $TESTFS_DS@snap && destroy_dataset $TESTFS_DS@snap
	log_must rm -rf $WORKDIR
	log_must zfs inherit nameattr $TESTFS_DS
}

log_assert "ZPL_NAME survives property toggles, send/recv and upgrade"
log_onexit cleanup

log_must mkdir $WORKDIR

# 1. Property toggle.
log_must zfs set nameattr=on $TESTFS_DS
log_must touch $WORKDIR/t1
verify_name $TESTFS_DS $WORKDIR/t1 t1

log_must zfs set nameattr=off $TESTFS_DS
log_must mv $WORKDIR/t1 $WORKDIR/t2
verify_name $TESTFS_DS $WORKDIR/t2 t1
verify_zdb_path $TESTFS_DS $WORKDIR/t2
log_must test -f $WORKDIR/t2

log_must zfs set nameattr=on $TESTFS_DS
log_must mv $WORKDIR/t2 $WORKDIR/t3
verify_name $TESTFS_DS $WORKDIR/t3 t3

# 2. send/receive.
log_must touch $WORKDIR/sent
verify_name $TESTFS_DS $WORKDIR/sent sent
log_must zfs snapshot $TESTFS_DS@snap
log_must eval "zfs send $TESTFS_DS@snap | zfs receive $RECV_DS"
recvmnt=$(get_prop mountpoint $RECV_DS)

# Property is not in a non -p stream, so the receiver is at the default.
log_must eval "[[ \$(get_prop nameattr $RECV_DS) == off ]]"
verify_name $RECV_DS $recvmnt/workdir/sent sent
verify_name $RECV_DS $recvmnt/workdir/t3 t3

log_must mv $recvmnt/workdir/sent $recvmnt/workdir/moved
verify_name $RECV_DS $recvmnt/workdir/moved sent
verify_zdb_path $RECV_DS $recvmnt/workdir/moved

log_must zfs set nameattr=on $RECV_DS
log_must mv $recvmnt/workdir/moved $recvmnt/workdir/healed
verify_name $RECV_DS $recvmnt/workdir/healed healed

# An incremental stream carries the rewritten bonus buffer: rename on the
# sender between two snapshots and check the receiver sees the new name.
log_must mv $WORKDIR/sent $WORKDIR/sent2
verify_name $TESTFS_DS $WORKDIR/sent2 sent2
log_must zfs snapshot $TESTFS_DS@snap2
log_must zfs rollback $RECV_DS@snap
log_must eval "zfs send -i $TESTFS_DS@snap $TESTFS_DS@snap2 | \
    zfs receive $RECV_DS"
verify_name $RECV_DS $recvmnt/workdir/sent2 sent2
verify_zdb_path $RECV_DS $recvmnt/workdir/sent2

# 3. Legacy (pre-SA) znodes.
log_must zfs create -o version=4 -o nameattr=on $LEGACY_DS
legmnt=$(get_prop mountpoint $LEGACY_DS)
log_must touch $legmnt/old
log_must mkdir $legmnt/olddir
log_must touch $legmnt/linkme
log_must mv $legmnt/old $legmnt/renamed
log_must ln $legmnt/linkme $legmnt/linked
verify_no_name $LEGACY_DS $legmnt/renamed
verify_no_name $LEGACY_DS $legmnt/olddir
verify_no_name $LEGACY_DS $legmnt/linkme
verify_zdb_path $LEGACY_DS $legmnt/renamed

log_must zfs upgrade $LEGACY_DS
log_must eval "[[ \$(get_prop version $LEGACY_DS) == 5 ]]"
# zfs_sa_upgrade() only converts an object whose ACL is cached.  Whether a
# rename has cached it differs between platforms, so the first rename may
# or may not convert the object and add the name.  Do not check that.
# chmod reads the ACL before its SA update, so after it the object is in
# SA format either way and the next rename must add the name.
log_must mv $legmnt/renamed $legmnt/upgraded
verify_zdb_path $LEGACY_DS $legmnt/upgraded
log_must chmod 600 $legmnt/upgraded
log_must mv $legmnt/upgraded $legmnt/upgraded2
verify_name $LEGACY_DS $legmnt/upgraded2 upgraded2
# An untouched legacy object stays legacy and attribute-free.
verify_no_name $LEGACY_DS $legmnt/olddir
log_must touch $legmnt/new
verify_name $LEGACY_DS $legmnt/new new

log_pass "ZPL_NAME survives property toggles, send/recv and upgrade"
