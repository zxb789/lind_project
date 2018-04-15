# We borrow heavily from the kernel build setup, though we are simpler since
# we don't have Kconfig tweaking settings on us.

# The implicit make rules have it looking for RCS files, among other things.
# We instead explicitly write all the rules we care about.
# It's even quicker (saves ~200ms) to pass -r on the command line.
MAKEFLAGS=-r

# The source directory tree.
srcdir := .
abs_srcdir := $(abspath $(srcdir))

# The name of the builddir.
builddir_name ?= out

# The V=1 flag on command line makes us verbosely print command lines.
ifdef V
  quiet=
else
  quiet=quiet_
endif

# Specify BUILDTYPE=Release on the command line for a release build.
BUILDTYPE ?= Debug

# Directory all our build output goes into.
# Note that this must be two directories beneath src/ for unit tests to pass,
# as they reach into the src/ directory for data with relative paths.
builddir ?= $(builddir_name)/$(BUILDTYPE)
abs_builddir := $(abspath $(builddir))
depsdir := $(builddir)/.deps

# Object output directory.
obj := $(builddir)/obj
abs_obj := $(abspath $(obj))

# We build up a list of every single one of the targets so we can slurp in the
# generated dependency rule Makefiles in one pass.
all_deps :=



# C++ apps need to be linked with g++.
#
# Note: flock is used to seralize linking. Linking is a memory-intensive
# process so running parallel links can often lead to thrashing.  To disable
# the serialization, override LINK via an envrionment variable as follows:
#
#   export LINK=g++
#
# This will allow make to invoke N linker processes as specified in -jN.
LINK ?= flock $(builddir)/linker.lock $(CXX.target)

CC.target ?= $(CC)
CFLAGS.target ?= $(CFLAGS)
CXX.target ?= $(CXX)
CXXFLAGS.target ?= $(CXXFLAGS)
LINK.target ?= $(LINK)
LDFLAGS.target ?= $(LDFLAGS)
AR.target ?= $(AR)

# TODO(evan): move all cross-compilation logic to gyp-time so we don't need
# to replicate this environment fallback in make as well.
CC.host ?= gcc
CFLAGS.host ?=
CXX.host ?= g++
CXXFLAGS.host ?=
LINK.host ?= g++
LDFLAGS.host ?=
AR.host ?= ar

# Define a dir function that can handle spaces.
# http://www.gnu.org/software/make/manual/make.html#Syntax-of-Functions
# "leading spaces cannot appear in the text of the first argument as written.
# These characters can be put into the argument value by variable substitution."
empty :=
space := $(empty) $(empty)

# http://stackoverflow.com/questions/1189781/using-make-dir-or-notdir-on-a-path-with-spaces
replace_spaces = $(subst $(space),?,$1)
unreplace_spaces = $(subst ?,$(space),$1)
dirx = $(call unreplace_spaces,$(dir $(call replace_spaces,$1)))

# Flags to make gcc output dependency info.  Note that you need to be
# careful here to use the flags that ccache and distcc can understand.
# We write to a dep file on the side first and then rename at the end
# so we can't end up with a broken dep file.
depfile = $(depsdir)/$(call replace_spaces,$@).d
DEPFLAGS = -MMD -MF $(depfile).raw

# We have to fixup the deps output in a few ways.
# (1) the file output should mention the proper .o file.
# ccache or distcc lose the path to the target, so we convert a rule of
# the form:
#   foobar.o: DEP1 DEP2
# into
#   path/to/foobar.o: DEP1 DEP2
# (2) we want missing files not to cause us to fail to build.
# We want to rewrite
#   foobar.o: DEP1 DEP2 \
#               DEP3
# to
#   DEP1:
#   DEP2:
#   DEP3:
# so if the files are missing, they're just considered phony rules.
# We have to do some pretty insane escaping to get those backslashes
# and dollar signs past make, the shell, and sed at the same time.
# Doesn't work with spaces, but that's fine: .d files have spaces in
# their names replaced with other characters.
define fixup_dep
# The depfile may not exist if the input file didn't have any #includes.
touch $(depfile).raw
# Fixup path as in (1).
sed -e "s|^$(notdir $@)|$@|" $(depfile).raw >> $(depfile)
# Add extra rules as in (2).
# We remove slashes and replace spaces with new lines;
# remove blank lines;
# delete the first line and append a colon to the remaining lines.
sed -e 's|\\||' -e 'y| |\n|' $(depfile).raw |\
  grep -v '^$$'                             |\
  sed -e 1d -e 's|$$|:|'                     \
    >> $(depfile)
