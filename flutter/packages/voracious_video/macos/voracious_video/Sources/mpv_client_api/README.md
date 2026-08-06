# Vendored libmpv client API headers

`include/mpv/{client,render,render_gl}.h`, copied verbatim from mpv 0.41.0.

They are **ISC**-licensed — unlike the mpv core, which is GPLv2+ by default and
LGPLv2.1+ when built with `-Dgpl=false`. The upstream header says so in as many
words: the client API is ISC "to enable other wrappers outside of mpv". Copying
them carries no copyleft obligation and does not change this package's position
on linking.

## Why vendor them at all

The alternative is to require libmpv's development headers on every machine
that builds the app, which would make a Homebrew install a build dependency of
a Flutter package. Worse, it would tempt the build into linking against
whatever `libmpv.dylib` it found — and linking is exactly what the LGPL
arrangement in [`docs/lgpl-mpv-build.md`](../../../../../../docs/lgpl-mpv-build.md)
avoids.

**Nothing in this package links against libmpv.** The headers supply struct
layouts and enum values only; every entry point is resolved with `dlsym` from
the library the Dart side already opened, whose path it passes across the
channel. That keeps one libmpv in the process, keeps it user-replaceable, and
means a missing library surfaces as the descriptive error `MpvLibrary.open`
already produces rather than as a launch failure of the whole app.

## Updating them

Copy the three files from the mpv source tree you are building against and run
the macOS app. `shim.c` static-asserts the two struct layouts the Swift side
depends on, so an ABI change fails the build rather than silently mis-passing
arguments.
