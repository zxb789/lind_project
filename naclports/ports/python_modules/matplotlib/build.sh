# Copyright (c) 2014 The Native Client Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

NACLPORTS_CPPFLAGS+=" ${NACL_EXCEPTIONS_FLAG}"
BuildStep() {
  NACLPORTS_CFLAGS+=" -fexceptions"
  DefaultPythonModuleBuildStep
}

InstallStep() {
  DefaultPythonModuleInstallStep
}

ConfigureStep() {
  return
}