rm $(depfile).raw
endef

# Command definitions:
# - cmd_foo is the actual command to run;
# - quiet_cmd_foo is the brief-output summary of the command.

quiet_cmd_cc = CC($(TOOLSET)) $@
cmd_cc = $(CC.$(TOOLSET)) $(GYP_CFLAGS) $(DEPFLAGS) $(CFLAGS.$(TOOLSET)) -c -o $@ $<

quiet_cmd_cxx = CXX($(TOOLSET)) $@
cmd_cxx = $(CXX.$(TOOLSET)) $(GYP_CXXFLAGS) $(DEPFLAGS) $(CXXFLAGS.$(TOOLSET)) -c -o $@ $<

quiet_cmd_touch = TOUCH $@
cmd_touch = touch $@

quiet_cmd_copy = COPY $@
# send stderr to /dev/null to ignore messages when linking directories.
cmd_copy = ln -f "$<" "$@" 2>/dev/null || (rm -rf "$@" && cp -af "$<" "$@")

quiet_cmd_alink = AR($(TOOLSET)) $@
cmd_alink = rm -f $@ && $(AR.$(TOOLSET)) crs $@ $(filter %.o,$^)

quiet_cmd_alink_thin = AR($(TOOLSET)) $@
cmd_alink_thin = rm -f $@ && $(AR.$(TOOLSET)) crsT $@ $(filter %.o,$^)

# Due to circular dependencies between libraries :(, we wrap the
# special "figure out circular dependencies" flags around the entire
# input list during linking.
quiet_cmd_link = LINK($(TOOLSET)) $@
cmd_link = $(LINK.$(TOOLSET)) $(GYP_LDFLAGS) $(LDFLAGS.$(TOOLSET)) -o $@ -Wl,--start-group $(LD_INPUTS) -Wl,--end-group $(LIBS)

# We support two kinds of shared objects (.so):
# 1) shared_library, which is just bundling together many dependent libraries
# into a link line.
# 2) loadable_module, which is generating a module intended for dlopen().
#
# They differ only slightly:
# In the former case, we want to package all dependent code into the .so.
# In the latter case, we want to package just the API exposed by the
# outermost module.
# This means shared_library uses --whole-archive, while loadable_module doesn't.
# (Note that --whole-archive is incompatible with the --start-group used in
# normal linking.)

# Other shared-object link notes:
# - Set SONAME to the library filename so our binaries don't reference
# the local, absolute paths used on the link command-line.
quiet_cmd_solink = SOLINK($(TOOLSET)) $@
cmd_solink = $(LINK.$(TOOLSET)) -shared $(GYP_LDFLAGS) $(LDFLAGS.$(TOOLSET)) -Wl,-soname=$(@F) -o $@ -Wl,--whole-archive $(LD_INPUTS) -Wl,--no-whole-archive $(LIBS)

quiet_cmd_solink_module = SOLINK_MODULE($(TOOLSET)) $@
cmd_solink_module = $(LINK.$(TOOLSET)) -shared $(GYP_LDFLAGS) $(LDFLAGS.$(TOOLSET)) -Wl,-soname=$(@F) -o $@ -Wl,--start-group $(filter-out FORCE_DO_CMD, $^) -Wl,--end-group $(LIBS)


