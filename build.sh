#!/bin/bash
#
# this scripts builds a linux based distribution called QBeD. it's based on LFS.
# TODO: split the script into methods

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
sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd

echo 'int main(){}' | $LFS_TGT-gcc -xc -
sanitycheck=$(readelf -l a.out | grep ld-linux)
if [ -z $sanitycheck ]; then
    bail "compilation failure. something broke after glibc compilation step."
fi

rm -v a.out

popd # glibc
popd # sources

# LIBSTDC++
pushd gcc-13.1.0
mv build buildgcc

mkdir -v build
pushd build

../libstdc++-v3/configure                                        \
    --host=$LFS_TGT                                              \
    --build=$(../config.guess)                                   \
    --prefix=/usr                                                \
    --disable-multilib                                           \
    --disable-nls                                                \
    --disable-libstdcxx-pch                                      \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/13.1.0
make
make DESTDIR=$LFS install
popd # gcc
popd # sources

echo "done building the tool chain to build QBeD"
echo "cross compiling temporary tools"

# M4
tar xvf m4-1.4.19.tar.xz
pushd m4-1.4.19

./configure --prefix=/usr          \
--host=$LFS_TGT                    \
--build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install
popd # sources

tar xvf ncurses-6.4.tar.gz
pushd ncurses-6.4

sed -i s/mawk// configure

mkdir build
pushd build

../configure

make -C include
make -C progs tic

popd # ncurses

./configure --prefix=/usr                 \
            --host=$LFS_TGT               \
            --build=$(./config.guess)     \
            --mandir=/usr/share/man       \
            --with-manpage-format=normal  \
            --with-shared                 \
            --without-normal              \
            --with-cxx-shared             \
            --without-debug               \
            --without-ada                 \
            --disable-stripping           \
            --enable-widec

make
make DESTDIR=$LFS TIC_PATH=$(pwd)/build/progs/tic install
echo "INPUT(-lncursesw)" > $LFS/usr/lib/libncurses.so
popd # sources

# BASH
tar xvf bash-5.2.15.tar.gz
pushd bash-5.2.15

./configure --prefix=/usr              \
    --build=$(sh support/config.guess) \
    --host=$LFS_TGT                    \
    --without-bash-malloc

make
make DESTDIR=$LFS install

ln -sv bash $LFS/bin/sh

popd # sources

# Coreutils
tar xvf coreutils-9.3.tar.xz
pushd coreutils-9.3

./configure --prefix=/usr                   \
    --host=$LFS_TGT                         \
    --build=$(build-aux/config.guess)       \
    --enable-install-program=hostname       \
    --enable-no-install-program=kill,uptime \
    gl_cv_macro_MB_CUR_MAX_good=y

make
make DESTDIR=$LFS install

mv -v $LFS/usr/bin/chroot $LFS/usr/sbin
mkdir -pv $LFS/usr/share/man/man8
mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/' $LFS/usr/share/man/man8/chroot.8

popd  # sources

# Diffutils

tar xvf diffutils-3.10.tar.xz
pushd diffutils-3.10

./configure --prefix=/usr --host=$LFS_TGT

make
make DESTDIR=$LFS install
popd

# File

tar xvf file-5.44.tar.gz
pushd file-5.44

mkdir build
pushd build
../configure --disable-bzlib       \
             --disable-libseccomp  \
             --disable-xzlib       \
             --disable-zlib

make
popd  # file

./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess)

make FILE_COMPILE=$(pwd)/build/src/file

make DESTDIR=$LFS install

rm -v $LFS/usr/lib/libmagic.la
popd # sources

# Findutils

tar xvf findutils-4.9.0.tar.xz
pushd findutils-4.9.0

./configure --prefix=/usr           \
    --localstatedir=/var/lib/locate \
    --host=$LFS_TGT                 \
    --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

popd # sources

# GAWK
tar xvf gawk-5.2.2.tar.xz
pushd gawk-5.2.2

sed -i 's/extras//' Makefile.in
./configure --prefix=/usr       \
            --host=$LFS_TGT     \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install
popd # sources

# Grep

tar xvf grep-3.11.tar.xz
pushd grep-3.11

./configure --prefix=/usr --host=$LFS_TGT

make
make DESTDIR=$LFS install

popd # sources

# Gzip
tar xvf gzip-1.12.tar.xz
pushd gzip-1.12

./configure --prefix=/usr --host=$LFS_TGT

make
make DESTDIR=$LFS install

popd # sources

# Make
tar xvf make-4.4.1.tar.gz
pushd make-4.4.1

./configure --prefix=/usr                       \
            --without-guile                     \
            --host=$LFS_TGT                     \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

