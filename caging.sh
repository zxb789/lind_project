#!/bin/bash
#
# Try to ease the burden of building lind (repy, nacl, and toolchain)
#
# Created by Chris Matthews <cmatthew@cs.uvic.ca>
# Updated by Joey Pabalinas <joeypabalinas@gmail.com>

# Uncomment this to print each command as they are executed
# ≈set -o xtrace

# Uncomment this for debugging. Will stop B on any failed commands
# set -o errexit

# Uncomment this to dump time profiling information out to a file to see where the script is slow
# PS4='+ $(date "+%s.%N")\011 '
# exec 3>&2 2> bashstart.$$.log
# set -x

trap 'echo "All done."' EXIT

if [[ -z "$REPY_PATH" ]]; then
   echo "Need to set REPY_PATH"
   exit 1
fi

if [[ -z "$LIND_BASE" ]]; then
   echo "Need to set LIND_BASE"
   exit 1
fi

if [[ -z "$LIND_SRC" ]]; then
   echo "Need to set LIND_SRC"
   exit 1
fi

readonly OS_NAME="$(uname -s)"
if [[ "$OS_NAME" == Darwin ]]; then
  readonly OS_SUBDIR="mac"
elif [[ "$OS_NAME" == Linux ]]; then
  readonly OS_SUBDIR="linux"
else
  readonly OS_SUBDIR="win"
fi
readonly MODE="dbg-$OS_SUBDIR"
readonly LIND_BASE="$LIND_BASE"
readonly LIND_SRC="$LIND_SRC"
readonly MISC_DIR="$LIND_BASE/misc"
readonly NACL_SRC="$LIND_SRC/nacl_src"
readonly NACL_BASE="$NACL_SRC/nacl"
readonly NACL_TOOLCHAIN_BASE="$NACL_BASE/tools"
readonly LIND_GLIBC_SRC="$LIND_BASE/lind_glibc"
readonly NACL_GCC_SRC="$LIND_BASE/nacl-gcc"
readonly NACL_BINUTILS_SRC="$LIND_BASE/nacl-binutils"
readonly NACL_REPY="$LIND_BASE/nacl_repy"
readonly NACL_PORTS_DIR="$LIND_BASE/naclports"

readonly REPY_PATH="$REPY_PATH"
readonly REPY_PATH_BIN="$REPY_PATH/bin"
readonly REPY_PATH_REPY="$REPY_PATH/repy"
readonly REPY_PATH_LIB="$REPY_PATH/lib"
readonly REPY_PATH_SDK="$REPY_PATH/sdk"

readonly LIND_MISC_URL='https://github.com/Lind-Project/Lind-misc.git'
readonly THIRD_PARTY_URL='https://github.com/Lind-Project/third_party.git'
readonly LSS_URL='https://github.com/Lind-Project/linux-syscall-support.git'
readonly NACL_REPY_URL='https://github.com/Lind-Project/nacl_repy.git'
readonly NACL_GCC_URL='https://github.com/Lind-Project/nacl-gcc.git'
readonly NACL_BINUTILS_URL='https://github.com/Lind-Project/nacl-binutils.git'
readonly NACL_GCLIENT_URL='https://github.com/Lind-Project/native_client.git@fork'
readonly NACL_PORTS_URL='https://chromium.googlesource.com/external/naclports.git'
readonly LIND_GLIBC_URL='https://github.com/Lind-Project/Lind-GlibC.git'

readonly -a PYGREPL=(grep '-lIPR' '(^|'"'"'|"|[[:space:]]|/)(python)([[:space:]]|\.exe|$)' './')
readonly -a PYGREPV=(grep '-vP' -- '\.(git|.?html|cc?|h|exp|so\.old|so)\b')
readonly -a PYSED=(sed '-r' 's_(^|'"'"'|"|[[:space:]]|/)(python)([[:space:]]|\.exe|$)_\1\22\3_g')
readonly -a PNACLGREPL=(grep '-IFRlw' -- "\${PNACLPYTHON}" './')
readonly -a PNACLGREPV=(grep '-vP' -- '\.(git|.?html|cc?|h|exp|so\.old|so)\b')
readonly -a PNACLSED=(sed "s_\${PNACLPYTHON}_python2_g")

