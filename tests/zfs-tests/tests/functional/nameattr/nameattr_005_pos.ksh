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
# ZPL_NAME is a variable-length SA attribute and must coexist with
# the other variable-length attributes (SA xattrs) in every bonus
# buffer layout: fitting in the bonus, pushed to a spill block, and being
# added or resized on an object that is already spilled.
#
# STRATEGY:
# 1. dnodesize=legacy (512-byte dnode, 320-byte bonus): a 255-byte name
#    plus an SA xattr that cannot fit must spill; the attribute is still
#    correct, and stays correct through a rename that changes its length.
# 2. Add the attribute to an object that was created without it (property
#    off) and is already spilled; the link path has to grow the SA layout
#    and take the spill hold.
# 3. dnodesize=auto: the same objects fit without spilling.
# 4. Every variant on a case-insensitive dataset stores the name exactly as
#    it appears in the directory ZAP.
#

verify_runnable "both"

SPILL_DS=$TESTPOOL/spill
AUTO_DS=$TESTPOOL/auto
CI_DS=$TESTPOOL/ci

function cleanup
{
	for ds in $SPILL_DS $AUTO_DS $CI_DS; do
		datasetexists $ds && destroy_dataset $ds
	done
}

function has_spill # dataset path
{
	typeset ds=$1 path=$2 obj
	obj=$(get_objnum "$path")
	sync_pool $TESTPOOL
	zdb -dddd "$ds" "$obj" | grep -q SPILL_BLKPTR
}

log_assert "ZPL_NAME coexists with SA xattrs in all bonus layouts"
log_onexit cleanup

NAME_255=$(printf 'a%.0s' {1..255})
NAME_200=$(printf 'b%.0s' {1..200})
XATTR_BIG=$(printf 'x%.0s' {1..1500})

# 1. Legacy dnodes: forced spill.
log_must zfs create -o dnodesize=legacy -o xattr=sa -o nameattr=on \
    $SPILL_DS
mnt=$(get_prop mountpoint $SPILL_DS)

log_must touch $mnt/$NAME_255
log_must set_xattr big $XATTR_BIG $mnt/$NAME_255
log_must has_spill $SPILL_DS $mnt/$NAME_255
verify_name $SPILL_DS $mnt/$NAME_255 $NAME_255
log_must eval "[[ \$(get_xattr big $mnt/$NAME_255) == $XATTR_BIG ]]"

# Shrink and grow the attribute on a spilled object.
log_must mv $mnt/$NAME_255 $mnt/short
verify_name $SPILL_DS $mnt/short short
log_must mv $mnt/short $mnt/$NAME_200
verify_name $SPILL_DS $mnt/$NAME_200 $NAME_200
log_must eval "[[ \$(get_xattr big $mnt/$NAME_200) == $XATTR_BIG ]]"

# 2. First-time add on an already spilled object via link and rename.
log_must zfs set nameattr=off $SPILL_DS
log_must touch $mnt/late
log_must set_xattr big $XATTR_BIG $mnt/late
log_must has_spill $SPILL_DS $mnt/late
verify_no_name $SPILL_DS $mnt/late
log_must zfs set nameattr=on $SPILL_DS
log_must ln $mnt/late $mnt/late.$NAME_200
verify_name $SPILL_DS $mnt/late late.$NAME_200
log_must mv $mnt/late $mnt/late2
verify_name $SPILL_DS $mnt/late2 late2
log_must eval "[[ \$(get_xattr big $mnt/late2) == $XATTR_BIG ]]"

# 3. Large dnodes: no spill for the same objects.
log_must zfs create -o dnodesize=auto -o xattr=sa -o nameattr=on $AUTO_DS
amnt=$(get_prop mountpoint $AUTO_DS)
log_must touch $amnt/$NAME_255
log_must set_xattr small small $amnt/$NAME_255
log_mustnot has_spill $AUTO_DS $amnt/$NAME_255
verify_name $AUTO_DS $amnt/$NAME_255 $NAME_255

# 4. Case-insensitive: the stored ZAP key is what gets cached, and the
# cached name does not interfere with case-folded lookups.
log_must zfs create -o casesensitivity=insensitive -o nameattr=on $CI_DS
cmnt=$(get_prop mountpoint $CI_DS)
log_must touch $cmnt/MixedCase
verify_name $CI_DS $cmnt/MixedCase MixedCase
log_must test -f $cmnt/MIXEDCASE
log_must mv $cmnt/mixedcase $cmnt/Other
verify_name $CI_DS $cmnt/Other Other
log_must test -f $cmnt/OTHER

log_pass "ZPL_NAME coexists with SA xattrs in all bonus layouts"