# Define an escape_quotes function to escape single quotes.
# This allows us to handle quotes properly as long as we always use
# use single quotes and escape_quotes.
escape_quotes = $(subst ','\'',$(1))
# This comment is here just to include a ' to unconfuse syntax highlighting.
# Define an escape_vars function to escape '$' variable syntax.
# This allows us to read/write command lines with shell variables (e.g.
# $LD_LIBRARY_PATH), without triggering make substitution.
escape_vars = $(subst $$,$$$$,$(1))
# Helper that expands to a shell command to echo a string exactly as it is in
# make. This uses printf instead of echo because printf's behaviour with respect
# to escape sequences is more portable than echo's across different shells
# (e.g., dash, bash).
exact_echo = printf '%s\n' '$(call escape_quotes,$(1))'

# Helper to compare the command we're about to run against the command
# we logged the last time we ran the command.  Produces an empty
# string (false) when the commands match.
# Tricky point: Make has no string-equality test function.
# The kernel uses the following, but it seems like it would have false
# positives, where one string reordered its arguments.
#   arg_check = $(strip $(filter-out $(cmd_$(1)), $(cmd_$@)) \
#                       $(filter-out $(cmd_$@), $(cmd_$(1))))
# We instead substitute each for the empty string into the other, and
# say they're equal if both substitutions produce the empty string.
# .d files contain ? instead of spaces, take that into account.
command_changed = $(or $(subst $(cmd_$(1)),,$(cmd_$(call replace_spaces,$@))),\
                       $(subst $(cmd_$(call replace_spaces,$@)),,$(cmd_$(1))))

# Helper that is non-empty when a prerequisite changes.
# Normally make does this implicitly, but we force rules to always run
# so we can check their command lines.
#   $? -- new prerequisites
#   $| -- order-only dependencies
prereq_changed = $(filter-out FORCE_DO_CMD,$(filter-out $|,$?))

# Helper that executes all postbuilds until one fails.
define do_postbuilds
  @E=0;\
  for p in $(POSTBUILDS); do\
    eval $$p;\
    E=$$?;\
    if [ $$E -ne 0 ]; then\
      break;\
    fi;\
  done;\
  if [ $$E -ne 0 ]; then\
    rm -rf "$@";\
    exit $$E;\
  fi
endef

# do_cmd: run a command via the above cmd_foo names, if necessary.
# Should always run for a given target to handle command-line changes.
# Second argument, if non-zero, makes it do asm/C/C++ dependency munging.
# Third argument, if non-zero, makes it do POSTBUILDS processing.
# Note: We intentionally do NOT call dirx for depfile, since it contains ? for
# spaces already and dirx strips the ? characters.
define do_cmd
$(if $(or $(command_changed),$(prereq_changed)),
  @$(call exact_echo,  $($(quiet)cmd_$(1)))
  @mkdir -p "$(call dirx,$@)" "$(dir $(depfile))"
  $(if $(findstring flock,$(word 1,$(cmd_$1))),
    @$(cmd_$(1))
    @echo "  $(quiet_cmd_$(1)): Finished",
    @$(cmd_$(1))
  )
  @$(call exact_echo,$(call escape_vars,cmd_$(call replace_spaces,$@) := $(cmd_$(1)))) > $(depfile)
  @$(if $(2),$(fixup_dep))
  $(if $(and $(3), $(POSTBUILDS)),
    $(call do_postbuilds)
  )
)
endef

# Declare the "all" target first so it is the default,
# even though we don't have the deps yet.
.PHONY: all
all:

# make looks for ways to re-generate included makefiles, but in our case, we
# don't have a direct way. Explicitly telling make that it has nothing to do
# for them makes it go faster.
%.d: ;

# Use FORCE_DO_CMD to force a target to run.  Should be coupled with
# do_cmd.
.PHONY: FORCE_DO_CMD
FORCE_DO_CMD:

TOOLSET := host
# Suffix rules, putting all outputs into $(obj).
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

# Try building from generated source, too.
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

$(obj).$(TOOLSET)/%.o: $(obj)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

TOOLSET := target
# Suffix rules, putting all outputs into $(obj).
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(srcdir)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

# Try building from generated source, too.
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj).$(TOOLSET)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)

