require 'mkmf'

# Filter out Clang-specific flags if we are using GCC
if RbConfig::CONFIG['CC'] =~ /gcc/
  $CFLAGS.gsub!(/-Wno-self-assign/, '')
  $CFLAGS.gsub!(/-Wno-parentheses-equality/, '')
  $CFLAGS.gsub!(/-Wno-constant-logical-operand/, '')
end

$CFLAGS << ' -O3 -I.'
$defs << "-DSPINEL_NO_MAIN"

# We only want to compile the wrapper (which includes the logic)
$srcs = ['spinel_wrapper.c']

create_makefile('spinel_detector')
