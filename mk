#!/bin/sh

set -e

tarxf() {
	cd $SOURCES
	[ -f $2$3 ] || curl -L -O $1$2$3 -C -
	rm -rf ${4:-$2}
	tar -xf $2$3
	cd ${4:-$2}
}

tarxfalt() {
	cd $SOURCES
	[ -f $2$3 ] || curl -L -O $1$2$3 -C -
	rm -rf ${4:-$2}
	tar -xf $2$3
}

clean_libtool() {
	find $ROOTFS -type f | xargs file 2>/dev/null | grep "libtool library file" | cut -f 1 -d : | xargs rm -rf 2>/dev/null || true
}

check_for_root() {
	:
}

setup_architecture() {
	case $BARCH in
		x86_64)
			export XHOST="$(echo ${MACHTYPE} | sed -e 's/-[^-]*/-cross/')"
			export XTARGET="x86_64-linux-musl"
			export XKARCH="x86_64"
			export GCCOPTS="--with-arch=x86-64 --with-tune=generic"
			;;
		aarch64)
			export XHOST="$(echo ${MACHTYPE} | sed -e 's/-[^-]*/-cross/')"
			export XTARGET="aarch64-linux-musl"
			export XKARCH="arm64"
			export GCCOPTS="--with-arch=armv8-a --with-abi=lp64"
			;;
		armhf)
			export XHOST="$(echo ${MACHTYPE} | sed -e 's/-[^-]*/-cross/')"
			export XTARGET="arm-linux-musleabihf"
			export XKARCH="arm"
			export GCCOPTS="--with-arch=armv7-a --with-float=hard --with-fpu=vfpv3"
			;;
		*)
			echo "BARCH variable isn't set!"
			exit 1
	esac
}

setup_environment() {
	export CWD="$(pwd)"
	export KEEP="$CWD/KEEP"
	export BUILD="$CWD/build"
	export SOURCES="$BUILD/sources"
	export ROOTFS="$BUILD/rootfs"
	export TOOLS="$BUILD/tools"
	export IMAGE="$BUILD/image"

	rm -rf $BUILD
	mkdir -p $BUILD $SOURCES $ROOTFS $TOOLS $IMAGE

	export LC_ALL="POSIX"
	export PATH="$TOOLS/bin:$PATH"
	export HOSTCC="gcc"
	export HOSTCXX="g++"
	export MKOPTS="-j$(expr $(nproc) + 1)"

	export CPPFLAGS="-D_FORTIFY_SOURCE=2"
	export CFLAGS="-Os -g0"
	export CXXFLAGS="-Os -g0"
	export LDFLAGS="-s"
}

