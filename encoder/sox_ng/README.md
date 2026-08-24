# README.md

The `SoX_ng` project imports, compares and refines bug fixes and
new work from the 50-odd software distributions that package SoX
and from the plethora of forks on github and elsewhere
and makes regular releases with a six-monthly cadence
for each of the micro (bug fixes) and minor (new features) releases.
A major release (non-backwards-compatible changes) is not planned.

The next micro release is scheduled for the 18th August 2026.<BR>
The next minor release is scheduled for the 18th November 2026.

## Terminology

`sox` means [sox.sf.net](http://sox.sf.net)<BR>
`SoX` means the Swiss Army Knife of command-line audio processing in any of its incarnations<BR>
`sox_ng` means the hard fork of `sox-14.4.2` aiming to sanitize `SoX`<BR>
`SoX_ng` means the project to maintain `sox_ng`

## How to get it

`sox_ng` lives at
[codeberg.org/sox_ng/sox_ng](https://codeberg.org/sox_ng/sox_ng)
and is composed of a SoX code base, a wiki and an issue tracker.

### Releases

On the [releases page](https://codeberg.org/sox_ng/sox_ng/releases)
you'll find source code tarballs and Windows `exe`s.

#### Compiling it from source

On Unix-compatible systems, extract it:

    gzip -d < sox_ng-*.tar.gz | tar xf -

Build it:

    cd sox_ng*
    ./configure
    make

On most systems you should only get two compiler warnings
about `#pragma STDC FENV_ACCESS`

Install it:

    sudo make install

It installs as `sox_ng`, `sox_ng.h`, `libsox_ng.so` and so on
so that `sox` and `sox_ng` can coexist on the same system.
To make it work the same as the original `sox`, use
`./configure --enable-replace`

### Development branches

#### main

To fetch the latest version:

    git clone https://codeberg.org/sox_ng/sox_ng
    cd sox_ng

and to make local copies of the wiki and the issues:

    git clone https://codeberg.org/sox_ng/sox_ng.wiki wiki
    issues/getissues.sh

To compile it:

    autoreconf -i
    ./configure
    make

and to install it:

    sudo make install

This installs it as `sox_ng`, `sox_ng.h`, `libsox_ng` and so on,
so that it can coexist with traditional `sox`. If you want it to work
the same as the original `sox`, use `./configure --enable-replace`
and if `ffmpeg` is installed add `--with-ffmpeg` to decode 48 more
audio and video formats.

## Runtime dependencies

If `ffmpeg` is installed on your system, `sox_ng` will be able to read
four dozen more audio formats as well as extract soundtracks from video files.

If `wget`, `wget2` or `curl` are installed, you can fetch URLs as input
streams.

## Build dependencies

To compile a release tarball you will need `make`, and `gcc` or `clang`

To build the git repository you will also need `autoconf`, `automake`
and `libtool`.

To enable all of SoX's optional modules you can install
`ladspa-sdk`
`lame`,
`libao`,
`libfftw3`,
`libflac`,
`libid3tag`,
`libmad`
`libogg`,
`libopus`,
`libopusfile`,
`libpng`,
`libsndfile`,
`libspeex`,
`libspeexdsp`,
`libvorbis`,
`opencore-amr`,
`twolame`,
`wavpack`.

### Debian, Ubuntu, Mint etc.

    apt install gcc make libtool ladspa-sdk libao-dev libasound2-dev libfftw3-dev \
	libgsm1-dev libid3tag0-dev libltdl-dev libmad0-dev libmagic-dev \
	libmp3lame-dev libopencore-amrnb-dev libopencore-amrwb-dev \
	libopusfile-dev libpng-dev libpulse-dev \
	libsndfile1-dev libspeex-dev libspeexdsp-dev libtwolame-dev \
	libvorbis-dev libwavpack-dev

and to run `issues/getissues.sh` and the `makehtml.sh` scripts you will need

    apt-get install jq libtext-multimarkdown-perl

### Fedora, Red Hat, CentOS etc.

    yum install gcc make libtool \
	alsa-lib-devel fftw-devel file-devel flac-devel gsm-devel \
	ladspa-devel lame-devel libao-devel libid3tag-devel \
	libmad-devel libpng-devel libsndfile-devel \
	libtool-ltdl-devel libvorbis-devel opencore-amr-devel \
	opusfile-devel pulseaudio-libs-devel speex-devel speexdsp-devel \
	twolame-devel wavpack-devel

and to run `issues/getissues.sh` and the `makehtml.sh` scripts you will need

    yum install jq multimarkdown

### FreeBSD

    pkg install gcc dmake fftw3 file ladspa libid3tag png \
	flac gsm lame libmad libsndfile libvorbis opencore-amr \
	opusfile speex speexdsp twolame wavpack

but you can almost certainly omit `file` which it wants for `libmagic`
which is installed in a default FreeBSD installation in `/usr/lib`.
If you install it with `pkg`, you get a second copy under `/usr/local`.

You can also install `pulseaudio` `alsa-libs` and `libao`
if you want support for those alternative sound I/O systems.

If you are compiling its development git tree you will also need to

    pkg install autotools libtool

To run `issues/getissues.sh` and the `makehtml.sh` scripts you will need

    pkg install jq multimarkdown

### MacOS/X

As well as the above, you can also install it with Homebrew:

    brew install sox_ng

### NetBSD, OpenWRT and Solus

There are packages for these [on `pkgs.org`](https://pkgs.org/download/sox_ng)

### Windows

On the [releases page](https://codeberg.org/sox_ng/sox_ng/releases)
you'll find `zip` files containing a Windows `exe` for `sox_ng`,
which you can copy to `sox.exe`, `soxi.exe`, `play.exe` and `rec.exe'
(they are all the same program which behaves differently according to
its name).

You may also be able to

    winget --install sox_ng.sox_ng -e

## Accessibility

You can edit and commit to the code and the wiki using Codeberg's web interface
or from the command-line.
The command-line is the only way to add images and attachments to the wiki.

The issues can be downloaded as well as uploaded replacing all remote content
but this risks overwriting changes made via the web interface so for now
it is recommended to edit them on the Codeberg web site.

## Community

### Mailing list

* [sox-ng@groups.io](https://groups.io/g/sox-ng)<BR>
  To subscribe, go there or send an email to
  [sox-ng+subscribe@groups.io](mailto:sox-ng+subscribe@groups.io)

### Private email

* [sox_ng@fastmail.com](mailto:sox_ng@fastmail.com)

### Finances

* [`SoX_ng`'s financial accounts](Accounting) are public and
* [Bounties](Bounties) can be offered for specific issues to be resolved

## README and PDFs

To generate SoX's original README, run `./README.sh` or `make README`

To generate the PDF version of the documentation, `make pdf`