readonly -a RSYNC=(rsync '-akpvAP' '--progress=status2' '--force')

export VIRTUALENVWRAPPER_PYTHON=python2
export VIRTUALENVWRAPPER_VIRTUALENV=virtualenv2
export WORKON_HOME="$LIND_BASE/.virtualenvs"

if [[ "$NACL_SDK_ROOT" != "$REPY_PATH_SDK" ]]; then
  echo "You need to set $NACL_SDK_ROOT to $REPY_PATH_SDK"
  exit 1
fi


# wrapper for desired logging command
#
function print {
    printf '%s\n' "$@" >&2
    # notify-send \
    #   --icon=/usr/share/icons/gnome/256x256/apps/utilities-terminal.png \
    #   "Build Script" "$*" >/dev/null 2>&1
}


# clean downloaded sources
#
function clean_src {
  print "Cleaning $LIND_BASE"
  cd "$LIND_BASE" && rm -rfv lind_glibc misc nacl_repy nacl
  print "Cleaning $NACL_SRC"
  cd "$NACL_SRC" && rm -rfv native_client
  print "Cleaning $NACL_PORTS_DIR"
  cd "$NACL_PORTS_DIR" && rm -rfv src
}


# download sources
#
function download_src {
  local pip_bin pip_ver
  local -A git_deps

  mkdir -p "$LIND_SRC"
  cd "$LIND_BASE" || exit 1

  # clone and symlink dependencies
  git_deps[misc]="$LIND_MISC_URL"
  git_deps[third_party]="$THIRD_PARTY_URL"
  git_deps[lss]="$LSS_URL"
  git_deps[nacl_repy]="$NACL_REPY_URL"
  git_deps[nacl-gcc]="$NACL_GCC_URL"
  git_deps[nacl-binutils]="$NACL_BINUTILS_URL"
  git_deps[lind_glibc]="$LIND_GLIBC_URL"
  for dir in "${!git_deps[@]}"; do
    [[ ! -e "$dir" ]] \
      && git clone -b lind_fork "${git_deps[$dir]}" "$dir"
    [[ ! -e "$LIND_SRC/$dir" ]] \
      && ln -Trsfv "$LIND_BASE/$dir" "$LIND_SRC/$dir"
  done

  # install gclient
  if ! type -P gclient >/dev/null 2>&1; then
    # find pip executable
    if type -P pip2 >/dev/null 2>&1; then
      pip_bin="pip2"
    elif type -P pip >/dev/null 2>&1; then
      pip_bin="pip"
    else
      print "Need to install pip/pip2 in order to build Lind"
      exit 1
    fi
    # check pip version
    pip_ver="$("$pip_bin" --version | sed 's/.*(python \([0-9\.]\+\)).*/\1/')"
    if [[ "$pip_ver" != 2* ]]; then
      print "Need python2 version of pip in order to build Lind"
      exit 1
    fi
    if ! "$pip_bin" install --user virtualenv || ! "$pip_bin" install virtualenv; then
      print "Need python virtualenv in order to build Lind"
      exit 1
    fi
    if ! "$pip_bin" install --user virtualenvwrapper || ! "$pip_bin" install virtualenvwrapper; then
      print "Need python virtualenvwrapper in order to build Lind"
      exit 1
    fi

    # start up virtualenv
    mkdir -p "$WORKON_HOME" || exit 1
    cd "$LIND_BASE" || exit 1
    . ./virtualenvwrapper.sh
    mkvirtualenv lind
    workon lind
    # get gclient and dependencies
    if ! "$pip_bin" install -U SCons gclient; then
      print "Need to \`pip2 install gclient\` in order to build Lind"
      exit 1
    fi
  fi

  # clone nacl
  if [[ ! -e "$LIND_BASE/native_client" ]]; then
    mkdir -p "$NACL_SRC"
    cd "$LIND_BASE" || exit 1
    gclient config --name=native_client "$NACL_GCLIENT_URL"  --git-deps
    gclient sync
    ln -Trsfv "$LIND_BASE/native_client" "$NACL_BASE"
    cd "$NACL_TOOLCHAIN_BASE" && rm -fr SRC
    make sync-pinned
    cd SRC || exit 1
    mv glibc glibc_orig
    ln -Trsfv "$LIND_GLIBC_SRC" glibc
    mv gcc gcc_orig
    ln -Trsfv "$NACL_GCC_SRC" gcc
    mv binutils binutils_orig
    ln -Trsfv "$NACL_BINUTILS_SRC" binutils
  fi

  # clone nacl external ports
  if [[ ! -e "$NACL_PORTS_DIR/src" ]]; then
    mkdir -p "$NACL_PORTS_DIR"
    cd "$NACL_PORTS_DIR" || exit 1
    gclient config --name=src "$NACL_PORTS_URL" --git-deps
    gclient sync
  fi

  cd "$LIND_SRC" || exit 1
}