$(obj).$(TOOLSET)/%.o: $(obj)/%.c FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cc FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cpp FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.cxx FORCE_DO_CMD
	@$(call do_cmd,cxx,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.S FORCE_DO_CMD
	@$(call do_cmd,cc,1)
$(obj).$(TOOLSET)/%.o: $(obj)/%.s FORCE_DO_CMD
	@$(call do_cmd,cc,1)


ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/build/nacl_core_sdk.target.mk)))),)
  include native_client/build/nacl_core_sdk.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/build/pull_in_all.target.mk)))),)
  include native_client/build/pull_in_all.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/crt_fini_32.target.mk)))),)
  include native_client/crt_fini_32.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/crt_fini_64.target.mk)))),)
  include native_client/crt_fini_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/crt_init_32.target.mk)))),)
  include native_client/crt_init_32.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/crt_init_64.target.mk)))),)
  include native_client/crt_init_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/hello_world_nexe.target.mk)))),)
  include native_client/hello_world_nexe.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/prep_nacl_sdk.target.mk)))),)
  include native_client/prep_nacl_sdk.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/prep_toolchain.target.mk)))),)
  include native_client/prep_toolchain.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/simple_thread_test.target.mk)))),)
  include native_client/simple_thread_test.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/gio/gio.target.mk)))),)
  include native_client/src/shared/gio/gio.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/gio/gio_lib.target.mk)))),)
  include native_client/src/shared/gio/gio_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/imc/imc.target.mk)))),)
  include native_client/src/shared/imc/imc.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/imc/imc_lib.target.mk)))),)
  include native_client/src/shared/imc/imc_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/imc/sigpipe_test.target.mk)))),)
  include native_client/src/shared/imc/sigpipe_test.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/platform/platform.target.mk)))),)
  include native_client/src/shared/platform/platform.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/platform/platform_lib.target.mk)))),)
  include native_client/src/shared/platform/platform_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/platform/platform_tests.target.mk)))),)
  include native_client/src/shared/platform/platform_tests.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/serialization/serialization.target.mk)))),)
  include native_client/src/shared/serialization/serialization.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/srpc/nonnacl_srpc.target.mk)))),)
  include native_client/src/shared/srpc/nonnacl_srpc.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/srpc/srpc_lib.target.mk)))),)
  include native_client/src/shared/srpc/srpc_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/shared/utils/utils.target.mk)))),)
  include native_client/src/shared/utils/utils.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/cpu_features/cpu_features.target.mk)))),)
  include native_client/src/trusted/cpu_features/cpu_features.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/debug_stub/debug_stub.target.mk)))),)
  include native_client/src/trusted/debug_stub/debug_stub.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/debug_stub/gdb_rsp_test.target.mk)))),)
  include native_client/src/trusted/debug_stub/gdb_rsp_test.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/desc/desc_wrapper.target.mk)))),)
  include native_client/src/trusted/desc/desc_wrapper.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/desc/nrd_xfer.target.mk)))),)
  include native_client/src/trusted/desc/nrd_xfer.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/fault_injection/nacl_fault_inject.target.mk)))),)
  include native_client/src/trusted/fault_injection/nacl_fault_inject.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/gio/gio_wrapped_desc.target.mk)))),)
  include native_client/src/trusted/gio/gio_wrapped_desc.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/interval_multiset/nacl_interval.target.mk)))),)
  include native_client/src/trusted/interval_multiset/nacl_interval.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/manifest_name_service_proxy/manifest_proxy.target.mk)))),)
  include native_client/src/trusted/manifest_name_service_proxy/manifest_proxy.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/nacl_base/nacl_base.target.mk)))),)
  include native_client/src/trusted/nacl_base/nacl_base.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/nonnacl_util/nonnacl_util.target.mk)))),)
  include native_client/src/trusted/nonnacl_util/nonnacl_util.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/nonnacl_util/sel_ldr_launcher.target.mk)))),)
  include native_client/src/trusted/nonnacl_util/sel_ldr_launcher.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/perf_counter/nacl_perf_counter.target.mk)))),)
  include native_client/src/trusted/perf_counter/nacl_perf_counter.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/platform_qualify/platform_qual_lib.target.mk)))),)
  include native_client/src/trusted/platform_qualify/platform_qual_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/reverse_service/reverse_service.target.mk)))),)
  include native_client/src/trusted/reverse_service/reverse_service.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/sel_universal/sel_universal.target.mk)))),)
  include native_client/src/trusted/sel_universal/sel_universal.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/arch/x86/service_runtime_x86_common.target.mk)))),)
  include native_client/src/trusted/service_runtime/arch/x86/service_runtime_x86_common.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/arch/x86_64/service_runtime_x86_64.target.mk)))),)
  include native_client/src/trusted/service_runtime/arch/x86_64/service_runtime_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/env_cleanser.target.mk)))),)
  include native_client/src/trusted/service_runtime/env_cleanser.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/linux/nacl_bootstrap_lib.target.mk)))),)
  include native_client/src/trusted/service_runtime/linux/nacl_bootstrap_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/linux/nacl_bootstrap_munge_phdr.host.mk)))),)
  include native_client/src/trusted/service_runtime/linux/nacl_bootstrap_munge_phdr.host.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/linux/nacl_bootstrap_raw.target.mk)))),)
  include native_client/src/trusted/service_runtime/linux/nacl_bootstrap_raw.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/linux/nacl_helper_bootstrap.target.mk)))),)
  include native_client/src/trusted/service_runtime/linux/nacl_helper_bootstrap.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/nacl_error_code.target.mk)))),)
  include native_client/src/trusted/service_runtime/nacl_error_code.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/nacl_signal.target.mk)))),)
  include native_client/src/trusted/service_runtime/nacl_signal.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/sel.target.mk)))),)
  include native_client/src/trusted/service_runtime/sel.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/sel_ldr.target.mk)))),)
  include native_client/src/trusted/service_runtime/sel_ldr.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/sel_main.target.mk)))),)
  include native_client/src/trusted/service_runtime/sel_main.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/service_runtime/sel_main_chrome.target.mk)))),)
  include native_client/src/trusted/service_runtime/sel_main_chrome.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/simple_service/simple_service.target.mk)))),)
  include native_client/src/trusted/simple_service/simple_service.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/threading/thread_interface.target.mk)))),)
  include native_client/src/trusted/threading/thread_interface.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/driver/ncval_new.target.mk)))),)
  include native_client/src/trusted/validator/driver/ncval_new.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/ncfileutils_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/ncfileutils_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/validation_cache.target.mk)))),)
  include native_client/src/trusted/validator/validation_cache.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/validators.target.mk)))),)
  include native_client/src/trusted/validator/validators.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/decoder/nc_decoder_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/decoder/nc_decoder_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/decoder/nc_opcode_modeling_verbose_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/decoder/nc_opcode_modeling_verbose_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/decoder/nc_opcode_modeling_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/decoder/nc_opcode_modeling_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/decoder/ncdis_decode_tables_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/decoder/ncdis_decode_tables_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/ncval_base_verbose_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/ncval_base_verbose_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/ncval_base_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/ncval_base_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/ncval_reg_sfi/ncval_reg_sfi_verbose_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/ncval_reg_sfi/ncval_reg_sfi_verbose_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/ncval_reg_sfi/ncval_reg_sfi_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/ncval_reg_sfi/ncval_reg_sfi_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/ncval_seg_sfi/ncdis_seg_sfi_verbose_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/ncval_seg_sfi/ncdis_seg_sfi_verbose_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/ncval_seg_sfi/ncdis_seg_sfi_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/ncval_seg_sfi/ncdis_seg_sfi_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator/x86/ncval_seg_sfi/ncval_seg_sfi_x86_64.target.mk)))),)
  include native_client/src/trusted/validator/x86/ncval_seg_sfi/ncval_seg_sfi_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_arm/arm_validator_core.target.mk)))),)
  include native_client/src/trusted/validator_arm/arm_validator_core.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_arm/arm_validator_reporters.target.mk)))),)
  include native_client/src/trusted/validator_arm/arm_validator_reporters.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_arm/ncval_arm.target.mk)))),)
  include native_client/src/trusted/validator_arm/ncval_arm.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_arm/ncvalidate_arm_v2.target.mk)))),)
  include native_client/src/trusted/validator_arm/ncvalidate_arm_v2.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_ragel/dfa_validate_x86_64.target.mk)))),)
  include native_client/src/trusted/validator_ragel/dfa_validate_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_ragel/rdfa_validator.target.mk)))),)
  include native_client/src/trusted/validator_ragel/rdfa_validator.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_x86/nccopy_x86_64.target.mk)))),)
  include native_client/src/trusted/validator_x86/nccopy_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_x86/ncdis_util_x86_64.target.mk)))),)
  include native_client/src/trusted/validator_x86/ncdis_util_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/trusted/validator_x86/ncval_x86_64.target.mk)))),)
  include native_client/src/trusted/validator_x86/ncval_x86_64.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/irt/irt_browser_lib.target.mk)))),)
  include native_client/src/untrusted/irt/irt_browser_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/irt/irt_core_nexe.target.mk)))),)
  include native_client/src/untrusted/irt/irt_core_nexe.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/irt/irt_core_tls_check.target.mk)))),)
  include native_client/src/untrusted/irt/irt_core_tls_check.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/minidump_generator/minidump_generator_lib.target.mk)))),)
  include native_client/src/untrusted/minidump_generator/minidump_generator_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/imc_syscalls_lib.target.mk)))),)
  include native_client/src/untrusted/nacl/imc_syscalls_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/nacl_dynacode_lib.target.mk)))),)
  include native_client/src/untrusted/nacl/nacl_dynacode_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/nacl_dyncode_private_lib.target.mk)))),)
  include native_client/src/untrusted/nacl/nacl_dyncode_private_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/nacl_exception_lib.target.mk)))),)
  include native_client/src/untrusted/nacl/nacl_exception_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/nacl_lib.target.mk)))),)
  include native_client/src/untrusted/nacl/nacl_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/nacl_lib_glibc.target.mk)))),)
  include native_client/src/untrusted/nacl/nacl_lib_glibc.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/nacl_lib_newlib.target.mk)))),)
  include native_client/src/untrusted/nacl/nacl_lib_newlib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/nacl_list_mappings_lib.target.mk)))),)
  include native_client/src/untrusted/nacl/nacl_list_mappings_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nacl/nacl_list_mappings_private_lib.target.mk)))),)
  include native_client/src/untrusted/nacl/nacl_list_mappings_private_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/nosys/nosys_lib.target.mk)))),)
  include native_client/src/untrusted/nosys/nosys_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/pthread/pthread_lib.target.mk)))),)
  include native_client/src/untrusted/pthread/pthread_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/pthread/pthread_private_lib.target.mk)))),)
  include native_client/src/untrusted/pthread/pthread_private_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/valgrind/dynamic_annotations_lib.target.mk)))),)
  include native_client/src/untrusted/valgrind/dynamic_annotations_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/src/untrusted/valgrind/valgrind_lib.target.mk)))),)
  include native_client/src/untrusted/valgrind/valgrind_lib.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/test_hello_world_nexe.target.mk)))),)
  include native_client/test_hello_world_nexe.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/test_hello_world_pnacl_x86_64_nexe.target.mk)))),)
  include native_client/test_hello_world_pnacl_x86_64_nexe.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/tests/sel_main_chrome/sel_main_chrome_test.target.mk)))),)
  include native_client/tests/sel_main_chrome/sel_main_chrome_test.target.mk
