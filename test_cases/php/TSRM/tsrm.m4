m4_include([TSRM/m4/ax_func_which_gethostbyname_r.m4])

AC_DEFUN([TSRM_BASIC_CHECKS],[

AC_REQUIRE([AC_PROG_CC])dnl
dnl AC_REQUIRE([AM_PROG_CC_STDC])dnl
AC_REQUIRE([AC_PROG_CC_C_O])dnl
AC_REQUIRE([AC_PROG_RANLIB])dnl

AC_CHECK_FUNCS(sigprocmask)

AX_FUNC_WHICH_GETHOSTBYNAME_R()

])


AC_DEFUN([TSRM_CHECK_PTH],[

AC_MSG_CHECKING(for GNU Pth)
PTH_PREFIX="`$1 --prefix`"
if test -z "$PTH_PREFIX"; then
  AC_MSG_RESULT(Please check your Pth installation)
fi

CPPFLAGS="$CPPFLAGS `$1 --cflags`"
LDFLAGS="$LDFLAGS `$1 --ldflags`"
LIBS="$LIBS `$1 --libs`"

AC_DEFINE(GNUPTH, 1, [Whether you use GNU Pth])
AC_MSG_RESULT(yes - installed in $PTH_PREFIX)

])

AC_DEFUN([TSRM_CHECK_ST],[
  if test -r "$1/include/st.h"; then
    CPPFLAGS="$CPPFLAGS -I$1/include"
    LDFLAGS="$LDFLAGS -L$1/lib"
  elif test -r "$1/st.h"; then
    CPPFLAGS="$CPPFLAGS -I$1"
    LDFLAGS="$LDFLAGS -L$1"
  fi
  AC_CHECK_HEADERS(st.h,[],[
    AC_MSG_ERROR([Sorry[,] I was unable to locate the State Threads header file.  Please specify the prefix using --with-tsrm-st=/prefix])
  ])
  LIBS="$LIBS -lst"
  AC_MSG_CHECKING(for SGI's State Threads)
  AC_MSG_RESULT(yes)
  AC_DEFINE(TSRM_ST, 1, [ ])
])

sinclude(threads.m4)

AC_DEFUN([TSRM_CHECK_PTHREADS],[

PTHREADS_CHECK

if test "$pthreads_working" != "yes"; then
  AC_MSG_ERROR(Your system seems to lack POSIX threads.)
fi

AC_DEFINE(PTHREADS, 1, Whether to use Pthreads)

AC_MSG_CHECKING(for POSIX threads)
AC_MSG_RESULT(yes)
])

AC_DEFUN([TSRM_THREADS_CHECKS],[

dnl For the thread implementations, we always use --with-*
dnl to maintain consistency

AC_ARG_WITH(tsrm-pth,
[  --with-tsrm-pth[=pth-config]
                          Use GNU Pth],[
  TSRM_PTH=$withval
],[
  TSRM_PTH=no
])

AC_ARG_WITH(tsrm-st,
[  --with-tsrm-st          Use SGI's State Threads],[
  TSRM_ST=$withval
],[
  TSRM_ST=no
])

AC_ARG_WITH(tsrm-pthreads,
[  --with-tsrm-pthreads    Use POSIX threads (default)],[
  TSRM_PTHREADS=$withval
],[
  TSRM_PTHREADS=yes
])

test "$TSRM_PTH" = "yes" && TSRM_PTH=pth-config

if test "$TSRM_PTH" != "no"; then
  TSRM_CHECK_PTH($TSRM_PTH)
elif test "$TSRM_ST" != "no"; then
  TSRM_CHECK_ST($TSRM_ST)
elif test "$TSRM_PTHREADS" != "no"; then
  TSRM_CHECK_PTHREADS
fi

])
