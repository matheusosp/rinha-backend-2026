require 'mkmf'

$CFLAGS << ' -O3 -I.'
create_makefile('spinel_detector')