endif
ifeq ($(strip $(foreach prefix,$(NO_LOAD),\
    $(findstring $(join ^,$(prefix)),\
                 $(join ^,native_client/untar_toolchains.target.mk)))),)
  include native_client/untar_toolchains.target.mk
endif

quiet_cmd_regen_makefile = ACTION Regenerating $@
cmd_regen_makefile = ./native_client/build/gyp_nacl -fmake --ignore-environment "--toplevel-dir=." -Inative_client/build/configs.gypi -Inative_client/build/standalone_flags.gypi "--depth=." "-Dnacl_standalone=1" "-Dsysroot=native_client/toolchain/linux_arm-trusted" native_client/build/all.gyp
Makefile: native_client/src/untrusted/valgrind/valgrind.gyp native_client/src/trusted/validator/x86/ncval_seg_sfi/ncval_seg_sfi.gyp native_client/src/trusted/desc/desc.gyp native_client/src/trusted/simple_service/simple_service.gyp native_client/src/trusted/validator/x86/ncval_reg_sfi/ncval_reg_sfi.gyp native_client/src/trusted/interval_multiset/interval_multiset.gyp native_client/src/trusted/validator/x86/decoder/ncdis_decode_tables.gyp native_client/build/untrusted.gypi native_client/src/trusted/validator/x86/validate_x86.gyp native_client/src/shared/srpc/srpc.gyp native_client/src/trusted/manifest_name_service_proxy/manifest_name_service_proxy.gyp native_client/src/untrusted/irt/irt.gyp native_client/src/trusted/validator_x86/validator_x86.gyp native_client/build/all.gyp native_client/src/trusted/validator_ragel/rdfa_validator.gyp native_client/src/trusted/validator/validator.gyp native_client/build/nacl_core_sdk.gyp native_client/src/trusted/service_runtime/service_runtime.gyp native_client/build/common.gypi native_client/src/trusted/validator/driver/ncval.gyp native_client/src/trusted/nonnacl_util/nonnacl_util.gyp native_client/src/untrusted/minidump_generator/minidump_generator.gyp native_client/src/shared/imc/imc.gyp native_client/src/trusted/debug_stub/debug_stub.gyp native_client/build/external_code.gypi native_client/src/untrusted/nosys/nosys.gyp native_client/src/untrusted/irt/irt_test.gyp native_client/src/trusted/perf_counter/perf_counter.gyp native_client/src/trusted/service_runtime/arch/x86/service_runtime_x86.gyp native_client/src/untrusted/irt/check_tls.gypi native_client/src/trusted/validator_arm/validator_arm.gyp native_client/src/shared/gio/gio.gyp native_client/tests/sel_main_chrome/sel_main_chrome.gyp native_client/src/shared/serialization/serialization.gyp native_client/src/trusted/threading/threading.gyp native_client/src/shared/platform/platform.gyp native_client/src/untrusted/pthread/pthread.gyp native_client/src/trusted/service_runtime/linux/nacl_bootstrap.gyp native_client/src/trusted/nonnacl_util/nonnacl_util.gypi native_client/src/trusted/cpu_features/cpu_features.gyp native_client/build/standalone_flags.gypi native_client/src/trusted/nacl_base/nacl_base.gyp native_client/src/trusted/service_runtime/arch/x86_64/service_runtime_x86_64.gyp native_client/src/trusted/validator_ragel/dfa_validator_x86_64.gyp native_client/src/trusted/reverse_service/reverse_service.gyp native_client/tests.gyp native_client/src/trusted/sel_universal/sel_universal.gyp native_client/src/trusted/platform_qualify/platform_qualify.gyp native_client/tools.gyp native_client/src/trusted/validator_x86/ncval.gyp native_client/src/trusted/gio/gio_wrapped_desc.gyp native_client/src/trusted/validator_arm/ncval.gyp native_client/build/configs.gypi native_client/src/shared/utils/utils.gyp native_client/src/untrusted/nacl/nacl.gyp native_client/src/trusted/validator/x86/decoder/ncval_x86_decoder.gyp native_client/src/trusted/validator/ncfileutils.gyp native_client/src/trusted/fault_injection/fault_injection.gyp
	$(call do_cmd,regen_makefile)

# "all" is a concatenation of the "all" targets from all the included
# sub-makefiles. This is just here to clarify.
all:

# Add in dependency-tracking rules.  $(all_deps) is the list of every single
# target in our tree. Only consider the ones with .d (dependency) info:
d_files := $(wildcard $(foreach f,$(all_deps),$(depsdir)/$(f).d))
ifneq ($(d_files),)
  include $(d_files)
endif