popd # sources

# Patch
tar xvf patch-2.7.6.tar.xz
pushd patch-2.7.6

./configure --prefix=/usr                     \
            --host=$LFS_TGT                   \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

popd #sources

# Sed
tar xvf sed-4.9.tar.xz
pushd sed-4.9

./configure --prefix=/usr --host=$LFS_TGT

make
make DESTDIR=$LFS install

popd # sources

# Tar

tar xvf tar-1.34.tar.xz
pushd tar-1.34

./configure --prefix=/usr                        \
            --host=$LFS_TGT                      \
            --build=$(build-aux/config.guess)

make
make DESTDIR=$LFS install

popd # sources

# Xz

tar xvf xz-5.4.3.tar.xz
pushd xz-5.4.3

./configure --prefix=/usr                        \
            --host=$LFS_TGT                      \
            --build=$(build-aux/config.guess)    \
            --disable-static                     \
            --docdir=/usr/share/doc/xz-5.4.3

make
make DESTDIR=$LFS install

rm -v $LFS/usr/lib/liblzma.la

popd # sources

# Binutils -- the first time we built binutils we built it with host gcc to be able
# to build target gcc. this time we are using target gcc to build target binutils

if [ -d binutils-2.40 ]; then rm -rfv binutils-2.40; fi

tar xvf binutils-2.40.tar.xz
pushd binutils-2.40

sed '6009s/$add_dir//' -i ltmain.sh

mkdir -v build
pushd build

../configure                    \
    --prefix=/usr               \
    --build=$(../config.guess)  \
    --host=$LFS_TGT             \
    --disable-nls               \
    --enable-shared             \
    --enable-gprofng=no         \
    --disable-werror            \
    --enable-64-bit-bfd

make
make DESTDIR=$LFS install

rm -v $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes}.{a,la}
popd # binutils
popd # sources

# Gcc
if [ -d gcc-13.1.0 ];then rm -rfv gcc-13.1.0;fi

tar xvf gcc-13.1.0.tar.xz
pushd gcc-13.1.0

tar xvf ../mpfr-4.2.0.tar.xz
mv -v mpfr-4.2.0 mpfr
tar xvf ../gmp-6.2.1.tar.xz
mv -v gmp-6.2.1 gmp
tar xvf ../mpc-1.3.1.tar.gz
mv -v mpc-1.3.1 mpc

case $(uname -m) in
    x86_64)
        sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
        ;;
esac

sed '/thread_header =/s/@.*@/gthr-posix.h/' \
    -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in

mkdir -v build
pushd build

../configure                                            \
            --build=$(../config.guess)                  \
            --host=$LFS_TGT                             \
            --target=$LFS_TGT                           \
            LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc   \
            --prefix=/usr                               \
            --with-build-sysroot=$LFS                   \
            --enable-default-pie                        \
            --enable-default-ssp                        \
            --disable-nls                               \
            --disable-multilib                          \
            --disable-libatomic                         \
            --disable-libgomp                           \
            --disable-libquadmath                       \
            --disable-libssp                            \
            --disable-libvtv                            \
            --enable-languages=c,c++

make
make DESTDIR=$LFS install

ln -sv gcc $LFS/usr/bin/cc

popd # gcc
popd # sources

# exit to root
exit

if [ -z $LFS ]; then export LFS=/mnt/qbed;fi

chown -R root:root $LFS/{usr,lib,var,etc,bin,sbin,tools}
case $(uname -m) in
    x86_64)
        chown -R root:root $LFS/lib64
        ;;
esac

mkdir -pv $LFS/{dev,proc,sys,run}

# bind mounting /dev devtmpfs
mount -v --bind /dev $LFS/dev

# bind mount pesudo terminal vfs
mount -v --bind /dev/pts $LFS/dev/pts

# mount procfs
mount -vt proc proc $LFS/proc

# mount sysfs
mount -vt sysfs sysfs $LFS/sys

# mount tmpfs
mount -vt tmpfs tmpfs $LFS/run

if [ -h $LFS/dev/shm ]; then
    mkdir -pv $LFS/$(readlink $LFS/dev/shm)
else
    mount -t tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
fi

if [ ! -a $LFS/lib/ld-linux-x86-64.so.2 ]; then
    cp sources/glibc-2.37/build/elf/ld-linux-x86-64.so.2 lib/
fi

chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PS1='(lfs chroot) \u:\w\$ ' PATH=/usr/bin:/usr/sbin /bin/bash --login