prepare_filesystem() {
	cd $ROOTFS
	mkdir -p boot bin dev etc/skel home lib mnt proc root share srv sys tmp var
	mkdir -p var/log/sshd var/log/crond var/log/dmesg
	mkdir -p var/empty var/service var/lib var/spool/cron/crontabs

	ln -sfn . usr
	ln -sfn bin sbin

	chmod 1777 tmp
	chmod 700 root

	cp -a $KEEP/etc/* etc/
#	cp -a $KEEP/boot/* boot/
	chmod 0600 etc/shadow

	cp -a $KEEP/{genfstab,runsvdir-start,zzz} bin/

	for services in tty1 tty2 tty3 tty4 tty5 tty6 ttyS0 dmesg; do
		ln -s /etc/service/$services var/service/$services
	done

	ln -s /proc/self/mounts etc/mtab

	mkdir -p \
		etc/network/if-down.d \
		etc/network/if-post-down.d \
		etc/network/if-post-up.d \
		etc/network/if-pre-down.d \
		etc/network/if-pre-up.d \
		etc/network/if-up.d
}

build_toolchain() {
	source $KEEP/toolchain_vers

	cd $SOURCES
	curl -L -O https://github.com/anthraxx/linux-hardened/releases/download/$LINUXPATCHVER/linux-hardened-$LINUXPATCHVER.patch -C -

	tarxf ftp://ftp.astron.com/pub/file/ file-$FILEVER .tar.gz
	./configure \
		--prefix=$TOOLS
	make $MKOPTS
	make install

	tarxf http://distfiles.dereferenced.org/pkgconf/ pkgconf-$PKGCONFVER .tar.xz
	LDFLAGS="-s -static" \
	./configure \
		--prefix=$TOOLS \
		--host=$XTARGET \
		--with-sysroot=$ROOTFS \
		--with-pkg-config-dir="$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig"
	make $MKOPTS
	make install
	ln -s pkgconf $TOOLS/bin/pkg-config
	ln -s pkgconf $TOOLS/bin/$CROSS_COMPILEpkg-config

	tarxf http://ftpmirror.gnu.org/gnu/binutils/ binutils-$BINUTILSVER .tar.xz
	sed -i "/ac_cpp=/s/\$CPPFLAGS/\$CPPFLAGS -O2/" libiberty/configure
	mkdir build
	cd build
	../configure \
		--prefix=$TOOLS \
		--target=$XTARGET \
		--with-sysroot=$ROOTFS \
		--enable-deterministic-archives \
		--disable-multilib \
		--disable-nls \
		--disable-werror
	make configure-host $MKOPTS
	make $MKOPTS
	make install

	tarxfalt http://ftpmirror.gnu.org/gnu/gmp/ gmp-$GMPVER .tar.xz
	tarxfalt http://www.mpfr.org/mpfr-$MPFRVER/ mpfr-$MPFRVER .tar.xz
	tarxfalt http://ftpmirror.gnu.org/gnu/mpc/ mpc-$MPCVER .tar.gz
	tarxfalt http://isl.gforge.inria.fr/ isl-$ISLVER .tar.xz
	tarxf http://ftpmirror.gnu.org/gnu/gcc/gcc-$GCCVER/ gcc-$GCCVER .tar.xz
	mv ../gmp-$GMPVER gmp
	mv ../mpfr-$MPFRVER mpfr
	mv ../mpc-$MPCVER mpc
	mv ../isl-$ISLVER isl
	patch -Np1 -i $KEEP/gcc/gcc-pure64.patch
	patch -Np1 -i $KEEP/gcc/gcc-pure64-mips.patch
	sed -i 's@\./fixinc\.sh@-c true@' gcc/Makefile.in
	sed -i "/ac_cpp=/s/\$CPPFLAGS/\$CPPFLAGS -O2/" {libiberty,gcc}/configure
	mkdir build
	cd build
	../configure $GCCOPTS \
		--prefix=$TOOLS \
		--build=$XHOST \
		--host=$XHOST \
		--target=$XTARGET \
		--with-sysroot=$ROOTFS \
		--with-newlib \
		--without-headers \
		--enable-languages=c \
		--disable-decimal-float \
		--disable-libatomic \
		--disable-libcilkrts \
		--disable-libgomp \
		--disable-libitm \
		--disable-libmudflap \
		--disable-libmpx \
		--disable-libquadmath \
		--disable-libsanitizer \
		--disable-libssp \
		--disable-libstdc++-v3 \
		--disable-libvtv \
		--disable-multilib \
		--disable-nls \
		--disable-shared \
		--disable-threads
	make all-gcc all-target-libgcc $MKOPTS
	make install-gcc install-target-libgcc

	tarxf https://cdn.kernel.org/pub/linux/kernel/v4.x/ linux-$LINUXVER .tar.xz
	patch -Np1 -i $SOURCES/linux-hardened-$LINUXPATCHVER.patch
	make mrproper $MKOPTS
	make ARCH=$XKARCH INSTALL_HDR_PATH=$ROOTFS headers_install
	find $ROOTFS/include -name .install -or -name ..install.cmd | xargs rm -rf
	clean_libtool

	tarxf http://www.musl-libc.org/releases/ musl-$MUSLVER .tar.gz
	CROSS_COMPILE=$CROSS_COMPILE \
	./configure \
		--prefix= \
		--syslibdir=/lib \
		--build=$XHOST \
		--host=$XTARGET \
		--enable-optimize
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	ln -sf ../lib/libc.so $ROOTFS/bin/ldd

	tarxfalt http://ftpmirror.gnu.org/gnu/gmp/ gmp-$GMPVER .tar.xz
	tarxfalt http://www.mpfr.org/mpfr-$MPFRVER/ mpfr-$MPFRVER .tar.xz
	tarxfalt http://ftpmirror.gnu.org/gnu/mpc/ mpc-$MPCVER .tar.gz
	tarxfalt http://isl.gforge.inria.fr/ isl-$ISLVER .tar.xz
	tarxf http://ftpmirror.gnu.org/gnu/gcc/gcc-$GCCVER/ gcc-$GCCVER .tar.xz
	mv ../gmp-$GMPVER gmp
	mv ../mpfr-$MPFRVER mpfr
	mv ../mpc-$MPCVER mpc
	mv ../isl-$ISLVER isl
	patch -Np1 -i $KEEP/gcc/gcc-pure64.patch
	patch -Np1 -i $KEEP/gcc/gcc-pure64-mips.patch
	sed -i 's@\./fixinc\.sh@-c true@' gcc/Makefile.in
	sed -i "/ac_cpp=/s/\$CPPFLAGS/\$CPPFLAGS -O2/" {libiberty,gcc}/configure
	mkdir build
	cd build
	../configure $GCCOPTS \
		--prefix=$TOOLS \
		--build=$XHOST \
		--host=$XHOST \
		--target=$XTARGET \
		--with-sysroot=$ROOTFS \
		--enable-__cxa_atexit \
		--enable-checking=release \
		--enable-default-pie \
		--enable-default-ssp \
		--enable-languages=c,c++ \
		--enable-lto \
		--enable-threads=posix \
		--enable-tls \
		--disable-gnu-indirect-function \
		--disable-libmpx \
		--disable-libmudflap \
		--disable-libsanitizer \
		--disable-multilib \
		--disable-nls \
		--disable-symvers \
		--disable-werror
	make $MKOPTS
	make install
}

prepare_rootfs_build() {
	export CROSS_COMPILE="$XTARGET-"
	export CC="$XTARGET-gcc"
	export CXX="$XTARGET-g++"
	export AR="$XTARGET-ar"
	export AS="$XTARGET-as"
	export RANLIB="$XTARGET-ranlib"
	export LD="$XTARGET-ld"
	export STRIP="$XTARGET-strip"
	export PKG_CONFIG_PATH="$ROOTFS/usr/lib/pkgconfig:$ROOTFS/usr/share/pkgconfig"
	export PKG_CONFIG_SYSROOT_DIR="$ROOTFS"
}

build_rootfs() {
	source $KEEP/toolchain_vers

	tarxf http://busybox.net/downloads/ busybox-1.28.4 .tar.bz2
	make ARCH=$XKARCH CROSS_COMPILE=$CROSS_COMPILE defconfig $MKOPTS
	sed -i 's/\(CONFIG_\)\(.*\)\(INETD\)\(.*\)=y/# \1\2\3\4 is not set/g' .config
	sed -i 's/\(CONFIG_IFPLUGD\)=y/# \1 is not set/' .config
	sed -i 's/\(CONFIG_FEATURE_WTMP\)=y/# \1 is not set/' .config
	sed -i 's/\(CONFIG_FEATURE_UTMP\)=y/# \1 is not set/' .config
	sed -i 's/\(CONFIG_UDPSVD\)=y/# \1 is not set/' .config
	sed -i 's/\(CONFIG_TCPSVD\)=y/# \1 is not set/' .config
	make ARCH=$XKARCH CROSS_COMPILE=$CROSS_COMPILE EXTRA_CFLAGS="$CFLAGS" $MKOPTS
	make ARCH=$XKARCH CROSS_COMPILE=$CROSS_COMPILE CONFIG_PREFIX=$ROOTFS install

	# Configure busybox
	chmod 4755 $ROOTFS/bin/busybox
	install -Dm0755 examples/udhcp/simple.script $ROOTFS/share/udhcpc/default.script
	rm -rf $ROOTFS/linuxrc

	tarxf https://sortix.org/libz/release/ libz-1.2.8.2015.12.26 .tar.gz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	tarxf http://ftpmirror.gnu.org/gnu/m4/ m4-1.4.18 .tar.xz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	tarxf http://ftpmirror.gnu.org/gnu/bison/ bison-3.0.5 .tar.xz
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--disable-nls
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	tarxf http://github.com/westes/flex/releases/download/v2.6.4/ flex-2.6.4 .tar.gz
cat > config.cache << EOF
ac_cv_func_malloc_0_nonnull=yes
ac_cv_func_realloc_0_nonnull=yes
EOF
	./configure \
		--prefix= \
		--build=$XHOST \
		--host=$XTARGET \
		--cache-file=config.cache \
		--disable-nls
	make $MKOPTS
	make DESTDIR=$ROOTFS install
	clean_libtool

	tarxf http://ftp.barfooze.de/pub/sabotage/tarballs/ libelf-compat-0.152c001 .tar.bz2
	echo "CFLAGS += $CFLAGS -fPIC" > config.mak
	sed -i 's@HEADERS = src/libelf.h@HEADERS = src/libelf.h src/gelf.h@' Makefile
	make CC="$CC" HOSTCC="$HOSTCC" $MKOPTS
	make prefix= DESTDIR=$ROOTFS install
	clean_libtool

	tarxf http://ftpmirror.gnu.org/gnu/binutils/ binutils-$BINUTILSVER .tar.xz
	sed -i "/ac_cpp=/s/\$CPPFLAGS/\$CPPFLAGS -O2/" libiberty/configure
	mkdir build
	cd build
	../configure \
		--prefix= \
		--libdir=/lib \
		--libexecdir=/lib \
		--build=$XHOST \
		--host=$XTARGET \
		--target=$XTARGET \
		--with-system-zlib \
		--enable-deterministic-archives \
		--enable-gold \
		--enable-ld=default \
		--enable-plugins \
		--enable-shared \
		--disable-multilib \
		--disable-nls \
		--disable-werror
	make configure-host $MKOPTS
	make tooldir=/ $MKOPTS
	make tooldir=/ DESTDIR=$ROOTFS install
	clean_libtool
}

check_for_root
setup_architecture
setup_environment
prepare_filesystem
build_toolchain
prepare_rootfs_build
build_rootfs

exit 0

