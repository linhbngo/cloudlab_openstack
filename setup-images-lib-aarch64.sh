#!/bin/sh

fixup_mounted_image_aarch64() {
    MNT="$1"
    _imgfile="$2"

    _dir=`dirname $_imgfile`
    retvalcmd=/bin/true

    # Find the kernel and initrd, and copy them to the dir holding
    # $_imgfile .
    if [ -f $MNT/boot/vmlinuz ]; then
	cp -p $MNT/boot/vmlinuz $_dir/$_imgfile-vmlinuz
    else
	# Try to find the highest-versioned vmlinuz.  Totally error-prone.
	_vmlinuz=`find $MNT/boot -name vmlinuz\* | sort | tail -1`
	if [ -n "$_vmlinuz" ]; then
	    cp -p $_vmlinuz $_dir/$_imgfile-vmlinuz
	else
	    echo "*** ERROR: could not find vmlinuz* in $MNT/boot; image will most likely fail to boot!"
	    ls -l $MNT/boot
	    retvalcmd=/bin/false
	fi
    fi
    if [ -f $MNT/boot/initrd.img ]; then
	cp -p $MNT/boot/initrd.img $_dir/$_imgfile-initrd.img
    else
	# Try to find the highest-versioned initrd.img.  Totally error-prone.
	_initrd=`find $MNT/boot -name initrd\*.img\* | sort | tail -1`
	if [ -n "$_initrd" ]; then
	    cp -p $_initrd $_dir/$_imgfile-initrd.img
	else
	    echo "*** ERROR: could not find initrd*.img* in $MNT/boot; image will most likely fail to boot!"
	    ls -l $MNT/boot
	    retvalcmd=/bin/false
	fi
    fi

    $retvalcmd
}

fixup_image() {
    _imgfile="$1"
    MNT=`mount_image_etc "$_imgfile"`
    if [ -z "$MNT" ]; then
	echo "ERROR: could not mount $_imgfile !"
	/bin/false
	return
    fi

    fixup_mounted_image "$MNT" "$_imgfile"
    fixup_mounted_image_aarch64 "$MNT" "$_imgfile"

    umount_image "$MNT"
}

   # 21  glance image-list
   # 23  glance image-list
   # 24  glance image-create --name xenial-server --progress --file xenial-server-cloudimg-arm64-disk1.img --disk-format ami --container-format ami
   # 25  glance image-update --property kernel_args=console=ttyAMA0 e12c37fa-3dbd-45ad-8050-2b6c7b1818ad
   # 26  glance image-create --name xenial-server-vmlinuz --progres --file xenial-server-cloudimg-arm64-disk1-vmlinuz --disk-format aki --container-format aki
   # 27  glance image-create --name xenial-server-initrd --progres --file xenial-server-cloudimg-arm64-disk1-initrd --disk-format ari --container-format ari
   # 28  glance image-create --name xenial-server-initrd --progres --file xenial-server-cloudimg-arm64-disk1-initrd.img --disk-format ari --container-format ari
   # 29  glance image-update --property kernel_id=daac78a9-d0d0-4e0d-a54f-a4a931659bcf e12c37fa-3dbd-45ad-8050-2b6c7b1818ad
   # 30  glance image-update --property ramdisk_id=e8de69f0-87cf-4061-9485-a79fa9dd7d11 e12c37fa-3dbd-45ad-8050-2b6c7b1818ad
   # 31  glance image-update --property hw_video_model=vga e12c37fa-3dbd-45ad-8050-2b6c7b1818ad
   # 32  glance image-update --property root_device_name=/dev/vda1 e12c37fa-3dbd-45ad-8050-2b6c7b1818ad

#
# Custom versions of these because all aarch64 images get uploaded as
# AMI/AKI/ARI images.
#
sched_image() {
    _imgfile="$1"
    _imgname="$2"

    if [ -z "$_imgname" ]; then
	_imgname="$_imgfile"
    fi
    
    touch $IMAGEUPLOADCMDFILE
    chmod 755 $IMAGEUPLOADCMDFILE

    GLANCEOPTS=""
    if [ "$OSCODENAME" = "juno" -o "$OSCODENAME" = "kilo" ]; then
	GLANCEOPTS="--is-public True"
    fi

    cat <<EOF >> $IMAGEUPLOADCMDFILE
_imgfile='$_imgfile'
_imgname='$_imgname'
GLANCEOPTS='$GLANCEOPTS'
EOF
    cat <<'EOF' >> $IMAGEUPLOADCMDFILE
glance image-create --name "${_imgname}" ${GLANCEOPTS} --disk-format ami --container-format ami --progress --file "$_imgfile"
if [ ! $? -eq 0 ]; then
	echo "*** ERROR: could not upload $_imgfile as $_imgname !"
	/bin/false
	return
fi
IMAGEID=`glance image-list | awk "/ ${_imgname} / { print \\$2 }"`
glance image-update --property kernel_args=console=ttyAMA0 $IMAGEID
glance image-update --property root_device_name=/dev/vda1 $IMAGEID
glance image-create --name ${_imgname}-vmlinuz --progress --file ${_imgfile}-vmlinuz --disk-format aki --container-format aki
KERNELID=`glance image-list | awk "/ ${_imgname}-vmlinuz / { print \\$2 }"`
glance image-update --property kernel_id=$KERNELID $IMAGEID
glance image-create --name ${_imgname}-initrd --progress --file ${_imgfile}-initrd.img --disk-format ari --container-format ari
RAMDISKID=`glance image-list | awk "/ ${_imgname}-initrd / { print \\$2 }"`
glance image-update --property ramdisk_id=$RAMDISKID $IMAGEID
EOF
    if [ $OSVERSION -lt $OSPIKE ]; then
	cat <<'EOF' >> $IMAGEUPLOADCMDFILE
glance image-update --property hw_video_model=vga $IMAGEID
EOF
    fi
}

upload_image() {
    _imgfile="$1"
    _imgname="$2"

    if [ -z "$_imgname" ]; then
	_imgname="$_imgfile"
    fi
    
    GLANCEOPTS=""
    if [ "$OSCODENAME" = "juno" -o "$OSCODENAME" = "kilo" ]; then
	GLANCEOPTS="--is-public True"
    fi

    glance image-create --name "${_imgname}" ${GLANCEOPTS} --disk-format ami --container-format ami --progress --file "$_imgfile"
    if [ ! $? -eq 0 ]; then
	echo "*** ERROR: could not upload $_imgfile as $_imgname !"
	/bin/false
	return
    fi
    IMAGEID=`glance image-list | awk "/ ${_imgname} / { print \\$2 }"`
    glance image-update --property kernel_args=console=ttyAMA0 $IMAGEID
    if [ $OSVERSION -lt $OSPIKE ]; then
	glance image-update --property hw_video_model=vga $IMAGEID
    fi
    glance image-update --property root_device_name=/dev/vda1 $IMAGEID
    glance image-create --name ${_imgname}-vmlinuz --progress --file ${_imgfile}-vmlinuz --disk-format aki --container-format aki
    KERNELID=`glance image-list | awk "/ ${_imgname}-vmlinuz / { print \\$2 }"`
    glance image-update --property kernel_id=$KERNELID $IMAGEID
    glance image-create --name ${_imgname}-initrd --progress --file ${_imgfile}-initrd.img --disk-format ari --container-format ari
    RAMDISKID=`glance image-list | awk "/ ${_imgname}-initrd / { print \\$2 }"`
    glance image-update --property ramdisk_id=$RAMDISKID $IMAGEID
    
}