# Create the system filesystem
mkdir -pv /{boot,home,mnt,opt,srv}
mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{,local/}{include,src}
mkdir -pv /usr/local/{bin,lib,sbin}
mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -pv /usr/{,local/}share/man/man{1..8}
mkdir -pv /var/{cache,local,log,mail,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}
ln -sfv /run /var/run
ln -sfv /run/lock /var/lock
install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp
# ============================================

ln -sv /proc/self/mounts /etc/mtab

cat > /etc/hosts << EOF
127.0.0.1 localhost $(hostname)
::1
localhost
EOF

cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
systemd-oom:x:81:81:systemd Out Of Memory Daemon:/:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

cat > /etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
usb:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
mail:x:34:
kvm:x:61:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-network:x:76:
systemd-resolve:x:77:
systemd-timesync:x:78:
systemd-coredump:x:79:
uuidd:x:80:
systemd-oom:x:81:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

echo "tester:x:101:101::/home/tester:/bin/bash" >> /etc/passwd
echo "tester:x:101:" >> /etc/group
install -o tester -d /home/tester

exec /usr/bin/bash --login

touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp -v utmp /var/log/lastlog
chmod -v 664 /var/log/lastlog
chmod -v 600 /var/log/btmp

# compiling the rest of the packages

cd /sources

# Gettext
tar xvf gettext-0.21.1.tar.xz
pushd gettext-0.21.1

./configure --disable-shared

make

cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin

popd  # sources

# Bison
tar xvf bison-3.8.2.tar.xz
pushd bison-3.8.2

./configure --prefix=/usr --docdir=/usr/share/doc/bison-3.8.2

make
make install
popd # sources

# Perl
tar xvf perl-5.36.1.tar.xz
pushd perl-5.36.1

sh Configure -des                                           \
             -Dprefix=/usr                                  \
             -Dvendorprefix=/usr                            \
             -Duseshrplib                                   \
             -Dprivlib=/usr/lib/perl5/5.36/core_perl        \
             -Darchlib=/usr/lib/perl5/5.36/core_perl        \
             -Dsitelib=/usr/lib/perl5/5.36/site_perl        \
             -Dsitearch=/usr/lib/perl5/5.36/site_perl       \
             -Dvendorlib=/usr/lib/perl5/5.36/vendor_perl    \
             -Dvendorarch=/usr/lib/perl5/5.36/vendor_perl
make
make install

popd # sources

# Python
tar xvf Python-3.11.4.tar.xz
pushd Python-3.11.4

./configure --prefix=/usr       \
            --enable-shared     \
            --without-ensurepip

make
make install
popd # sources

# Texinfo

tar xvf texinfo-7.0.3.tar.xz
pushd texinfo-7.0.3

./configure --prefix=/usr

make
make install

popd # sources

# Util-linux

tar xvf util-linux-2.39.tar.xz
pushd util-linux-2.39

mkdir -pv /var/lib/hwclock
./configure ADJTIME_PATH=/var/lib/hwclock/adjtime\
    --libdir=/usr/lib \
    --runstatedir=/run \
    --docdir=/usr/share/doc/util-linux-2.39 \
    --disable-chfn-chsh \
    --disable-login \
    --disable-nologin   \
    --disable-su    \
    --disable-setpriv   \
    --disable-runuser   \
    --disable-pylibmount \
    --disable-static    \
    --without-python

make
make install
popd # sources

cd ..

