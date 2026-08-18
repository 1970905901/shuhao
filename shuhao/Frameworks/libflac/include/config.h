/* Hand-crafted libFLAC config.h for iOS / Darwin.
 * Replaces autoconf-generated config.h. Decoder-only build, no Ogg, no SIMD intrinsics.
 * Mirrors what cmake/autoconf would produce on Apple ARM64. */

#ifndef LIBFLAC_IOS_CONFIG_H
#define LIBFLAC_IOS_CONFIG_H

/* Platform */
#define FLAC__SYS_DARWIN 1
#define WORDS_BIGENDIAN 0
#define CPU_IS_BIG_ENDIAN 0
#define CPU_IS_LITTLE_ENDIAN 1

/* Feature toggles */
#define FLAC__HAS_OGG 0           /* no Ogg-FLAC; raw .flac only */
#define FLAC__NO_ASM 1            /* avoid x86/AArch64 intrinsics — pure C */
#define FLAC__INTEGER_ONLY_LIBRARY 0
#define ENABLE_64_BIT_WORDS 0

/* libc / POSIX features (all available on Darwin) */
#define HAVE_BSWAP16 1
#define HAVE_BSWAP32 1
#define HAVE_FSEEKO 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_PARAM_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HAVE_LROUND 1
#define HAVE_TYPEOF 1

/* Package identity */
#define PACKAGE "flac"
#define PACKAGE_NAME "flac"
#define PACKAGE_STRING "flac 1.4.3"
#define PACKAGE_TARNAME "flac"
#define PACKAGE_URL ""
#define PACKAGE_VERSION "1.4.3"
#define PACKAGE_BUGREPORT "flac-dev@xiph.org"
#define VERSION "1.4.3"

#endif