# wipe the entire modular build toolchain build tree, then rebuild it
# Warning: this can take a while!
#
function clean_toolchain {
     cd "$NACL_TOOLCHAIN_BASE" && rm -rf out BUILD
}


# Compile liblind and the compoent programs.
#
function build_liblind {
    echo -ne "Building liblind... "
    cd "$MISC_DIR/liblind" || exit 1
    make clean
    make all
    echo "done."

}


# Copy the toolchain files into the repy subdir.
#
function install_to_path {
    # nothing should fail here.
    set -o errexit

    echo "Injecting Libs into RePy install"

    print "**Sending NaCl stuff to $REPY_PATH"

    # echo "Deleting all directories in the $REPY_PATH (except repy folder)"
    # rm -rf "${REPY_PATH_BIN:?}"
    # rm -rf "${REPY_PATH_LIB:?}"
    # rm -rf "${REPY_PATH_SDK:?}"

    mkdir -p "$REPY_PATH_BIN"
    mkdir -p "$REPY_PATH_LIB/glibc"
    mkdir -p "$REPY_PATH_SDK/toolchain/${OS_SUBDIR}_x86_glibc"
    mkdir -p "$REPY_PATH_SDK/tools"

    # ${RSYNC} ${NACL_TOOLCHAIN_BASE}/out/nacl-sdk/* ${REPY_PATH_SDK}/toolchain/${OS_SUBDIR}_x86_glibc
    "${RSYNC[@]}" "$NACL_TOOLCHAIN_BASE/out/nacl-sdk"/* "$REPY_PATH_SDK/toolchain/${OS_SUBDIR}_x86_glibc"

    # ${RSYNC} ${NACL_BASE}/scons-out/${MODE}-x86-64/staging/* ${REPY_PATH_BIN}
    "${RSYNC[@]}" "$NACL_BASE/scons-out/${MODE}-x86-64/staging"/* "$REPY_PATH_BIN"

    #install script
    cp -fv "$MISC_DIR/lind.sh" "$REPY_PATH_BIN/lind"
    chmod +x "$REPY_PATH_BIN/lind"

    # ${RSYNC} ${NACL_TOOLCHAIN_BASE}/out/nacl-sdk/x86_64-nacl/lib/*  ${REPY_PATH_LIB}/glibc
    "${RSYNC[@]}" "$NACL_TOOLCHAIN_BASE/out/nacl-sdk/x86_64-nacl/lib"/*  "$REPY_PATH_LIB/glibc"
}


# Run the RePy unit tests.
#
function test_repy {
    cd "$REPY_PATH/repy/" || exit 1
    set +o errexit  # some of our unit tests fail
    for file in ut_lind_*; do
        print "$file"
        trap '' TERM
        python "$file"
    # trap 'python2 "$file"' INT TERM EXIT
    done

    # run the struct test
    file=ut_seattlelibtests_teststruct.py
    print "$file"
    python "$file"

}


# Run the applications test stuites.
#
function test_apps {
    set +o errexit
    cd "$MISC_DIR/tests" && ./test.sh
}


# Check the REPY_PATH location to make sure it is safe to be installing stuff there.
#
function check_install_dir {
    [[ ! -d "$REPY_PATH" && -e "$REPY_PATH" ]] && exit -2
    # and if it does not exit, make it.
    mkdir -p "$REPY_PATH"
}


# Install repy into $REPY_PATH with the prepare_tests script.
#
function build_repy {

    set -o errexit

    mkdir -p "$REPY_PATH_REPY"
    print "Building Repy in $REPY_SRC to $REPY_PATH"
    cd "$NACL_REPY" || exit 1
    cp -v seattlelib/xmlrpc* "$REPY_PATH_REPY/"
    python2 preparetest.py -t -f "$REPY_PATH_REPY"
    print "Done building Repy in \"$REPY_PATH_REPY\""
    cd seattlelib || exit 1
    set -o errexit
    for file in *.mix; do
    "$MISC_DIR/check_includes.sh" "$file"
    done
    set +o errexit
    ctags  --language-force=python ./*.mix ./*.repy || true
}


# Update, build and test everything. If there is a problem, freak out.
#
function nightly_build {
    set -o errexit
    # Clean
    # clean_install
    # clean_nacl
    # clean_toolchain
    # check_install_dir
    # Update
    ~/lind/misc/global_update.sh

    # build
    # build_toolchain
    # build_rpc
    # build_glibc
    # build_nacl
    # build_repy
    # build_sdk
    # install_to_path

    # test repy
    test_repy

    # test glibc
    test_glibc

    # test applications
    test_apps

}


# clean repy install
#
function clean_install {
    rm -rf "$REPY_PATH"
    mkdir -p "$REPY_PATH"
}


# Run the NaCl build.
#
function build_nacl {
     print "Building NaCl"
     cd "$NACL_BASE" || exit -1

     # convert files from python to python2
     cd "$NATIVE_CLIENT_SRC" || exit 1
     "${PYGREPL[@]}" 2>/dev/null | \
          "${PYGREPV[@]}" | \
          while read -r file; do
              # preserve executability
              "${PYSED[@]}" <"$file" >"$file.new"
              cat <"$file.new" >"$file"
              rm -f "$file.new"
          done

     # build NaCl with glibc tests
     PATH="$LIND_BASE:$PATH" \
         python2 ./scons.py --verbose --mode="$MODE,nacl" \
         nacl_pic=1 werror=0 \
         platform=x86-64 --nacl_glibc -j4

     # and check
     rc="$?"
     if (("$rc")); then
         print "NaCl Build Failed($rc)" $'\a'
         exit "$rc"
     fi

     print "Done building NaCl $rc"
}


# Run clean on nacl build.
#
function clean_nacl {
     cd "$NACL_BASE" || exit 1
     ./scons --mode="$MODE,nacl" platform=x86-64 --nacl_glibc -c
     print "Done Cleaning NaCl"
}


# Build glibc from source
#
function build_glibc {
     # the build is long and borning, so execute this first if it exists
     if type -P fortune >/dev/null 2>&1; then
         fortune
     else
         print "Fortune Not Found. Skipping."
     fi

     print -ne "Copy component.h header to glibc: "
     cd "$MISC_DIR/liblind" || exit 1
     mkdir -p "$LIND_GLIBC_SRC/sysdeps/nacl//sysdeps/nacl/"
     cp -fvp component.h "$LIND_GLIBC_SRC/sysdeps/nacl/"

     print "Building glibc"

     # if extra files (like editor temp files) are
     # in the subdir glibc tries to compile them too.
     # move them here so they dont cause a problem
     cd "$LIND_GLIBC_SRC/sysdeps/nacl/" || exit 1
     shopt -s nullglob
     for f in .\#*; do
       print "moving editor backupfile $f so it does not get caught in build."
       mv -f "$f" .
     done

     # turns out this works better if you do it from the nacl base dir
     cd "$NACL_TOOLCHAIN_BASE" && rm -fr BUILD out
     sed \
         's!http://git\.chromium\.org!https://chromium.googlesource.com!g' \
         <Makefile \
         >Makefile.new 2>/dev/null \
         && cat \
             <Makefile.new \
             >Makefile \
         && rm -f Makefile.new
     make clean
     # ??? not quite sure why this is needed but it is -jp
     PATH="$LIND_BASE:$PATH" make build-with-glibc -j4 \
         || PATH="$LIND_BASE:$PATH" make build-with-glibc -j4 \
         || exit -1

     print "Done building toolchain"
}


# perform an incremental glibc compile
#
function update_glibc {
    cd "$NACL_TOOLCHAIN_BASE" \
        && PATH="$LIND_BASE:$PATH" make updateglibc
}


# perform a clean glibc compile
#
function update_glibc2 {
    cd "$NACL_TOOLCHAIN_BASE" || exit 1
    rm -rf BUILD/stamp-glibc64
    PATH="$LIND_BASE:$PATH" make BUILD/stamp-glibc64
}


#
# Run the glibc tester
function glibc_tester {
    set -o errexit

    cd "$MISC_DIR/glibc_test/" || exit 1
    make clean
    PATH="$LIND_BASE:$PATH" make all
    cd .. || exit 1
    rm -rfv lind.metadata linddata.*
    lind "$MISC_DIR/glibc_test/glibc_tester.nexe"
}

PS3="build what: "
list=(all repy nacl buildglibc updateglibc updateglibc2)
list+=(download cleansources cleantoolchain cleannacl install)
list+=(liblind sdk rpc)
list+=(test_repy test_glibc test_apps test_all nightly)
if ((!$#)); then
  select choice in "${list[@]}"; do
    set -- "$choice"
    break
  done
fi

# all scripts assume we start here
START_TIME=$(date +%s)

print "$0" "$@"
for word in "$@"; do
    case "$word" in
    repy)
        build_repy;;
    nacl)
        build_nacl;;
    buildglibc)
        build_glibc;;
    updateglibc)
        update_glibc;;
    updateglibc2)
        update_glibc2;;
    all)
        download_src
        build_nacl
        build_glibc
        build_repy
        install_to_path;;
    install)
        print "Installing libs into install dir"
        install_to_path;;
    download)
        print "Downloading Sources"
        download_src;;
    cleansources)
        print "Cleaning Downloaded Sources"
        clean_src;;
    cleantoolchain)
        print "Cleaning Toolchain"
        clean_toolchain;;
    cleannacl)
        print "Cleaning NaCl"
        clean_nacl;;
    liblind)
        print "Building LibLind"
        build_liblind;;
    test_repy)
        print "Testing Repy"
        test_repy;;
    test_glibc)
        print "Testing GLibC"
        glibc_tester;;
    test_apps)
        print "Testing Applications"
        test_apps;;
    test_all)
        print "Testing All"
        test_repy
        glibc_tester
        test_apps;;
    nightly)
        print "Nightly Build"
        nightly_build;;
    *)
        print "Error: Did not find a build target named $word. Exiting..."
        exit 1;;
    esac
done

END_TIME="$(date +%s)"
DIFF="$((END_TIME - START_TIME))"
print "It took $DIFF seconds" $'\a'
