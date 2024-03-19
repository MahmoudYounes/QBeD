#!/bin/bash
#
# this scripts builds a linux based distribution called QBeD. it's based on LFS.

. common.sh

bail_if_not_root

# checking host package versions
. ver-check.sh

if [ ! -z $LFS]; then
    export LFS=/mnt/qbed
fi

# for now these steps are manually done
# TODO: accept arguments to a /dev/smth that is used to automate the partition creation.
# TODO: mount the newly created partition on /mnt/qbed

# TODO: uncomment. this takes time and internet bandwidth. I would like to test the script first
# wget --input-file=./wget-list-systemd --directory-prefix=$LFS/sources
# wget --input-file=./wget-list-patches-systemd --directory-prefix=$LFS/sources

# TODO: support a flag for patches download from wget-list-patches-systemd

echo "creating file system hierarchy"
mkdir -pv $LFS/{etc,var} $LFS/usr/{bin,lib,sbin}

for i in bin lib sbin; do
    ln -sv usr/$i $LFS/$i
done

case $(uname -m) in
    x86_64) mkdir -pv $LFS/lib64  ;;
esac

mkdir -pv $LFS/tools
echo "done"
echo "creating group lfs and user lfs"
groupadd lfs
useradd -s /bin/bash -g lfs -m -k /dev/null lfs

echo "invoking passwd on lfs user. enter password when prompted"
passwd lfs

echo "changing ownership of $LFS to lfs user"
chown -v -R lfs $LFS/*

echo "done"
echo "switching to lfs user"
su - lfs

echo $LFS
exit 0

cat > ~/.bash_profile << "EOF"
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

cat > ~/.bashrc << "EOF"
set +h
umask 022
LFS=/mnt/qbed
LC_ALL=POSIX
LFS_TGT=$(uname -m)-qbed-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
PATH=$LFS/tools/bin:$PATH
CONFIG_SITE=$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
EOF

source ~/.bashrc

# TODO:
# building a distro is tightly coupled with the package versions used. in order to be able to rebuild an updated
# version of QBeD we need to lock the package versions. in my mind, I can keep this as a configuration, and make
# all build system (bash scripts) use the package versions configured. in all cases, we have to refer to the
# packages by their full name-version tuple.
#

pushd $LFS/sources

# BINUTILS
tar xvf binutils-2.40.tar.xz
pushd binutils-2.40
mkdir -v build
pushd build
../configure --prefix=$LFS/tools \
             --with-sysroot=$LFS \
             --target=$LFS_TGT   \
             --disable-nls       \
             --enable-gprofng=no \
             --disable-werror
make -j $(nproc)
make install


popd # binutils folder
popd # sources folder

# GCC
tar xvf gcc-13.1.0.tar.xz
pushd gcc-13.1.0

tar -xf ../mpfr-4.2.0.tar.xz
mv -v mpfr-4.2.0 mpfr
tar -xf ../gmp-6.2.1.tar.xz
mv -v gmp-6.2.1 gmp
tar -xf ../mpc-1.3.1.tar.gz
mv -v mpc-1.3.1 mpc

case $(uname -m) in
    x86_64)
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
        ;;
esac

mkdir -v build
pushd build

../configure                       \
    --target=$LFS_TGT              \
    --prefix=$LFS/tools            \
    --with-glibc-version=2.37      \
    --with-sysroot=$LFS            \
    --with-newlib                  \
    --without-headers              \
    --enable-default-pie           \
    --enable-default-ssp           \
    --disable-nls                  \
    --disable-shared               \
    --disable-multilib             \
    --disable-threads              \
    --disable-libatomic            \
    --disable-libgomp              \
    --disable-libquadmath          \
    --disable-libssp               \
    --disable-libvtv               \
    --disable-libstdcxx            \
    --enable-languages=c,c++
make
make install
popd # gcc

cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
$(dirname $($LFS_TGT-gcc -print-libgcc-file-name))/include/limits.h

popd # sources

# LINUX KERNEL
tar xvf linux-6.1.53.tar.xz

pushd linux-6.1.53

make mrproper

make headers

find usr/include -type f ! -name '*.h' -delete

cp -rv usr/include $LFS/usr

popd # sources

# GLIBC
case $(uname -m) in
    i?86)
        ln -sfv ld-linux.so.2 $LFS/lib/ld-lsb.so.3
        ;;
    x86_64)
        ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
        ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
        ;;
esac

tar xvf glibc-2.37.tar.xz

pushd glibc-2.37
patch -Np1 -i ../glibc-2.37-fhs-1.patch

mkdir -v build
pushd build

echo "rootsbindir=/usr/sbin" > configparms

../configure                              \
    --prefix=/usr                         \
    --host=$LFS_TGT                       \
    --build=$(../scripts/config.guess)    \
    --enable-kernel=6.1.53                \
    --with-headers=$LFS/usr/include       \
    libc_cv_slibdir=/usr/lib

make
make DESTDIR=$LFS install