# remove docs
rm -rf /usr/share/{info,man,doc}/*

find /usr/{lib,libexec} -name \*.la -delete

rm -rf /tools

# create backup

# exit back to root
exit

# unmount vfs
mountpoint -q $LFS/dev/shm && umount $LFS/dev/shm
umount $LFS/dev/pts
umount $LFS/{sys,proc,run,dev}

cd $LFS
tar -cJpf $HOME/lfs-temp-tools-d7cb883f5f4bdb5497baa2562652c11f2d805ac7-systemd.tar.xz .

#chroot again
chroot "$LFS" /usr/bin/env -i HOME=/root TERM="$TERM" PS1='(lfs chroot) \u:\w\$ ' PATH=/usr/bin:/usr/sbin /bin/bash --login

# man-pages
tar xvf man-pages-6.04.tar.xz
pushd man-pages-6.04

make prefix=/usr install

popd

# Iana-Etc

tar xvf iana-etc-20230524.tar.gz
pushd iana-etc-20230524

cp services protocols /etc

popd

# Glibc 3rd time.. which should be a sharm

if [ -d glibc-2.37 ]; then
    rm -rf glibc-2.37
fi

tar xvf glibc-2.37.tar.xz
pushd glibc-2.37

# this patch is used becuase some programs use the non-FHS compilant /var/db to store runtime data
# this patch makes them store this data in a compilant FHS way. FHS: filesystem hierarchy standard. google it!
patch -Np1 -i ../glibc-2.37-fhs-1.patch

# fix a buf overflow sec vuln in vfprintf
sed '/width -=/s/workend - string/number_length/' -i stdio-common/vfprintf-process-arg.c

mkdir -v build
pushd build

# FIXME: in case something goes wrong the output file in the book is called configparms - missing an a before last m.
echo "rootsbindir=/usr/sbin" > configparams

../configure --prefix=/usr          \
    --disable-werror                \
    --enable-kernel=6.1.30          \
    --enable-stack-protector=strong \
    --with-headers=/usr/include     \
    libc_cv_slibdir=/usr/lib

make
make check

touch /etc/ld.so.conf

sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile

make install

sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd

cp -v ../nscd/nscd.conf /etc/nscd.conf
mkdir -pv /var/cache/nscd

install -v -Dm644 ../nscd/nscd.tmpfiles /usr/lib/tmpfiles.d/nscd.conf
install -v -Dm644 ../nscd/nscd.service /usr/lib/systemd/system/nscd.service

# install locales to get optimal test coverage
make localedata/install-locales
localedef -i POSIX -f UTF-8 C.UTF-8 2> /dev/null || true
localedef -i ja_JP -f SHIFT_JIS ja_JP.SJIS 2> /dev/null || true

# create /etc/nsswitch.conf becuase glibc defaults don't work well in  networked environment
cat > /etc/nsswitch.conf << "EOF"
# Begin /etc/nsswitch.conf
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
# End /etc/nsswitch.conf
EOF

# adding timezone data
tar xvf ../../tzdata2023c.tar.gz

ZONEINFO=/usr/share/zoneinfo
mkdir -pv $ZONEINFO/{posix,right}
for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward; do
    zic -L /dev/null -d $ZONEINFO ${tz}
    zic -L /dev/null -d $ZONEINFO/posix ${tz}
    zic -L leapseconds -d $ZONEINFO/right ${tz}
done

cp -v zone.tab zone1970.tab iso3166.tab $ZONEINFO
zic -d $ZONEINFO -p Europe/Copenhagen
unset ZONEINFO

# linking the local timezone. documenting I was in denmark at the time :)
ln -sfv /usr/share/zoneinfo/Europe/Berlin /etc/localtime

# these two directories are know to be needed by the dynamic loader ld-linux.so
# by default loader searches /usr/lib. other locations need to be added to /etc/ld.so.conf file
cat > /etc/ld.so.conf << "EOF"
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib
EOF

# let's add also a directory capbility to the ld loader
cat >> /etc/ld.so.conf << "EOF"
# Add an include directory
include /etc/ld.so.conf.d/*.conf
EOF
mkdir -pv /etc/ld.so.conf.d

popd # glibc
popd # sources

# zlib -- [de]compression
tar xvf zlib-1.2.13.tar.gz

pushd zlib-1.2.13

./configure --prefix=/usr

make
make check
make install

rm -fv /usr/lib/libz.a

popd # sources

# bzip2 -- compression and decompression of bzip2 alg
tar xvf bzip2-1.0.8.tar.gz

pushd bzip2-1.0.8

# patch that installs the documentation for this package
patch -Np1 -i ../bzip2-1.0.8-install_docs-1.patch

# ensure symlinks are relative
sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile

# ensures man pages are installed correctly
sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile

# cause bzip2 to be built using different Makefile that creates dynamic libbz2.so and links bzip2 utils against it
make -f Makefile-libbz2_so
make clean
make
make PREFIX=/usr install

# install shared libraries
cp -av libbz2.so.* /usr/lib
ln -sv libbz2.so.1.0.8 /usr/lib/libbz2.so

# install shared bzip2 binary to /usr/bin. replace two copies of bzip2 with symlinks
cp -v bzip2-shared /usr/bin/bzip2
for i in /usr/bin/{bzcat,bunzip2}; do
    ln -sfv bzip2 $i
done

# remove useless static libraries
rm -fv /usr/lib/libbz2.a

popd # sources

# XZ -- compressing and decompressing with the xz algo.
if [ -d xz-5.4.3 ]; then
    rm -rf xz-5.4.3
fi

tar xvf xz-5.4.3.tar.xz
pushd xz-5.4.3

./configure --prefix=/usr --disable-static --docdir=/usr/share/doc/xz-5.4.3
make
make check
make install

popd #sources

# zstd -- another compression algorithm support library
tar xvf zstd-1.5.5.tar.gz
pushd zstd-1.5.5

make prefix=/usr
make check
make prefix=/usr install

# remove static library
rm -v /usr/lib/libzstd.a

popd # sources
